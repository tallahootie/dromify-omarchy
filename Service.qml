import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Bridges the QML panel to the two bundled shell scripts:
//   bin/dromify-api    - Subsonic/Navidrome REST calls (config, browse,
//                          search, favourites, cover art)
//   bin/dromify-player - a single always-idle mpv instance, controlled
//                          over its JSON IPC socket
//
// Every external call goes through a Process; nothing here talks to the
// network or to mpv directly. Two small job queues (one for API reads, one
// for cover art) keep concurrent requests from clobbering each other's
// stdout collector, while player transport calls are simple fire-and-forget
// one-shots guarded against overlap.
Item {
  id: root

  // Directory this plugin was loaded from — works whether it's installed at
  // the conventional ~/.config/omarchy/plugins/tallahootie.dromify or
  // cloned/symlinked elsewhere, since it's derived from this file's own URL
  // rather than assumed.
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    return u.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string apiBin: pluginDir + "/bin/dromify-api"
  readonly property string playerBin: pluginDir + "/bin/dromify-player"

  // dromify-api already caps what it will buffer from the server, but the
  // response comes back through a StdioCollector that would hold it a second
  // time in this (the bar's) process. Reject anything past this ceiling
  // before it reaches JSON.parse, so a regression or a hostile server can't
  // balloon the shell's memory. Matches dromify-api's own MAX_JSON_BYTES.
  readonly property int _maxApiBytes: 16 * 1024 * 1024
  function _overSized(s) { return s && s.length > _maxApiBytes }

  property bool configured: false
  property bool restoreOnStartup: true
  property string lastError: ""
  property bool connecting: false

  // Transport state, refreshed by the poll timer while queueIndex >= 0.
  property bool playing: false
  property bool paused: true
  property real position: 0
  property real duration: 0
  property int volume: 100
  // What's actually being decoded right now — from mpv, not the source
  // file's own tags, so it reflects any server-side transcoding rather
  // than just what the original file happens to be.
  property string audioCodec: ""
  property int audioBitrate: 0   // bits/sec, 0 if unknown

  // When metadata is available, queue mirrors the list the user played
  // (album, playlist, search results, ...). After an older session reloads
  // without a saved snapshot, mpv still owns the playlist; fallbackCurrentSong
  // carries the current title/artist until the user starts a new queue.
  property var queue: []
  property int queueIndex: -1
  property bool queueMetadataAvailable: false
  property var fallbackCurrentSong: null
  property int fallbackPlaylistCount: 0
  property var _pendingQueueState: null
  readonly property var currentSong: queueMetadataAvailable
    ? ((queueIndex >= 0 && queueIndex < queue.length) ? queue[queueIndex] : null)
    : fallbackCurrentSong
  onRestoreOnStartupChanged: if (!restoreOnStartup) pollTimer.stop()
  // True from the moment a track is requested until mpv confirms it loaded.
  // playFrom refuses to start a second load while one is in flight, so
  // spamming next/prev can't race two loads and leave `queue`/`queueIndex`
  // (updated optimistically, for instant UI feedback) pointing at a track
  // mpv never actually loaded.
  property bool loading: false

  // Repeat is delegated to mpv's own loop-playlist/loop-file properties
  // (see dromify-player's set-repeat) — this just tracks which of the
  // three states is active for the UI. Not reset by playFrom: repeat is a
  // player-wide preference, not tied to any one queue.
  property string repeatMode: "off"   // off | all | one

  // Shuffle, unlike repeat, has no equivalent mpv property that's both
  // toggleable and reversible (playlist-shuffle has no inverse), so it's
  // done client-side: reorder `queue` and rewrite mpv's playlist tail to
  // match (see _reorderTail). Only the *upcoming* portion (after
  // queueIndex) is shuffled — history and the currently playing entry stay
  // put — and _unshuffledQueue keeps the pre-shuffle order so toggling
  // back off restores remaining tracks in original order.
  property bool shuffleEnabled: false
  property var _unshuffledQueue: null

  // coverCache maps "id:size" -> local file path (populated asynchronously).
  // A value of "" means a fetch is in flight; absent means not requested yet.
  property var coverCache: ({})

  // --- browse / navigation state -------------------------------------------
  // Lives here (not on the per-monitor Panel.qml) so every screen's copy of
  // the bar widget shows the same tab, drill-down level, search, and
  // settings view — otherwise each screen navigated independently even
  // though they all shared the one playing track.

  property string activeTab: "albums"   // albums | artists | playlists | favorites
  property var tabAlbums: []
  property var tabArtists: []
  property var tabPlaylists: []
  property var tabFavorites: ({ artists: [], albums: [], songs: [] })
  property var loadedTabs: ({})

  property string searchQuery: ""
  readonly property bool searchActive: searchQuery.trim() !== ""
  property var searchResults: ({ artists: [], albums: [], songs: [] })

  // Drill stack: each frame is { kind: "artistAlbums"|"albumSongs"|"playlistSongs", id, title, items, loading }
  property var stack: []
  readonly property var topFrame: stack.length > 0 ? stack[stack.length - 1] : null

  property bool showSettings: false
  property bool addingServer: false

  // Keyboard/mouse cursor. Shared for the same reason as the rest of this
  // section — moving the cursor on one screen's panel is the same action
  // as moving it on another's.
  property string focusSection: "search"   // search | tabs | list | nowplaying
  property int tabIndex: 0
  property int listIndex: 0
  property bool cursorActive: false
  // True from the moment a keyboard move/activate happens until the mouse
  // genuinely moves. Row and tab hover handlers check this and skip their
  // own cursor updates while it's set — without it, a mouse sitting
  // motionless over the tabs row could still "re-enter" a tab (Qt hit-tests
  // the stationary pointer against the new geometry whenever a tab's width
  // changes, e.g. the active tab going bold) and silently snap focus back
  // to "tabs" right after a keyboard Down press moved it into the list.
  property bool keyboardActive: false
  readonly property var tabOrder: ["albums", "artists", "playlists", "favorites"]

  // Accordion-style collapse of everything below Now Playing (search, tabs,
  // list) — offered only while a song is actually playing, so there's
  // something worth shrinking down to. Shared like the rest of this section:
  // collapsing on one screen collapses the same logical panel everywhere.
  property bool browseCollapsed: false

  function switchTab(tab) {
    activeTab = tab
    stack = []
    ensureTabLoaded(tab)
    setListCursor(0)
  }

  // Clears everything cached from whichever server was active before —
  // switching (or connecting to a different) server must not leave the
  // previous server's albums/artists/playlists sitting in view.
  function resetBrowseState() {
    stack = []
    loadedTabs = {}
    tabAlbums = []
    tabArtists = []
    tabPlaylists = []
    tabFavorites = { artists: [], albums: [], songs: [] }
    searchQuery = ""
    searchResults = { artists: [], albums: [], songs: [] }
  }

  function ensureTabLoaded(tab, force) {
    if (!force && loadedTabs[tab]) return
    var next = {}
    for (var k in loadedTabs) next[k] = loadedTabs[k]
    next[tab] = true
    loadedTabs = next
    if (tab === "albums") fetchAlbums("newest", function(rows) { tabAlbums = rows })
    else if (tab === "artists") fetchArtists(function(rows) { tabArtists = rows })
    else if (tab === "playlists") fetchPlaylists(function(rows) { tabPlaylists = rows })
    else if (tab === "favorites") fetchFavorites(function(rows) { tabFavorites = rows })
  }

  function pushArtist(artist) {
    stack = stack.concat([{ kind: "artistAlbums", id: artist.id, title: artist.name, items: [], loading: true }])
    setListCursor(0)
    fetchArtistAlbums(artist.id, function(rows) { replaceTopFrame("artistAlbums", artist.id, artist.name, rows) })
  }

  function pushAlbum(album) {
    stack = stack.concat([{ kind: "albumSongs", id: album.id, title: album.name, items: [], loading: true }])
    setListCursor(0)
    fetchAlbumSongs(album.id, function(rows) { replaceTopFrame("albumSongs", album.id, album.name, rows) })
  }

  function pushPlaylist(playlist) {
    stack = stack.concat([{ kind: "playlistSongs", id: playlist.id, title: playlist.name, items: [], loading: true }])
    setListCursor(0)
    fetchPlaylistSongs(playlist.id, function(rows) { replaceTopFrame("playlistSongs", playlist.id, playlist.name, rows) })
  }

  function replaceTopFrame(kind, id, title, items) {
    var copy = stack.slice(0, -1)
    copy.push({ kind: kind, id: id, title: title, items: items, loading: false })
    stack = copy
  }

  // Re-fetches whatever the current frame (or top-level tab) is showing.
  function refetchFrame(frame) {
    if (frame.kind === "artistAlbums") fetchArtistAlbums(frame.id, function(rows) { replaceTopFrame(frame.kind, frame.id, frame.title, rows) })
    else if (frame.kind === "albumSongs") fetchAlbumSongs(frame.id, function(rows) { replaceTopFrame(frame.kind, frame.id, frame.title, rows) })
    else if (frame.kind === "playlistSongs") fetchPlaylistSongs(frame.id, function(rows) { replaceTopFrame(frame.kind, frame.id, frame.title, rows) })
  }

  function popFrame() {
    stack = stack.slice(0, -1)
    setListCursor(0)
  }

  // --- flat row model --------------------------------------------------------
  // Header rows are non-navigable section labels used to combine
  // artists/albums/songs into one list for search results and favourites.

  function combinedRows(result) {
    var out = []
    var artists = (result && result.artists) || []
    var albums = (result && result.albums) || []
    var songs = (result && result.songs) || []
    if (artists.length) { out.push({ type: "header", data: "ARTISTS" }); artists.forEach(function(a) { out.push({ type: "artist", data: a }) }) }
    if (albums.length) { out.push({ type: "header", data: "ALBUMS" }); albums.forEach(function(a) { out.push({ type: "album", data: a }) }) }
    if (songs.length) { out.push({ type: "header", data: "SONGS" }); songs.forEach(function(s) { out.push({ type: "song", data: s }) }) }
    return out
  }

  property var rows: {
    // Search wins over the drill stack: the search field stays visible at
    // every level, so typing in it while drilled into an album/artist has
    // to actually show results rather than being swallowed by the frame.
    // The stack is left intact underneath — clearing the query drops you
    // back exactly where you were.
    if (root.searchActive) return root.combinedRows(root.searchResults)
    if (root.topFrame) {
      var kind = root.topFrame.kind === "artistAlbums" ? "album" : "song"
      // A playlist's rows are numbered by their position in the playlist,
      // not each track's own album track number — so carry that 1-based
      // position on the row for the panel to show.
      var isPlaylist = root.topFrame.kind === "playlistSongs"
      return root.topFrame.items.map(function(it, i) {
        return isPlaylist ? { type: kind, data: it, listPos: i + 1 }
                          : { type: kind, data: it }
      })
    }
    if (root.activeTab === "albums") return root.tabAlbums.map(function(a) { return { type: "album", data: a } })
    if (root.activeTab === "artists") return root.tabArtists.map(function(a) { return { type: "artist", data: a } })
    if (root.activeTab === "playlists") return root.tabPlaylists.map(function(p) { return { type: "playlist", data: p } })
    if (root.activeTab === "favorites") return root.combinedRows(root.tabFavorites)
    return []
  }
  property var navigableRows: rows.filter(function(r) { return r.type !== "header" })
  readonly property bool listLoading: root.searchActive ? false : (root.topFrame ? root.topFrame.loading : false)
  readonly property string listTitle: root.searchActive ? "Search results" : (root.topFrame ? root.topFrame.title : "")

  function songListForRow(row) {
    if (root.searchActive) return root.searchResults.songs
    if (root.topFrame) return root.topFrame.items
    if (root.activeTab === "favorites") return root.tabFavorites.songs
    return []
  }

  function activateRow(row) {
    if (!row) return
    // Drilling into a container from search results leaves search mode —
    // otherwise the pushed frame would stay hidden behind the still-active
    // results (search outranks the stack in the `rows` binding).
    if (row.type === "artist" || row.type === "album" || row.type === "playlist") {
      if (searchActive) searchQuery = ""
    }
    if (row.type === "artist") pushArtist(row.data)
    else if (row.type === "album") pushAlbum(row.data)
    else if (row.type === "playlist") pushPlaylist(row.data)
    else if (row.type === "song") {
      var songs = songListForRow(row)
      // By id, not indexOf(row.data) — object-reference equality here is
      // one more thing that has to stay perfectly in sync between the
      // clicked row and this list; comparing the actual song id can't go
      // stale the same way.
      var idx = -1
      for (var i = 0; i < songs.length; i++) {
        if (songs[i] && songs[i].id === row.data.id) { idx = i; break }
      }
      playFrom(songs, idx < 0 ? 0 : idx)
    }
  }

  function toggleCurrentFavorite() {
    var row = navigableRows[listIndex]
    if (row && (row.type === "song" || row.type === "album" || row.type === "artist")) toggleFavorite(row.data)
  }

  function refreshCurrent() {
    if (topFrame) refetchFrame(topFrame)
    else if (searchActive) search(searchQuery, function(result) { searchResults = result })
    else ensureTabLoaded(activeTab, true)
  }

  Timer {
    id: searchDebounce
    interval: 350
    onTriggered: root.search(root.searchQuery, function(result) { root.searchResults = result })
  }
  onSearchQueryChanged: searchDebounce.restart()

  // --- keyboard cursor ---------------------------------------------------
  // setListCursor/moveCursor/activateCursor only touch state; the visual
  // "scroll this row into view" effect is per-monitor (each screen has its
  // own Flickable), so Panel.qml does that itself, reactively, whenever
  // listIndex or focusSection changes here.

  function setListCursor(i) {
    listIndex = Math.max(0, i)
  }

  function ensureCursor() {
    if (listIndex >= navigableRows.length) listIndex = Math.max(0, navigableRows.length - 1)
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    keyboardActive = true
    if (dx !== 0 && !searchActive && stack.length === 0 && focusSection !== "nowplaying") {
      focusSection = "tabs"
      tabIndex = Math.max(0, Math.min(tabOrder.length - 1, tabIndex + dx))
      switchTab(tabOrder[tabIndex])
      return
    }
    if (dy === 0) return
    ensureCursor()
    if (focusSection === "search" || focusSection === "tabs") {
      // Not gated on navigableRows already having content: the list may
      // still be loading (a real possibility against a remote server), and
      // requiring it to be non-empty here meant a Down press pressed too
      // soon did nothing at all, with no way to tell it had been ignored.
      // Landing on "list" with nothing loaded yet is harmless — the first
      // row highlights itself as soon as it arrives.
      if (dy > 0) { focusSection = "list"; listIndex = 0 }
      return
    }
    if (focusSection === "list") {
      var next = listIndex + dy
      if (next < 0) { focusSection = searchActive || stack.length > 0 ? "search" : "tabs"; return }
      if (next >= navigableRows.length) {
        if (root.currentSong) focusSection = "nowplaying"
        return
      }
      listIndex = next
      return
    }
    if (focusSection === "nowplaying" && dy < 0) {
      focusSection = "list"
    }
  }

  function activateCursor() {
    keyboardActive = true
    if (focusSection === "list") activateRow(navigableRows[listIndex])
    else if (focusSection === "nowplaying") togglePause()
  }

  // --- setup -------------------------------------------------------------
  // Multiple named server profiles can be saved; one is "active" at a time.
  // activeProfile is {id, name, serverURL, username} or null; profiles is
  // every saved profile (including the active one), for a settings/switcher
  // view to list.

  property var activeProfile: null
  property var profiles: []

  function _applyStatus(data) {
    if (!data) return
    root.configured = data.configured === true
    root.activeProfile = data.active || null
    root.profiles = data.profiles || []
  }

  function refreshStatus(callback) {
    _run(statusProcess, [apiBin, "status"], function(data, err) {
      _applyStatus(data)
      if (callback) callback(data, err)
    })
  }

  function configure(name, serverUrl, user, password, callback) {
    connecting = true
    lastError = ""
    _runWithSecret(configureProcess, [apiBin, "configure", name, serverUrl, user], password, function(data, err) {
      connecting = false
      if (err) {
        lastError = err
        if (callback) callback(false, err)
        return
      }
      refreshStatus()
      _warmUpPlayer()
      if (callback) callback(true, "")
    })
  }

  // Switches which saved profile is active — no credentials needed, it's
  // already saved. Does not touch current playback (a different server
  // wouldn't recognize the currently-loaded track's id anyway, but there's
  // no reason to force-stop it either).
  function switchProfile(id, callback) {
    _run(configureProcess, [apiBin, "switch", id], function(data, err) {
      _applyStatus(data)
      if (callback) callback(!err, err || "")
    })
  }

  // Removes one saved profile. If it was the active one, nothing is active
  // afterward (the settings view is left showing "add a server").
  function forgetProfile(id, callback) {
    var wasActive = root.activeProfile && root.activeProfile.id === id
    _run(forgetProcess, [apiBin, "forget", id], function(data, err) {
      _applyStatus(data)
      if (wasActive && !root.configured) {
        stopPlayback()
        queue = []
        queueIndex = -1
      }
      if (callback) callback(!err, err || "")
    })
  }

  function renameProfile(id, name, callback) {
    _run(configureProcess, [apiBin, "rename", id, name], function(data, err) {
      _applyStatus(data)
      if (callback) callback(!err, err || "")
    })
  }

  // Clears a profile's stored password without deleting the saved
  // name/server/username, distinct from forgetProfile (which removes it
  // entirely) — the profile can be signed back into later via relogin.
  function logoutProfile(id, callback) {
    var wasActive = root.activeProfile && root.activeProfile.id === id
    _run(forgetProcess, [apiBin, "logout", id], function(data, err) {
      _applyStatus(data)
      if (wasActive && !root.configured) {
        stopPlayback()
        queue = []
        queueIndex = -1
      }
      if (callback) callback(!err, err || "")
    })
  }

  function relogin(id, password, callback) {
    connecting = true
    lastError = ""
    _runWithSecret(configureProcess, [apiBin, "relogin", id], password, function(data, err) {
      connecting = false
      _applyStatus(data)
      if (err) lastError = err
      if (callback) callback(!err, err || "")
    })
  }

  // Opens the active server's web UI in the default browser
  // (omarchy-launch-browser honours xdg-settings). No credentials go with
  // it — the web UI keeps its own session once you've signed in, and the
  // password is a deliberate copy from the settings view (copyProfilePassword).
  function openServerInBrowser() {
    var url = activeProfile && activeProfile.serverURL ? String(activeProfile.serverURL) : ""
    if (url === "") return
    Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  // Copies a saved profile's password to the clipboard, for pasting into
  // its web UI's sign-in form once. dromify-api does the copy itself
  // (keyring -> `wl-copy --sensitive`), so the plaintext never passes
  // through here or an argv, and Omarchy's clipboard-history capture skips
  // the --sensitive offer. `profileId` empty/omitted means the active one.
  function copyProfilePassword(profileId) {
    var args = [apiBin, "copy-password"]
    if (profileId) args.push(String(profileId))
    Quickshell.execDetached(args)
    Quickshell.execDetached(["notify-send", "-a", "Dromify", "-t", "4000",
      "Password copied to clipboard", "Paste it into the server's sign-in form."])
  }

  // --- browsing ------------------------------------------------------------
  // Each call parses the endpoint's JSON and hands the caller a plain row
  // array via `callback(rows, error)`. Reads share one queued Process so a
  // fast double-click can't race two responses onto the same stdout.

  function fetchArtists(callback) {
    _apiGet(["getArtists.view"], function(body, err) { callback(err ? [] : Model.extractArtists(body), err) })
  }

  function fetchArtistAlbums(artistId, callback) {
    _apiGet(["getArtist.view", "id=" + artistId], function(body, err) { callback(err ? [] : Model.extractAlbums(body), err) })
  }

  function fetchAlbums(type, callback) {
    _apiGet(["getAlbumList2.view", "type=" + type, "size=60"], function(body, err) { callback(err ? [] : Model.extractAlbums(body), err) })
  }

  function fetchAlbumSongs(albumId, callback) {
    _apiGet(["getAlbum.view", "id=" + albumId], function(body, err) { callback(err ? [] : Model.extractSongs(body), err) })
  }

  function fetchPlaylists(callback) {
    _apiGet(["getPlaylists.view"], function(body, err) { callback(err ? [] : Model.extractPlaylists(body), err) })
  }

  function fetchPlaylistSongs(playlistId, callback) {
    _apiGet(["getPlaylist.view", "id=" + playlistId], function(body, err) { callback(err ? [] : Model.extractSongs(body), err) })
  }

  function fetchFavorites(callback) {
    _apiGet(["getStarred2.view"], function(body, err) { callback(err ? { artists: [], albums: [], songs: [] } : Model.extractStarred(body), err) })
  }

  function search(query, callback) {
    if (String(query || "").trim() === "") { callback({ artists: [], albums: [], songs: [] }, ""); return }
    _apiGet(["search3.view", "query=" + query], function(body, err) { callback(err ? { artists: [], albums: [], songs: [] } : Model.extractSearch(body), err) })
  }

  function toggleFavorite(item) {
    if (!item || !item.id) return
    var next = !Model.isStarred(item)
    _apiGet([(next ? "star.view" : "unstar.view"), "id=" + item.id], function(body, err) {
      if (!err) _applyStarred(item.id, next)
    })
  }

  // Reflects a star/unstar everywhere that item might currently be shown —
  // whichever tab cache, the search results, the current drill-down frame,
  // and the play queue.
  function _applyStarred(id, starred) {
    function withStarred(it, value) {
      var copy = {}
      for (var k in it) copy[k] = it[k]
      copy.starred = value ? "1" : ""
      return copy
    }
    function patch(list) {
      return list.map(function(it) { return it && it.id === id ? withStarred(it, starred) : it })
    }
    tabAlbums = patch(tabAlbums)
    tabArtists = patch(tabArtists)
    tabPlaylists = patch(tabPlaylists)
    tabFavorites = { artists: patch(tabFavorites.artists), albums: patch(tabFavorites.albums), songs: patch(tabFavorites.songs) }
    searchResults = { artists: patch(searchResults.artists), albums: patch(searchResults.albums), songs: patch(searchResults.songs) }
    if (topFrame) replaceTopFrame(topFrame.kind, topFrame.id, topFrame.title, patch(topFrame.items))
    queue = patch(queue)
    if (_unshuffledQueue) _unshuffledQueue = patch(_unshuffledQueue)
    if (queueMetadataAvailable) _saveQueueState(queue)
  }

  // --- cover art -----------------------------------------------------------

  // Pure lookup — does not itself trigger a fetch, so it's safe to use
  // directly in a property binding. Callers request the fetch explicitly
  // (typically from Component.onCompleted on the row that wants it) via
  // requestCover(); once it lands, coverCache changes and any binding that
  // reads coverSource() re-evaluates on its own.
  function coverSource(coverArtId, size) {
    if (!coverArtId) return ""
    var path = coverCache[coverArtId + ":" + size]
    return path ? ("file://" + path) : ""
  }

  function requestCover(coverArtId, size) {
    if (!coverArtId) return
    var key = coverArtId + ":" + size
    if (coverCache[key] !== undefined) return
    var next = {}
    for (var k in coverCache) next[k] = coverCache[k]
    next[key] = ""
    coverCache = next
    _coverQueue.push({ id: coverArtId, size: size, key: key })
    _drainCoverQueue()
  }

  // --- playback --------------------------------------------------------------
  // mpv's own playlist is the queue: load-queue hands it every track's
  // stream URL up front, so its native playlist-next/prev (and therefore
  // MPRIS Next/Previous — what hardware media keys and `playerctl` actually
  // call) work correctly. `queueIndex` isn't tracked optimistically; the
  // status poll reads mpv's real `playlist-pos` back and that's what moves
  // `queueIndex`, so in-app buttons, media keys, and playerctl all stay in
  // sync through the same source of truth.

  // Bumped on every playFrom call; an in-flight call's async steps check
  // their own generation against this before applying anything, so clicking
  // a second track while the first is still loading (a real possibility —
  // mpv's very first cold start can take a couple of seconds) makes the
  // second click *win* instead of being silently dropped, or worse, having
  // the first click's now-stale result land after it and clobber the
  // second track's state. Previously this used a plain `loading` guard that
  // rejected the second click outright, which looked exactly like "clicking
  // any track plays the wrong one" — the click wasn't misrouted, it was
  // just ignored with no feedback.
  property int _playGen: 0

  function _discardPendingPlaybackRuns() {
    loadProcess._pending = null
    playQueueProcess._pending = null
  }

  // Interleaves urls with each song's title label for dromify-player
  // load-queue, which bakes each one in as that playlist entry's own
  // force-media-title — see the long comment on cmd_load_queue for why
  // that beats setting the current title reactively after a skip. Just
  // the title, not "Artist – Title": mpv-mpris's own Artist tag is synced
  // just as correctly (same per-file timing), and the system media widget
  // appends it after this title itself, so folding the artist in here too
  // made it show up twice.
  // Builds the stdin payload for dromify-player load-queue / reorder-tail:
  // url and title on their own lines, one pair per track. The stream URLs
  // carry the Subsonic salt+token, so they go over stdin, never argv (see
  // _runLatest). Titles are forced onto a single line — they're only a
  // cosmetic force-media-title, and a newline would desync the pairing.
  function _queuePayload(songs, urls) {
    var lines = []
    for (var i = 0; i < urls.length; i++) {
      var title = songs[i] ? Model.nowPlayingLabel(songs[i]) : ""
      lines.push(urls[i])
      lines.push(String(title).replace(/[\r\n]+/g, " "))
    }
    return lines.join("\n")
  }

  // Persist only queue metadata; authenticated stream URLs never enter the state file.
  function _queueMetadata(songs) {
    return songs.map(function(song) {
      return {
        id: String(song.id || ""),
        title: String(song.title || ""),
        artist: String(song.artist || ""),
        album: String(song.album || ""),
        coverArt: String(song.coverArt || ""),
        duration: Number(song.duration) || 0,
        starred: !!song.starred
      }
    })
  }

  function _queueStatePayload(songs) {
    var saveShuffle = shuffleEnabled && Array.isArray(_unshuffledQueue)
    return JSON.stringify({
      queue: _queueMetadata(songs),
      shuffleEnabled: saveShuffle,
      unshuffledQueue: saveShuffle ? _queueMetadata(_unshuffledQueue) : []
    })
  }

  function _sameQueueIds(first, second) {
    if (!Array.isArray(first) || !Array.isArray(second) || first.length !== second.length) return false
    var counts = ({})
    for (var i = 0; i < first.length; i++) {
      var firstId = first[i] ? first[i].id : ""
      if (typeof firstId !== "string" || firstId === "") return false
      var firstKey = "$" + firstId
      counts[firstKey] = (counts[firstKey] || 0) + 1
    }
    for (var j = 0; j < second.length; j++) {
      var secondId = second[j] ? second[j].id : ""
      if (typeof secondId !== "string" || secondId === "") return false
      var secondKey = "$" + secondId
      if (!counts[secondKey]) return false
      counts[secondKey]--
    }
    return true
  }

  function _saveQueueState(songs) {
    _pendingQueueState = { operation: "save", payload: _queueStatePayload(songs) }
    _flushQueueState()
  }

  function _clearQueueState() {
    _pendingQueueState = { operation: "clear", payload: "" }
    _flushQueueState()
  }

  function _flushQueueState() {
    if (queueStateProcess.running || !_pendingQueueState) return
    var next = _pendingQueueState
    _pendingQueueState = null
    queueStateProcess._operation = next.operation
    queueStateProcess._input = next.payload
    queueStateProcess.command = [playerBin, next.operation === "clear" ? "clear-queue-state" : "save-queue-state"]
    queueStateProcess.running = true
  }

  function _safeStatusText(value) {
    return String(value || "").replace(/[\r\n]+/g, " ").slice(0, 512)
  }

  function restorePlayback() {
    var gen = _playGen
    _run(restoreProcess, [playerBin, "restore"], function(snapshot) {
      if (!restoreOnStartup || gen !== _playGen || !snapshot || !snapshot.status) return
      var status = snapshot.status
      repeatMode = status.repeatMode === "one" || status.repeatMode === "all" ? status.repeatMode : "off"
      shuffleEnabled = false
      _unshuffledQueue = null
      var pos = Math.floor(Number(status.playlistPos))
      var count = Math.floor(Number(status.playlistCount))
      if (status.running !== true || status.idle === true || !isFinite(pos) || !isFinite(count) || pos < 0 || count < 1 || pos >= count) return

      var savedQueue = Array.isArray(snapshot.queue) ? snapshot.queue : []
      queueMetadataAvailable = savedQueue.length === count && savedQueue.every(function(song) {
        return song && typeof song.id === "string" && song.id !== ""
      })
      var savedUnshuffledQueue = Array.isArray(snapshot.unshuffledQueue) ? snapshot.unshuffledQueue : []
      var restoreShuffle = queueMetadataAvailable && snapshot.shuffleEnabled === true
        && _sameQueueIds(savedQueue, savedUnshuffledQueue)
      shuffleEnabled = restoreShuffle
      _unshuffledQueue = restoreShuffle ? savedUnshuffledQueue : null
      fallbackPlaylistCount = count
      queue = queueMetadataAvailable ? savedQueue : []
      fallbackCurrentSong = queueMetadataAvailable ? null : {
        id: "",
        title: _safeStatusText(status.mediaTitle),
        artist: _safeStatusText(status.artist)
      }
      queueIndex = pos
      position = Number(status.position) || 0
      duration = Number(status.duration) || 0
      var restoredVolume = Number(status.volume)
      volume = isFinite(restoredVolume) ? Math.round(restoredVolume) : 100
      audioCodec = status.audioCodec || ""
      audioBitrate = Number(status.audioBitrate) || 0
      paused = status.paused === true
      playing = status.running === true && !paused
      if (currentSong && (currentSong.title || currentSong.artist))
        console.info("dromify: restored now playing state repeat=" + repeatMode + " shuffle=" + shuffleEnabled)
      pollTimer.start()
    })
  }

  // Plays `songs[startIndex]`, queuing the rest of `songs` behind it as the
  // play queue (an album, a playlist, search results, ...).
  function playFrom(songs, startIndex) {
    if (!songs || startIndex < 0 || startIndex >= songs.length) return
    // A shuffled order only means something relative to the queue it came
    // from; starting a new one (a different album, a fresh search, ...)
    // makes that stale, so drop it rather than carry a shuffle flag that
    // no longer refers to anything real.
    shuffleEnabled = false
    _unshuffledQueue = null
    _discardPendingPlaybackRuns()
    var gen = ++_playGen
    loading = true
    queueMetadataAvailable = true
    fallbackCurrentSong = null
    fallbackPlaylistCount = 0
    queue = songs
    queueIndex = startIndex
    var ids = songs.map(function(s) { return s.id })
    _runLatest(loadProcess, [apiBin, "urls", "stream.view"].concat(ids), function(urlsOut, err) {
      if (gen !== _playGen) return
      if (err || !urlsOut) { lastError = err || "could not build stream URLs"; loading = false; return }
      var urls = String(urlsOut).split("\n").map(function(u) { return u.trim() }).filter(function(u) { return u !== "" })
      if (urls.length === 0) { lastError = "could not build stream URLs"; loading = false; return }
      _runLatest(playQueueProcess,
                 [playerBin, "load-queue", String(startIndex), String(urls.length)],
                 function(ok) {
        if (gen !== _playGen) return
        loading = false
        if (ok === false) { lastError = "player could not load queue"; return }
        paused = false
        playing = true
        _saveQueueState(queue)
        pollTimer.restart()
      }, _queuePayload(songs, urls))
      _apiGet(["scrobble.view", "id=" + songs[startIndex].id, "submission=false"], function() {})
    })
  }

  function togglePause() {
    if (queueIndex < 0) return
    _run(playerCtlProcess, [playerBin, "toggle-pause"], function() { pollNow() })
  }

  // These just nudge mpv's own playlist ("weak", so running off either end
  // is a no-op unless repeat-all wraps it); the poll timer picks up
  // wherever mpv actually lands within ~800ms and updates queueIndex from
  // that. Nothing here needs to relabel the title — every entry already
  // carries its own correct one, baked in when the queue was loaded.
  function next() {
    if (queueMetadataAvailable ? queue.length === 0 : fallbackPlaylistCount < 2) return
    _run(playerCtlProcess, [playerBin, "next"], function() { pollNow() })
  }

  function previous() {
    if (queueMetadataAvailable ? queue.length === 0 : fallbackPlaylistCount < 2) return
    _run(playerCtlProcess, [playerBin, "previous"], function() { pollNow() })
  }

  function cycleRepeat() {
    repeatMode = repeatMode === "off" ? "all" : (repeatMode === "all" ? "one" : "off")
    _run(playerCtlProcess, [playerBin, "set-repeat", repeatMode], function() {})
  }

  function toggleShuffle() {
    if (!queueMetadataAvailable || queueIndex < 0 || queue.length === 0) return
    var newQueue, newIndex

    if (!shuffleEnabled) {
      _unshuffledQueue = queue.slice()
      var head = queue.slice(0, queueIndex + 1)
      var tail = queue.slice(queueIndex + 1)
      // Fisher-Yates over just the not-yet-played tail.
      for (var i = tail.length - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1))
        var tmp = tail[i]; tail[i] = tail[j]; tail[j] = tmp
      }
      newQueue = head.concat(tail)
      newIndex = queueIndex
      shuffleEnabled = true
    } else {
      // Keep the played prefix in its actual order. mpv only lets us replace
      // the playlist tail, so the current song must stay at queueIndex.
      newQueue = queue.slice(0, queueIndex + 1)
      var playedIds = ({})
      for (var k = 0; k < newQueue.length; k++) {
        var playedKey = "$" + String(newQueue[k].id || "")
        playedIds[playedKey] = (playedIds[playedKey] || 0) + 1
      }
      var originalQueue = _unshuffledQueue || queue
      var upcoming = []
      for (var m = 0; m < originalQueue.length; m++) {
        var originalSong = originalQueue[m]
        var originalKey = "$" + String(originalSong.id || "")
        if (playedIds[originalKey]) playedIds[originalKey]--
        else upcoming.push(originalSong)
      }
      newQueue = newQueue.concat(upcoming)
      newIndex = queueIndex
      _unshuffledQueue = null
      shuffleEnabled = false
    }
    _reorderTail(newQueue, newIndex)
  }

  // Rewrites just the not-yet-played tail of mpv's own playlist to match a
  // reordered `queue` — used by toggleShuffle — leaving history and
  // whatever's actually playing completely untouched. A full load-queue
  // reload (a "replace" loadfile on the head) closes and reopens the
  // currently playing stream just to re-register titles it already has —
  // an audible pause on every toggle, and previously a restart to 0 too,
  // since loadfile always starts its target entry from position 0.
  // dromify-player's reorder-tail instead strips whatever mpv's playlist
  // has after its own current position and appends the new tail fresh, so
  // mpv never issues a loadfile for the entry it's already playing.
  function _reorderTail(newQueue, newIndex) {
    _discardPendingPlaybackRuns()
    var gen = ++_playGen
    queueMetadataAvailable = true
    fallbackCurrentSong = null
    fallbackPlaylistCount = 0
    queue = newQueue
    queueIndex = newIndex
    var tail = newQueue.slice(newIndex + 1)
    loading = true
    if (tail.length === 0) {
      _runLatest(playQueueProcess, [playerBin, "reorder-tail", "0"], function(ok) {
        if (gen !== _playGen) return
        loading = false
        if (ok === false) { lastError = "player could not update queue"; return }
        _saveQueueState(queue)
      }, "")
      return
    }
    var ids = tail.map(function(s) { return s.id })
    _runLatest(loadProcess, [apiBin, "urls", "stream.view"].concat(ids), function(urlsOut, err) {
      if (gen !== _playGen) return
      if (err || !urlsOut) { lastError = err || "could not build stream URLs"; loading = false; return }
      var urls = String(urlsOut).split("\n").map(function(u) { return u.trim() }).filter(function(u) { return u !== "" })
      if (urls.length === 0) { lastError = "could not build stream URLs"; loading = false; return }
      _runLatest(playQueueProcess,
                 [playerBin, "reorder-tail", String(urls.length)],
                 function(ok) {
        if (gen !== _playGen) return
        loading = false
        if (ok === false) { lastError = "player could not update queue"; return }
        _saveQueueState(queue)
      }, _queuePayload(tail, urls))
    })
  }

  function seekFraction(fraction) {
    if (duration <= 0) return
    var secs = Math.max(0, Math.min(duration, fraction * duration))
    _run(playerCtlProcess, [playerBin, "seek", String(Math.round(secs))], function() {})
  }

  function setVolume(v) {
    volume = v
    _run(playerCtlProcess, [playerBin, "volume", String(Math.round(v))], function() {})
  }

  function stopPlayback() {
    _discardPendingPlaybackRuns()
    ++_playGen
    loading = false
    pollTimer.stop()
    queue = []
    queueIndex = -1
    queueMetadataAvailable = false
    fallbackCurrentSong = null
    fallbackPlaylistCount = 0
    shuffleEnabled = false
    _unshuffledQueue = null
    _clearQueueState()
    playing = false
    paused = true
    position = 0
    duration = 0
    _runLatest(playQueueProcess, [playerBin, "stop"], function() {}, "")
  }

  function pollNow() {
    if (queueIndex < 0 || statusPollProcess.running) return
    // Tags this poll with the play generation active right now, so if a
    // newer playFrom starts before this poll's `dromify-player status`
    // subprocess returns, the (by then stale) result gets discarded instead
    // of applied — see the onExited handler below for why that matters.
    statusPollProcess._gen = _playGen
    statusPollProcess.command = [playerBin, "status"]
    statusPollProcess.running = true
  }

  Timer {
    id: pollTimer
    interval: 800
    repeat: true
    running: false
    onTriggered: root.pollNow()
  }

  Process {
    id: statusPollProcess
    property int _gen: 0
    running: false
    stdout: StdioCollector { id: pollOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      // Dispatched before a newer playFrom started; its result reflects
      // mpv's state *before* the new track's load-queue landed — applying
      // it now would show the old track again for one poll tick right
      // after the new one had already appeared, then flip back. This is
      // what caused that flicker: not a poll interval issue, a stale
      // response from a request that was already in flight when the click
      // happened, landing after the optimistic queue/queueIndex update.
      if (statusPollProcess._gen !== root._playGen) return
      // Narrower version of the same problem: a poll dispatched *after* the
      // generation bump can still reach mpv before load-queue's own IPC
      // commands do (there's no ordering guarantee between two independent
      // subprocesses), so its data is genuinely mpv's old state even though
      // the generation matches. `loading` covers this — it's only false
      // once load-queue's process has actually exited, by which point mpv
      // has processed those commands. Skip the whole update rather than
      // just the queueIndex sync: position/duration for the old track
      // would be just as misleading to show for that one tick.
      if (root.loading) return
      var data = null
      try { data = JSON.parse(pollOut.text) } catch (e) { return }
      if (!data) return
      root.paused = data.paused === true
      root.playing = data.running === true && data.paused !== true
      root.position = Number(data.position) || 0
      root.duration = Number(data.duration) || 0
      if (data.volume !== undefined) root.volume = Math.round(Number(data.volume))
      root.audioCodec = data.audioCodec || ""
      root.audioBitrate = Number(data.audioBitrate) || 0
      if (data.repeatMode === "off" || data.repeatMode === "all" || data.repeatMode === "one")
        root.repeatMode = data.repeatMode

      if (data.running !== true || data.idle === true) {
        root.queue = []
        root.queueIndex = -1
        root.queueMetadataAvailable = false
        root.fallbackCurrentSong = null
        root.fallbackPlaylistCount = 0
        root.shuffleEnabled = false
        root._unshuffledQueue = null
        root._clearQueueState()
        pollTimer.stop()
        return
      }

      // mpv's playlist-pos is the one source of truth for "what's playing" —
      // it moves the same way whether the track changed because of an
      // in-app button, a media key, `playerctl`, or mpv auto-advancing. With
      // a metadata-backed queue, follow it and scrobble each track; without
      // one, refresh only the current title/artist from mpv.
      var pos = data.playlistPos !== undefined ? Number(data.playlistPos) : -1
      if (!root.queueMetadataAvailable && pos >= 0) {
        var count = Math.floor(Number(data.playlistCount))
        if (count > 0) root.fallbackPlaylistCount = count
        if (pos < root.fallbackPlaylistCount) {
          root.queueIndex = pos
          var priorSong = root.fallbackCurrentSong || {}
          var title = root._safeStatusText(data.mediaTitle)
          var artist = root._safeStatusText(data.artist)
          if (priorSong.title !== title || priorSong.artist !== artist)
            root.fallbackCurrentSong = { id: "", title: title, artist: artist }
        }
      } else if (root.queueMetadataAvailable && pos >= 0 && pos !== root.queueIndex && pos < root.queue.length) {
        var finishedSong = root.currentSong
        root.queueIndex = pos
        if (finishedSong && finishedSong.id) _apiGet(["scrobble.view", "id=" + finishedSong.id, "submission=true"], function() {})
        if (root.currentSong && root.currentSong.id) _apiGet(["scrobble.view", "id=" + root.currentSong.id, "submission=false"], function() {})
      }
    }
  }

  // --- generic API job queue -------------------------------------------------

  property var _apiQueue: []
  property bool _apiBusy: false

  function _apiGet(args, callback) {
    _apiQueue.push({ args: args, cb: callback })
    _drainApiQueue()
  }

  function _drainApiQueue() {
    if (_apiBusy || _apiQueue.length === 0) return
    _apiBusy = true
    var job = _apiQueue.shift()
    apiProcess._cb = job.cb
    apiProcess.command = [apiBin, "get"].concat(job.args)
    apiProcess.running = true
  }

  Process {
    id: apiProcess
    property var _cb: null
    running: false
    stdout: StdioCollector { id: apiOut; waitForEnd: true }
    stderr: StdioCollector { id: apiErr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = apiProcess._cb
      apiProcess._cb = null
      root._apiBusy = false
      if (exitCode === 0) {
        var data = null
        if (root._overSized(apiOut.text)) {
          root.lastError = "server response too large"
          if (cb) cb(null, root.lastError)
          Qt.callLater(root._drainApiQueue)
          return
        }
        try { data = JSON.parse(apiOut.text) } catch (e) { /* leave null */ }
        if (cb) cb(data, "")
      } else {
        var msg = String(apiErr.text || "request failed").replace(/^dromify-api:\s*/, "").trim()
        root.lastError = msg
        if (cb) cb(null, msg)
      }
      Qt.callLater(root._drainApiQueue)
    }
  }

  // --- cover art job queue -----------------------------------------------

  property var _coverQueue: []
  property bool _coverBusy: false

  function _drainCoverQueue() {
    if (_coverBusy || _coverQueue.length === 0) return
    _coverBusy = true
    var job = _coverQueue.shift()
    coverProcess._key = job.key
    coverProcess.command = [apiBin, "cover", job.id, String(job.size)]
    coverProcess.running = true
  }

  Process {
    id: coverProcess
    property string _key: ""
    running: false
    stdout: StdioCollector { id: coverOut; waitForEnd: true }
    onExited: function(exitCode) {
      root._coverBusy = false
      if (exitCode === 0) {
        var path = String(coverOut.text || "").trim()
        var next = {}
        for (var k in root.coverCache) next[k] = root.coverCache[k]
        next[coverProcess._key] = path
        root.coverCache = next
      }
      Qt.callLater(root._drainCoverQueue)
    }
  }

  // --- one-shot helpers ------------------------------------------------------

  // Runs a one-shot Process, stashing `callback` on it so the Process's own
  // onExited handler (each parses its stdout differently — JSON body, raw
  // URL string, or nothing at all) can hand back its result. If `proc` is
  // still busy with a previous call, this one is dropped rather than
  // clobbering the in-flight call's command/callback (several of these
  // Processes — playerCtlProcess especially — are shared across multiple
  // user actions that can fire in quick succession, like spamming play/pause).
  function _run(proc, command, callback) {
    if (proc.running) return false
    proc._cb = callback
    proc.command = command
    proc.running = true
    return true
  }

  // Like _run, but keeps the server password off argv (world-readable via
  // /proc/<pid>/cmdline). Playback URLs use _runLatest, which applies same
  // stdin handling while also serializing newer requests.
  function _runWithSecret(proc, command, secret, callback) {
    if (proc.running) return false
    proc._cb = callback
    proc._secret = secret
    proc.command = command
    proc.running = true
    return true
  }

  // Playback requests are latest-wins: while one subprocess runs, retain
  // newest request and start it as soon as current request exits. `secret`
  // stays off argv and is written to stdin by the process's onStarted handler.
  function _runLatest(proc, command, callback, secret) {
    var request = { command: command, callback: callback, secret: secret }
    if (proc.running || proc._pending) {
      proc._pending = request
      return true
    }
    _startLatestRun(proc, request)
    return true
  }

  function _startLatestRun(proc, request) {
    proc._cb = request.callback
    if (request.secret !== undefined) proc._secret = request.secret
    proc.command = request.command
    proc.running = true
  }

  function _drainLatestRun(proc) {
    if (proc.running || !proc._pending) return
    var request = proc._pending
    proc._pending = null
    _startLatestRun(proc, request)
  }

  Process {
    id: statusProcess
    property var _cb: null
    running: false
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = statusProcess._cb; statusProcess._cb = null
      var data = null
      try { data = JSON.parse(statusOut.text) } catch (e) {}
      if (cb) cb(data, exitCode === 0 ? "" : String(statusErr.text || "").trim())
    }
  }

  // Shared by configure/switch/rename/relogin. configure and relogin carry a
  // password: it's written to the child's stdin from onStarted (see
  // _runWithSecret) rather than passed in `command`, so it never appears in
  // argv / /proc. switch and rename leave _secret "" and write nothing; the
  // dromify-api subcommands they call don't read stdin.
  Process {
    id: configureProcess
    property var _cb: null
    property string _secret: ""
    stdinEnabled: true
    running: false
    stdout: StdioCollector { id: configureOut; waitForEnd: true }
    stderr: StdioCollector { id: configureErr; waitForEnd: true }
    onStarted: {
      if (configureProcess._secret !== "") {
        configureProcess.write(configureProcess._secret + "\n")
        configureProcess._secret = ""
      }
    }
    onExited: function(exitCode) {
      configureProcess._secret = ""
      var cb = configureProcess._cb; configureProcess._cb = null
      if (exitCode !== 0) {
        if (cb) cb(null, String(configureErr.text || "").replace(/^dromify-api:\s*/, "").trim())
        return
      }
      var data = null
      try { data = JSON.parse(configureOut.text) } catch (e) {}
      if (cb) cb(data, "")
    }
  }

  Process {
    id: forgetProcess
    property var _cb: null
    running: false
    stdout: StdioCollector { id: forgetOut; waitForEnd: true }
    stderr: StdioCollector { id: forgetErr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = forgetProcess._cb; forgetProcess._cb = null
      if (exitCode !== 0) {
        if (cb) cb(null, String(forgetErr.text || "").replace(/^dromify-api:\s*/, "").trim())
        return
      }
      var data = null
      try { data = JSON.parse(forgetOut.text) } catch (e) {}
      if (cb) cb(data, "")
    }
  }

  Process {
    id: loadProcess
    property var _cb: null
    property var _pending: null
    running: false
    stdout: StdioCollector { id: loadOut; waitForEnd: true }
    stderr: StdioCollector { id: loadErr; waitForEnd: true }
    onExited: function(exitCode) {
      var cb = loadProcess._cb; loadProcess._cb = null
      if (exitCode === 0 && root._overSized(loadOut.text)) {
        if (cb) cb("", "stream URL list too large")
      } else if (cb) {
        cb(exitCode === 0 ? loadOut.text : "", exitCode === 0 ? "" : String(loadErr.text || "").trim())
      }
      Qt.callLater(function() { root._drainLatestRun(loadProcess) })
    }
  }

  Process {
    id: playerCtlProcess
    property var _cb: null
    running: false
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var cb = playerCtlProcess._cb; playerCtlProcess._cb = null
      if (cb) cb()
    }
  }

  Process {
    id: restoreProcess
    property var _cb: null
    running: false
    stdout: StdioCollector { id: restoreOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var cb = restoreProcess._cb; restoreProcess._cb = null
      if (exitCode !== 0 || root._overSized(restoreOut.text)) { if (cb) cb(null); return }
      var data = null
      try { data = JSON.parse(restoreOut.text) } catch (e) {}
      if (cb) cb(data)
    }
  }

  Process {
    id: queueStateProcess
    property string _operation: ""
    property string _input: ""
    stdinEnabled: true
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      if (queueStateProcess._operation === "save") queueStateProcess.write(queueStateProcess._input + "\n")
      queueStateProcess._input = ""
    }
    onExited: function(exitCode) {
      queueStateProcess._operation = ""
      if (exitCode !== 0) console.warn("dromify: unable to persist playback queue metadata")
      root._flushQueueState()
    }
  }

  // Separate from playerCtlProcess so a track load never contends with an
  // unrelated transport call (pause/seek/volume/next/previous) sharing the
  // same Process object and getting silently dropped by _run's busy guard.
  // Driven via _runLatest: while busy, newest request replaces pending one.
  // Queue URLs carry the Subsonic token; onStarted writes them to stdin,
  // never argv.
  Process {
    id: playQueueProcess
    property var _cb: null
    property var _pending: null
    property string _secret: ""
    stdinEnabled: true
    running: false
    stdout: StdioCollector { waitForEnd: true }
    onStarted: {
      if (playQueueProcess._secret !== "") {
        playQueueProcess.write(playQueueProcess._secret + "\n")
        playQueueProcess._secret = ""
      }
    }
    onExited: function(exitCode) {
      playQueueProcess._secret = ""
      var cb = playQueueProcess._cb; playQueueProcess._cb = null
      if (cb) cb(exitCode === 0)
      Qt.callLater(function() { root._drainLatestRun(playQueueProcess) })
    }
  }

  // Fire-and-forget: spawns mpv in the background as soon as we know we're
  // configured, rather than waiting for the first track click. mpv's cold
  // start can take a couple of seconds; doing it here means that wait
  // happens quietly up front instead of stalling — and shrinking the window
  // for — the first real playFrom.
  Process {
    id: warmupProcess
    running: false
    stdout: StdioCollector { waitForEnd: true }
  }
  function _warmUpPlayer() {
    if (warmupProcess.running) return
    warmupProcess.command = [playerBin, "ensure"]
    warmupProcess.running = true
  }

  Component.onCompleted: {
    refreshStatus(function(data) {
      if (data && data.configured) _warmUpPlayer()
    })
    if (restoreOnStartup) restorePlayback()
  }
}
