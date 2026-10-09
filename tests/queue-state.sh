#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYER="$ROOT/bin/dromify-player"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/runtime" "$TMP/state"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/mpv"
chmod +x "$TMP/bin/mpv"
cat > "$TMP/bin/socat" <<'EOF'
#!/usr/bin/env bash
request="$(cat)"
if [[ "$request" == *'"get_version"'* ]]; then
  printf '%s\n' '{"data":{"version":"fixture"}}'
  exit 0
fi
# Keep response order aligned with cmd_status(): pause, time-pos, duration,
# idle-active, eof-reached, volume, playlist-pos, playlist-count,
# audio-codec-name, audio-bitrate, media-title, metadata/by-key/artist,
# loop-playlist, loop-file.
printf '%s\n' \
  '{"data":false}' \
  '{"data":42}' \
  '{"data":180}' \
  '{"data":false}' \
  '{"data":false}' \
  '{"data":0}' \
  '{"data":2}' \
  '{"data":4}' \
  '{"data":"flac"}' \
  '{"data":800000}' \
  "$(jq -cn --arg value "${MOCK_MEDIA_TITLE:-Recovered Track}" '{data:$value}')" \
  "$(jq -cn --arg value "${MOCK_MEDIA_ARTIST:-Recovered Artist}" '{data:$value}')" \
  "$(jq -cn --arg value "${MOCK_LOOP_PLAYLIST:-no}" '{data:$value}')" \
  "$(jq -cn --arg value "${MOCK_LOOP_FILE:-no}" '{data:$value}')"
EOF
chmod +x "$TMP/bin/socat"
export XDG_RUNTIME_DIR="$TMP/runtime"
export XDG_STATE_HOME="$TMP/state"
export PATH="$TMP/bin:$PATH"

input='[{"id":"song-1","title":"Track","artist":"Artist","album":"Record","coverArt":"cover-1","duration":180,"track":2,"starred":true,"streamUrl":"https://example.test/stream?id=song-1&token=secret"}]'
printf '%s\n' "$input" | "$PLAYER" save-queue-state >/dev/null

state="$("$PLAYER" queue-state)"
expected='[{"id":"song-1","title":"Track","artist":"Artist","album":"Record","coverArt":"cover-1","duration":180,"starred":true}]'
jq -e --argjson expected "$expected" '.queue == $expected and .shuffleEnabled == false and .unshuffledQueue == []' <<< "$state" >/dev/null
[[ "$state" != *"streamUrl"* && "$state" != *"token"* && "$state" != *"secret"* ]]
[[ "$(stat -c '%a' "$XDG_STATE_HOME/dromify/queue.json")" == "600" ]]
restored="$("$PLAYER" restore)"
jq -e '.status.idle == true and .queue[0].id == "song-1" and (.status | has("path") | not)' <<< "$restored" >/dev/null
python3 - "$XDG_RUNTIME_DIR/dromify-mpv.sock" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.close()
PY
active_restore="$("$PLAYER" restore)"
jq -e '.status.running == true and .status.idle == false and .status.playlistPos == 2 and .status.playlistCount == 4 and .status.mediaTitle == "Recovered Track" and .status.artist == "Recovered Artist" and .queue[0].id == "song-1" and (.status | has("path") | not)' <<< "$active_restore" >/dev/null
repeat_all="$(MOCK_LOOP_PLAYLIST=inf "$PLAYER" status)"
repeat_one="$(MOCK_LOOP_FILE=inf "$PLAYER" status)"
repeat_off="$("$PLAYER" status)"
jq -e '.repeatMode == "all"' <<< "$repeat_all" >/dev/null
jq -e '.repeatMode == "one"' <<< "$repeat_one" >/dev/null
jq -e '.repeatMode == "off"' <<< "$repeat_off" >/dev/null

original='[{"id":"song-1","title":"First","artist":"Artist"},{"id":"song-2","title":"Second","artist":"Artist"}]'
shuffled='[{"id":"song-2","title":"Second","artist":"Artist"},{"id":"song-1","title":"First","artist":"Artist"}]'
shuffle_input="$(jq -cn --argjson queue "$shuffled" --argjson original "$original" '{queue:$queue,shuffleEnabled:true,unshuffledQueue:$original,streamUrl:"https://example.test/stream?token=secret"}')"
printf '%s\n' "$shuffle_input" | "$PLAYER" save-queue-state >/dev/null
shuffle_state="$("$PLAYER" queue-state)"
jq -e '.shuffleEnabled == true and [.queue[].id] == ["song-2","song-1"] and [.unshuffledQueue[].id] == ["song-1","song-2"]' <<< "$shuffle_state" >/dev/null
shuffle_restore="$("$PLAYER" restore)"
jq -e '.shuffleEnabled == true and [.queue[].id] == ["song-2","song-1"] and [.unshuffledQueue[].id] == ["song-1","song-2"]' <<< "$shuffle_restore" >/dev/null
[[ "$shuffle_state" != *"streamUrl"* && "$shuffle_state" != *"token"* && "$shuffle_state" != *"secret"* ]]

unsafe_status="$(MOCK_MEDIA_TITLE='https://music.example/stream?token=secret' "$PLAYER" status)"
jq -e '.mediaTitle == "" and .artist == "Recovered Artist"' <<< "$unsafe_status" >/dev/null
[[ "$unsafe_status" != *"secret"* ]]

if printf '{invalid json' | "$PLAYER" save-queue-state >/dev/null 2>&1; then
  echo "invalid queue state was accepted" >&2
  exit 1
fi
jq -e '.shuffleEnabled == true and [.queue[].id] == ["song-2","song-1"]' <<< "$("$PLAYER" queue-state)" >/dev/null

mkdir -p "$TMP/outside" "$TMP/linked"
chmod 755 "$TMP/outside"
ln -s "$TMP/outside" "$TMP/linked/dromify"
linked_state="$(XDG_STATE_HOME="$TMP/linked" "$PLAYER" queue-state)"
[[ "$linked_state" == '{"queue":[],"shuffleEnabled":false,"unshuffledQueue":[]}' ]]
[[ "$(stat -c '%a' "$TMP/outside")" == "755" ]]
mkdir -p "$TMP/shared" "$TMP/unsafe"
chmod 777 "$TMP/shared"
ln -s "$TMP/shared" "$TMP/unsafe/dromify"
if XDG_STATE_HOME="$TMP/unsafe" "$PLAYER" queue-state >/dev/null 2>&1; then
  echo "accepted a group/world-writable state directory symlink" >&2
  exit 1
fi

"$PLAYER" clear-queue-state >/dev/null
[[ "$("$PLAYER" queue-state)" == '{"queue":[],"shuffleEnabled":false,"unshuffledQueue":[]}' ]]
printf 'queue-state: ok\n'
