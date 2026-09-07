// Pure helpers for shaping Subsonic/Navidrome JSON (as returned by
// `bin/dromify-api get ...`, already unwrapped to the inner
// "subsonic-response" object) into the flat row lists the panel renders.
// Field names mirror Dromify's DromifyKit models (id, name/title, artist,
// artistId, album, albumId, coverArt, duration, track, year, songCount,
// albumCount) so anyone who knows the app recognizes the shapes here.

function safeArray(value) {
  return Array.isArray(value) ? value : []
}

function formatDuration(totalSeconds) {
  var secs = Math.max(0, Math.round(Number(totalSeconds) || 0))
  var m = Math.floor(secs / 60)
  var s = secs % 60
  return m + ":" + (s < 10 ? "0" : "") + s
}

// "-3:45" style countdown for the right-hand side of a seek bar.
function formatRemaining(position, duration) {
  var remaining = Number(duration) - Number(position)
  return "-" + formatDuration(remaining)
}

// A short "what's actually playing" pill: "FLAC" for lossless formats
// (bitrate there is just the raw PCM rate, not a meaningful quality
// number), "MP3 320" for lossy ones. Codec name comes from mpv itself, so
// this reflects real server-side transcoding rather than the source
// file's own tag.
var LOSSLESS_CODECS = ["flac", "alac", "wav", "pcm", "pcm_s16le", "pcm_s24le", "ape", "wavpack", "tta", "tak"]
function formatAudioLabel(codec, bitrateBps) {
  var name = String(codec || "").trim()
  if (name === "") return ""
  var upper = name.toUpperCase()
  if (LOSSLESS_CODECS.indexOf(name.toLowerCase()) !== -1) return upper
  var kbps = Math.round((Number(bitrateBps) || 0) / 1000)
  return kbps > 0 ? (upper + " " + kbps) : upper
}

// getArtists.view -> flat artist list (server groups them under an
// alphabetical index; the panel doesn't need that grouping).
function extractArtists(body) {
  var groups = body && body.artists ? safeArray(body.artists.index) : []
  var out = []
  for (var i = 0; i < groups.length; i++) {
    var artists = safeArray(groups[i].artist)
    for (var j = 0; j < artists.length; j++) out.push(artists[j])
  }
  return out
}

function extractAlbums(body) {
  if (!body) return []
  if (body.albumList2) return safeArray(body.albumList2.album)
  if (body.artist) return safeArray(body.artist.album)
  return []
}

function extractSongs(body) {
  if (!body) return []
  if (body.album) return safeArray(body.album.song)
  if (body.playlist) return safeArray(body.playlist.entry)
  if (body.randomSongs) return safeArray(body.randomSongs.song)
  if (body.songsByGenre) return safeArray(body.songsByGenre.song)
  return []
}

function extractPlaylists(body) {
  return body && body.playlists ? safeArray(body.playlists.playlist) : []
}

function extractSearch(body) {
  var r = (body && body.searchResult3) || {}
  return {
    artists: safeArray(r.artist),
    albums: safeArray(r.album),
    songs: safeArray(r.song)
  }
}

function extractStarred(body) {
  var r = (body && body.starred2) || {}
  return {
    artists: safeArray(r.artist),
    albums: safeArray(r.album),
    songs: safeArray(r.song)
  }
}

function albumSubtitle(album) {
  var parts = []
  if (album && album.artist) parts.push(album.artist)
  if (album && album.year) parts.push(String(album.year))
  return parts.join(" · ")
}

function artistSubtitle(artist) {
  var count = artist ? Number(artist.albumCount || 0) : 0
  if (count <= 0) return ""
  return count + (count === 1 ? " album" : " albums")
}

function songSubtitle(song) {
  var parts = []
  if (song && song.artist) parts.push(song.artist)
  if (song && song.album) parts.push(song.album)
  return parts.join(" · ")
}

function playlistSubtitle(playlist) {
  var count = playlist ? Number(playlist.songCount || 0) : 0
  if (count <= 0) return "Empty"
  return count + (count === 1 ? " track" : " tracks")
}

function isStarred(item) {
  return !!(item && item.starred)
}

// Just the title, trimmed to a plausible bar-pill length. This is baked
// into mpv's per-entry force-media-title (see Service.qml's
// _urlsWithTitles) rather than "Artist – Title" — the system media widget
// already appends mpv-mpris's own (now correctly-synced, per-file) Artist
// tag after whatever we put here, so including the artist ourselves too
// made it show up twice.
function nowPlayingLabel(song) {
  if (!song) return ""
  var title = song.title ? song.title : (song.artist || "")
  return title.length > 40 ? title.substring(0, 39) + "…" : title
}
