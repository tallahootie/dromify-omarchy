#!/usr/bin/env bash
set -euo pipefail

if [[ "${DROMIFY_RUN_SHELL_RELOAD_TEST:-}" != "1" ]]; then
  echo "Refusing to restart Omarchy shell; set DROMIFY_RUN_SHELL_RELOAD_TEST=1 to run." >&2
  exit 2
fi

PLUGIN_DIR="${DROMIFY_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/tallahootie.dromify}"
PLAYER="$PLUGIN_DIR/bin/dromify-player"
if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]]; then
  RUNTIME_DIR="$XDG_RUNTIME_DIR"
else
  RUNTIME_DIR="/tmp/dromify-$(id -u)"
fi
MPV_SOCKET="$RUNTIME_DIR/dromify-mpv.sock"

mpv_pid() {
  ps -ww -eo pid=,args= | awk -v socket="$MPV_SOCKET" '
    index($0, "--input-ipc-server=" socket) { pid = $1; count++ }
    END { if (count == 1) print pid; else exit 1 }
  '
}

for command in jq journalctl omarchy omarchy-shell ps; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done
[[ -x "$PLAYER" ]] || { echo "Dromify player helper not found" >&2; exit 1; }
omarchy-shell shell ping >/dev/null || { echo "Omarchy shell is not running" >&2; exit 1; }
omarchy plugin list --json | jq -e 'any(.[]; .id == "tallahootie.dromify" and .enabled == true)' >/dev/null \
  || { echo "Dromify bar widget is not enabled" >&2; exit 1; }

before="$("$PLAYER" status)"
jq -e '.running == true and .idle == false and .paused == false and .playlistCount > 0 and .playlistPos >= 0 and (.mediaTitle != "" or .artist != "")' \
  <<<"$before" >/dev/null \
  || { echo "Start unpaused Dromify playback before running this test" >&2; exit 1; }
before_count="$(jq -r '.playlistCount' <<<"$before")"
before_pos="$(jq -r '.playlistPos' <<<"$before")"
before_position="$(jq -r '.position' <<<"$before")"
before_repeat="$(jq -r '.repeatMode' <<<"$before")"
before_queue="$("$PLAYER" queue-state)"
jq -e --argjson count "$before_count" '
  (.queue | length) == $count
  and all(.queue[]; .id != "" and ((.title // "") != "" or (.artist // "") != ""))
' <<<"$before_queue" >/dev/null \
  || { echo "Saved Dromify queue metadata is required for exact track verification" >&2; exit 1; }
before_shuffle="$(jq -r '.shuffleEnabled == true' <<<"$before_queue")"
before_pid="$(mpv_pid)" || { echo "Could not identify Dromify's mpv process" >&2; exit 1; }
RESTORE_MARKER="dromify: restored now playing state repeat=$before_repeat shuffle=$before_shuffle"

cursor_line="$(journalctl --user -b -n 0 --show-cursor --no-pager 2>/dev/null | grep '^-- cursor: ' | tail -n 1)"
cursor="${cursor_line#-- cursor: }"
[[ -n "$cursor" && "$cursor" != "$cursor_line" ]] || {
  echo "Could not capture journal cursor" >&2
  exit 1
}

omarchy restart shell
shell_ready=false
for ((attempt = 0; attempt < 45; attempt++)); do
  if omarchy-shell shell ping >/dev/null 2>&1; then
    shell_ready=true
    break
  fi
  sleep 1
done
[[ "$shell_ready" == true ]] || { echo "Omarchy shell did not return after restart" >&2; exit 1; }

restored=false
for ((attempt = 0; attempt < 30; attempt++)); do
  logs="$(journalctl --user -b --after-cursor="$cursor" --no-pager -o cat 2>/dev/null || true)"
  if grep -Fq "$RESTORE_MARKER" <<<"$logs"; then
    restored=true
    break
  fi
  sleep 1
done
[[ "$restored" == true ]] || { echo "Dromify did not report restoring now playing state" >&2; exit 1; }

after="$("$PLAYER" status)"
jq -e '.running == true and .idle == false and .paused == false and .playlistCount > 0 and .playlistPos >= 0 and (.mediaTitle != "" or .artist != "")' \
  <<<"$after" >/dev/null \
  || { echo "Playback did not survive shell restart" >&2; exit 1; }
after_count="$(jq -r '.playlistCount' <<<"$after")"
[[ "$after_count" == "$before_count" ]] || { echo "mpv playlist changed during shell restart" >&2; exit 1; }
after_pid="$(mpv_pid)" || { echo "Could not identify Dromify's mpv process after restart" >&2; exit 1; }
[[ "$after_pid" == "$before_pid" ]] || { echo "mpv process changed during shell restart" >&2; exit 1; }
[[ "$(jq -r '.repeatMode' <<<"$after")" == "$before_repeat" ]] \
  || { echo "mpv repeat mode changed during shell restart" >&2; exit 1; }

after_pos="$(jq -r '.playlistPos' <<<"$after")"
if [[ "$before_repeat" == "one" && "$after_pos" != "$before_pos" ]]; then
  echo "Playlist position changed while repeat-one was active" >&2
  exit 1
fi
if [[ "$before_repeat" != "all" && "$after_pos" -lt "$before_pos" ]]; then
  echo "Playlist position moved backwards without repeat-all" >&2
  exit 1
fi
expected_track="$(jq -ce --argjson pos "$after_pos" '
  def safeText: if type != "string" then "" elif (ascii_downcase | contains("://")) then "" else .[0:512] end;
  .queue[$pos] as $song
  | (if $song.title != "" then $song.title else $song.artist end) as $title
  | {
      mediaTitle: ($title | if length > 40 then (.[:39] + "…") else . end | gsub("[\\r\\n]+"; " ") | safeText),
      artist: ($song.artist | safeText)
    }
' <<<"$before_queue")" || { echo "Current playlist position has no saved track metadata" >&2; exit 1; }
jq -e --argjson expected "$expected_track" '
  .mediaTitle == $expected.mediaTitle and .artist == $expected.artist
' <<<"$after" >/dev/null \
  || { echo "Current track does not match the saved playlist position" >&2; exit 1; }
if [[ "$after_pos" == "$before_pos" && "$before_repeat" == "off" ]]; then
  awk -v before="$before_position" -v after="$(jq -r '.position' <<<"$after")" 'BEGIN { exit !(after + 2 >= before) }' \
    || { echo "Current track position moved backwards" >&2; exit 1; }
fi

printf 'shell-reload: ok\n'
