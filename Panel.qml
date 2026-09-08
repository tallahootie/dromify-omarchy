import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "tallahootie.dromify"
  ipcTarget: "tallahootie.dromify"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  // Dim by default; the bar pill lights this up to Color.accent instead
  // while something is actually playing.
  readonly property color barIconColor: Qt.darker(barForeground, 1.55)

  // One Service instance is shared by every monitor's copy of this bar
  // widget (the shell instantiates "service"-kind plugins once, globally —
  // see manifest.json). Without this, each monitor's Panel.qml used to
  // create its own separate Service, each with its own idea of what was
  // playing; they all controlled the same single mpv process underneath,
  // so playing a track on one screen looked like it "randomly paused" the
  // track showing as playing on the other.
  //
  // The shared lookup can be transiently null right after a plugin reload
  // (the shell doesn't guarantee the service is recreated before this
  // bar-widget's own bindings first evaluate), so _localNav is a private
  // fallback instance that's never null — nav uses it only until the
  // shared one shows up, at which point every binding here re-evaluates
  // and switches over on its own.
  readonly property var nav: (bar && bar.shell && bar.shell.firstPartyServiceFor("tallahootie.dromify")) || _localNav
  Service { id: _localNav }

  // --- per-instance keyboard focus / scroll ---------------------------------
  // Everything about *what* is being browsed (tabs, drill-down, search,
  // settings, cursor position) lives on the shared `nav` now — see
  // Service.qml — so every screen's panel shows the same thing. What stays
  // here is purely visual and inherently per-window: scrolling this
  // screen's own Flickable to keep the (shared) cursor position in view,
  // and this screen's own keyboard focus.

  function goBackOrClose() {
    // Search sits on top of the drill stack (see the `rows` binding in
    // Service.qml), so Back peels the search off first, then walks the
    // stack, then closes.
    if (nav.searchActive) nav.searchQuery = ""
    else if (nav.stack.length > 0) nav.popFrame()
    else root.close()
  }

  function scrollCursorIntoView() {
    if (nav.focusSection !== "list" || !listColumn) return
    Qt.callLater(function() {
      // listIndex counts only navigable (non-header) rows; map it back to
      // its position in the full `rows` array (which listColumn's Repeater
      // mirrors 1:1, headers included) to find the matching child.
      var target = nav.navigableRows[nav.listIndex]
      var childIndex = target !== undefined ? nav.rows.indexOf(target) : -1
      var item = childIndex >= 0 ? listColumn.children[childIndex] : null
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  Connections {
    target: nav
    // Mouse hover over a row also moves listIndex/focusSection (so the
    // keyboard-cursor highlight tracks the pointer too), but it must not
    // also yank the scroll position — that's what made hovering near the
    // top/bottom edge of the list feel like it was auto-scrolling under
    // the cursor. keyboardActive is only true while an actual keyboard
    // move is in flight (set at the top of moveCursor, before listIndex
    // changes; cleared by any real mouse movement), so it's a reliable
    // "was this a keyboard move?" check here.
    function onListIndexChanged() { if (nav.keyboardActive) root.scrollCursorIntoView() }
    function onFocusSectionChanged() { if (nav.keyboardActive) root.scrollCursorIntoView() }
  }

  // --- connect form ------------------------------------------------------

  property string editingProfileId: ""
  property string editName: ""
  property string formName: ""
  property string formServer: ""
  property string formUser: ""
  property string formPass: ""

  function submitConnect() {
    nav.configure(formName, formServer, formUser, formPass, function(ok, err) {
      if (ok) {
        formName = ""
        formServer = ""
        formUser = ""
        formPass = ""
        nav.addingServer = false
        nav.showSettings = false
        nav.resetBrowseState()
        nav.switchTab("albums")
      }
    })
  }

  // --- lifecycle -----------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    nav.cursorActive = false
    nav.focusSection = nav.searchActive ? "search" : "tabs"
    nav.refreshStatus(function() {
      if (!nav.configured) nav.showSettings = true
      else if (!nav.loadedTabs[nav.activeTab]) nav.ensureTabLoaded(nav.activeTab)
    })
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // --- bar pill --------------------------------------------------------------
  // Fixed-width: just the music-note icon, lit up in the accent colour while
  // something is actually playing (dim otherwise). A track-title label was
  // tried here but its length changes with every track, which kept
  // reflowing every other bar widget to its right — not worth it for a
  // pill whose panel already shows what's playing.

  Item {
    id: button
    implicitWidth: root.barSize
    implicitHeight: root.barSize

    Text {
      anchors.centerIn: parent
      text: "󰝚"
      color: (nav.playing && !nav.paused) ? Color.accent : root.barIconColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) nav.togglePause()
        else if (mouse.button === Qt.MiddleButton) nav.next()
        else root.toggle()
      }
    }
  }

  // --- popup content -----------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Matches the width of the stock Omarchy panels (audio, network,
    // display, …), which all pass Style.space(380) here.
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!nav.cursorActive) { nav.cursorActive = true; return }
        nav.moveCursor(dx, dy)
      }
      onActivateRequested: if (nav.cursorActive) nav.activateCursor()
      onCloseRequested: root.goBackOrClose()
      onTextKey: function(t) {
        if (t === "/") { searchField.forceActiveFocus() }
        else if ((t === "f" || t === "F") && nav.focusSection === "list") { nav.toggleCurrentFavorite() }
        else if (t === "r" || t === "R") nav.refreshCurrent()
      }

      ColumnLayout {
        id: column
        // NOT panel.contentWidth — that's the popup's full outer width,
        // before its own padding/border insets are subtracted. This
        // column's real parent (keyCatcher, anchors.fill: parent) already
        // sits inside that inset content area, so matching *its* width is
        // what keeps everything inside the visible card instead of
        // overflowing past the right edge (which is what was clipping the
        // settings gear entirely and crowding the stars against the border).
        width: parent.width
        spacing: Style.space(10)

        // header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
              text: "Dromify"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              Layout.alignment: Qt.AlignVCenter
            }
            Text {
              text: "for Omarchy"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              Layout.alignment: Qt.AlignVCenter
              Layout.fillWidth: true
              Layout.minimumWidth: 0
            }
          }

          // The active server's name, doubling as a link that opens its web
          // UI in the default browser (omarchy-launch-browser honours
          // xdg-settings). Signing in there is a one-time thing — the web
          // UI keeps its own session afterwards — so this just opens the
          // page; the password is copied on demand from the gear/settings
          // view instead.
          Text {
            id: serverLink
            visible: nav.configured && !nav.showSettings && nav.activeProfile
                     && !!nav.activeProfile.serverURL
            text: (nav.activeProfile ? nav.activeProfile.name : "") + "  󰏌"
            color: serverLinkArea.containsMouse ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: serverLinkArea.containsMouse
            elide: Text.ElideMiddle
            Layout.maximumWidth: Style.space(220)
            Layout.alignment: Qt.AlignVCenter

            MouseArea {
              id: serverLinkArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: nav.openServerInBrowser()

              PanelToolTip {
                visible: serverLinkArea.containsMouse
                text: "Open " + (nav.activeProfile ? nav.activeProfile.serverURL : "") + " in browser"
              }
            }
          }

          PanelActionButton {
            iconText: nav.showSettings ? "󰁍" : "󰒓"
            tooltipText: nav.showSettings ? "Back to library" : "Server settings"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: nav.showSettings = !nav.showSettings
          }
        }

        // --- settings: server profiles + add-server form -------------------
        ColumnLayout {
          visible: nav.showSettings || !nav.configured
          Layout.fillWidth: true
          spacing: Style.space(10)

          PanelSectionHeader {
            visible: nav.profiles.length > 0
            text: "SERVERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
            Layout.fillWidth: true
          }

          ColumnLayout {
            visible: nav.profiles.length > 0
            Layout.fillWidth: true
            spacing: Style.space(6)

            Repeater {
              model: nav.profiles
              delegate: ProfileRow {
                required property var modelData
                profile: modelData
                Layout.fillWidth: true
              }
            }
          }

          Button {
            visible: nav.profiles.length > 0
            text: nav.addingServer ? "Cancel" : "Add another server"
            Layout.fillWidth: true
            onClicked: nav.addingServer = !nav.addingServer
          }

          ColumnLayout {
            visible: nav.addingServer || nav.profiles.length === 0
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              visible: nav.profiles.length === 0
              text: "Connect to your Navidrome or Subsonic server"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }

            TextField {
              id: nameField
              Layout.fillWidth: true
              placeholderText: "Name (e.g. Home)"
              text: root.formName
              onTextChanged: root.formName = text
              selectByMouse: true
            }
            TextField {
              id: serverField
              Layout.fillWidth: true
              placeholderText: "https://music.example.com"
              text: root.formServer
              onTextChanged: root.formServer = text
              selectByMouse: true
            }
            TextField {
              id: userField
              Layout.fillWidth: true
              placeholderText: "Username"
              text: root.formUser
              onTextChanged: root.formUser = text
              selectByMouse: true
            }
            TextField {
              id: passField
              Layout.fillWidth: true
              placeholderText: "Password"
              echoMode: TextInput.Password
              text: root.formPass
              onTextChanged: root.formPass = text
              selectByMouse: true
              Keys.onReturnPressed: root.submitConnect()
            }

            Text {
              visible: nav.lastError !== ""
              text: nav.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }

            Button {
              text: nav.connecting ? "Connecting…" : "Connect"
              enabled: !nav.connecting && root.formName !== "" && root.formServer !== "" && root.formUser !== "" && root.formPass !== ""
              Layout.fillWidth: true
              onClicked: root.submitConnect()
            }
          }
        }

        // --- connected content ----------------------------------------------
        ColumnLayout {
          visible: nav.configured && !nav.showSettings
          Layout.fillWidth: true
          spacing: Style.space(10)

          // Pinned right under the header — visible the moment the panel
          // opens, with no scrolling needed, rather than buried below a
          // long list.
          NowPlayingBar { visible: nav.currentSong; Layout.fillWidth: true }

          // The accordion toggle for the section below, sitting in the
          // middle of what would otherwise be a plain separator — the line
          // splits in two around it instead of a separate divider-then-button
          // stack. Only offered while something's playing, since collapsing
          // an already-empty Now Playing bar to save space makes no sense.
          RowLayout {
            visible: nav.currentSong
            Layout.fillWidth: true
            spacing: Style.space(8)

            // Plain Rectangles rather than two PanelSeparators: that
            // component binds its own width to parent.width (right for a
            // full-width divider, wrong for a half-width RowLayout cell).
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 1
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            }
            PanelActionButton {
              iconText: nav.browseCollapsed ? "󰅀" : "󰅃"
              tooltipText: nav.browseCollapsed ? "Show library" : "Hide library"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: nav.browseCollapsed = !nav.browseCollapsed
            }
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 1
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            }
          }

          // Collapses everything below Now Playing behind the toggle above
          // once something's actually playing. A plain Item's implicitHeight
          // (not height directly) is what ColumnLayout reads to size both
          // this cell and its own total implicitHeight — binding height
          // instead left the *popup's own* size (driven by the outer
          // column's implicitHeight, in the base KeyboardPanel) stuck at
          // whatever it was when opened, so the expanded list spilled out
          // past the card's border instead of the card growing to fit it.
          // `visible` only drops at a real zero height (matching the network
          // panel's band-pills collapse), which keeps this rendered for the
          // whole animation instead of snapping.
          Item {
            id: browseClip
            Layout.fillWidth: true
            clip: true
            readonly property bool expanded: !nav.currentSong || !nav.browseCollapsed
            visible: implicitHeight > 0
            implicitHeight: expanded ? browseColumn.implicitHeight : 0
            opacity: expanded ? 1 : 0

            Behavior on implicitHeight {
              NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
              NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }

            ColumnLayout {
              id: browseColumn
              width: browseClip.width
              spacing: Style.space(10)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                TextField {
                  id: searchField
                  Layout.fillWidth: true
                  placeholderText: "Search artists, albums, songs…"
                  text: nav.searchQuery
                  onTextChanged: nav.searchQuery = text
                  selectByMouse: true
                  onActiveFocusChanged: if (activeFocus) { nav.cursorActive = false; nav.focusSection = "search" }
                  // PanelKeyCatcher is `blocked` while this field has focus (so
                  // typing "j"/"f"/etc. isn't hijacked as a shortcut), which means
                  // this is the only way back to keyboard navigation of the panel.
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                  Keys.onDownPressed: {
                    nav.moveCursor(0, 1)
                    keyCatcher.forceActiveFocus()
                  }
                }

                PanelActionButton {
                  visible: nav.searchQuery !== ""
                  iconText: "󰅖"
                  tooltipText: "Clear search"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    nav.searchQuery = ""
                    keyCatcher.forceActiveFocus()
                  }
                }
              }

              RowLayout {
                visible: !nav.searchActive && nav.stack.length === 0
                Layout.fillWidth: true
                spacing: Style.space(6)

                Repeater {
                  model: [["albums", "Albums"], ["artists", "Artists"], ["playlists", "Playlists"], ["favorites", "Favourites"]]
                  delegate: TabButton {
                    required property var modelData
                    required property int index
                    tab: modelData[0]
                    label: modelData[1]
                    tabIdx: index
                  }
                }
                Item { Layout.fillWidth: true }
              }

              RowLayout {
                // Hidden while a search is running even if the drill stack
                // is non-empty — the results below are global, so the
                // frame's own back-button + title would be misleading. The
                // stack is still there; clearing the query brings this back.
                visible: nav.stack.length > 0 && !nav.searchActive
                Layout.fillWidth: true
                spacing: Style.space(6)

                PanelActionButton {
                  iconText: "󰁍"
                  tooltipText: "Back"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: nav.popFrame()
                }
                Text {
                  text: nav.listTitle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }

              PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

              Flickable {
                id: panelFlick
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(listColumn.implicitHeight, Style.space(460))
                // Bumped so the empty-state text below centers in the panel's
                // body instead of sitting cramped just under the search field.
                Layout.minimumHeight: (nav.navigableRows.length === 0 && nav.rows.length === 0 && !nav.listLoading) ? Style.space(160) : Style.space(80)
                contentWidth: width
                contentHeight: listColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar { id: listScroll; policy: ScrollBar.AsNeeded }

                // These sit directly in the Flickable, so anchors.centerIn:
                // parent would center against *content* size (contentHeight,
                // tied to listColumn's near-zero height when empty) rather
                // than the visible frame — pinning the text to the top. Center
                // against the Flickable's own viewport dimensions instead.
                Text {
                  visible: nav.listLoading
                  x: (panelFlick.width - implicitWidth) / 2
                  y: (panelFlick.height - implicitHeight) / 2
                  text: "Loading…"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  visible: !nav.listLoading && nav.navigableRows.length === 0 && nav.rows.length === 0
                  x: (panelFlick.width - implicitWidth) / 2
                  y: (panelFlick.height - implicitHeight) / 2
                  text: nav.searchActive ? "No results" : "Nothing here yet"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Column {
                  id: listColumn
                  // Leave a gutter for the scrollbar while it's showing, so
                  // the keyboard-cursor row highlight (a full-width fill on
                  // each row) stops short of the bar instead of sliding
                  // under the thumb.
                  width: panelFlick.width - (listScroll.visible ? listScroll.width + Style.space(4) : 0)
                  spacing: Style.space(2)

                  Repeater {
                    model: nav.rows
                    delegate: Loader {
                      id: rowLoader
                      required property var modelData
                      width: listColumn.width
                      sourceComponent: modelData.type === "header" ? headerRowComp : itemRowComp
                      // A *live* binding, not a one-time snapshot: onLoaded only
                      // fires the first time this delegate loads, but Repeater
                      // can reuse the same delegate for a different row later
                      // (e.g. the list shrinking then growing again as you
                      // navigate) and just update modelData on it — a plain
                      // `item.rowData = modelData` here would freeze rowData at
                      // whatever the row happened to be on first load, silently
                      // going stale. That's what made both the missing cursor
                      // highlight and clicking always playing the wrong track
                      // look like separate bugs — same cause, since both read
                      // rowData off the delegate.
                      onLoaded: {
                        item.rowData = Qt.binding(function() { return rowLoader.modelData })
                      }
                    }
                  }
                }

                Component { id: headerRowComp; HeaderRow {} }
                Component { id: itemRowComp; ItemRow {} }
              }
            }
          }
        }
      }
    }
  }


  component TabButton: CursorSurface {
    id: tabButton
    required property string tab
    required property string label
    required property int tabIdx

    hasCursor: nav.cursorActive && nav.focusSection === "tabs" && nav.tabIndex === tabIdx
    current: nav.activeTab === tab
    foreground: root.foreground
    implicitWidth: tabLabel.implicitWidth + Style.space(20)
    implicitHeight: tabLabel.implicitHeight + Style.space(14)
    // The active tab is marked by the underline below, not a background
    // fill — dropping CursorSurface's own "current" fill/border here so the
    // two don't compete; the keyboard-cursor hover fill (hasCursor) still
    // applies on top of that.
    color: hasCursor ? fill : "transparent"
    borderSpec: hasCursor ? Border.controlSpec("hover-cursor", foreground, accent) : Border.none()

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        if (nav.keyboardActive) return
        nav.cursorActive = true; nav.focusSection = "tabs"; nav.tabIndex = tabButton.tabIdx
      }
      onPositionChanged: nav.keyboardActive = false
      onClicked: nav.switchTab(tabButton.tab)
    }

    Text {
      id: tabLabel
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(2)
      text: tabButton.label
      color: tabButton.current ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: tabButton.current
    }

    // Active-tab indicator, sized to the label's own width so it reads as
    // "this word is selected" rather than a generic same-width-for-all bar.
    Rectangle {
      visible: tabButton.current
      color: Color.accent
      radius: height / 2
      height: Math.max(2, Style.space(2))
      width: tabLabel.implicitWidth
      anchors.horizontalCenter: tabLabel.horizontalCenter
      anchors.top: tabLabel.bottom
      anchors.topMargin: Style.space(4)
    }
  }

  component ProfileRow: ColumnLayout {
    id: profileRow
    required property var profile
    readonly property bool isActive: nav.activeProfile && nav.activeProfile.id === profile.id
    // A logged-out profile (see the logout button below) keeps its saved
    // name/server/username but has no password in the keyring, so it needs
    // a password prompt instead of a plain one-click switch.
    readonly property bool needsSignIn: profile.hasPassword === false
    readonly property bool isEditing: root.editingProfileId === profile.id
    Layout.fillWidth: true
    spacing: Style.space(6)

    function commitRename() {
      var name = root.editName.trim()
      if (name === "") return
      nav.renameProfile(profileRow.profile.id, name, function() { root.editingProfileId = "" })
    }

    function commitRelogin(password) {
      if (!password) return
      nav.relogin(profileRow.profile.id, password, function(ok) {
        if (ok) {
          nav.showSettings = false
          nav.resetBrowseState()
          nav.switchTab("albums")
        }
      })
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: profileRow.profile.name
            + (profileRow.isActive ? "  ·  Active" : (profileRow.needsSignIn ? "  ·  Signed out" : ""))
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: profileRow.isActive
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: profileRow.profile.username + "@" + String(profileRow.profile.serverURL).replace(/^https?:\/\//, "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: !profileRow.isActive && !profileRow.needsSignIn
        iconText: "󰓅"
        tooltipText: "Switch to this server"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: nav.switchProfile(profileRow.profile.id, function(ok) {
          if (ok) {
            nav.showSettings = false
            nav.resetBrowseState()
            nav.switchTab("albums")
          }
        })
      }
      PanelActionButton {
        iconText: "󰏫"
        tooltipText: "Rename"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: {
          root.editName = profileRow.profile.name
          root.editingProfileId = profileRow.isEditing ? "" : profileRow.profile.id
        }
      }
      PanelActionButton {
        visible: !profileRow.needsSignIn
        iconText: "󰆏"
        tooltipText: "Copy password"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: nav.copyProfilePassword(profileRow.profile.id)
      }
      PanelActionButton {
        visible: !profileRow.needsSignIn
        iconText: "󰍃"
        tooltipText: "Log out"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onClicked: nav.logoutProfile(profileRow.profile.id)
      }
      PanelActionButton {
        iconText: "󰆴"
        tooltipText: "Remove this server"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onClicked: nav.forgetProfile(profileRow.profile.id)
      }
    }

    RowLayout {
      visible: profileRow.isEditing
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(4)
      spacing: Style.space(6)

      TextField {
        Layout.fillWidth: true
        text: root.editName
        onTextChanged: root.editName = text
        selectByMouse: true
        Keys.onReturnPressed: profileRow.commitRename()
      }
      PanelActionButton {
        iconText: "󰄬"
        tooltipText: "Save"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: profileRow.commitRename()
      }
    }

    RowLayout {
      visible: profileRow.needsSignIn
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(4)
      spacing: Style.space(6)

      TextField {
        id: reloginField
        Layout.fillWidth: true
        placeholderText: "Password"
        echoMode: TextInput.Password
        selectByMouse: true
        Keys.onReturnPressed: profileRow.commitRelogin(text)
      }
      PanelActionButton {
        iconText: "󰌐"
        tooltipText: "Sign in"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: profileRow.commitRelogin(reloginField.text)
      }
    }
  }

  component HeaderRow: PanelSectionHeader {
    property var rowData: null
    foreground: root.foreground
    fontFamily: root.fontFamily
    text: rowData ? String(rowData.data) : ""
    width: parent ? parent.width : implicitWidth
  }

  component ItemRow: CursorSurface {
    id: itemRow
    property var rowData: null
    // By id, not indexOf(rowData) — reference equality between this row's
    // data and the shared nav.navigableRows array turns out not to hold up
    // (Quickshell's Repeater apparently doesn't hand a Loader's modelData
    // back as the literal same object reference as the source array
    // element, even though the values match) — indexOf silently returned
    // -1 for every row, which is why the cursor highlight never appeared.
    // Comparing the actual id sidesteps whatever that mechanism is.
    readonly property int navIndex: {
      if (!rowData || !rowData.data) return -1
      var id = rowData.data.id
      var list = nav.navigableRows
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].data && list[i].data.id === id) return i
      }
      return -1
    }
    readonly property var item: rowData ? rowData.data : null
    readonly property string kind: rowData ? rowData.type : ""
    // Set on playlist rows: the 1-based position in the playlist, shown in
    // place of the track's own album track number.
    readonly property int listPos: (rowData && rowData.listPos) ? rowData.listPos : -1
    readonly property bool isPlayingSong: kind === "song" && item && nav.currentSong && item.id === nav.currentSong.id

    hasCursor: nav.cursorActive && nav.focusSection === "list" && navIndex >= 0 && nav.listIndex === navIndex
    foreground: root.foreground
    width: parent ? parent.width : implicitWidth
    implicitHeight: rowContent.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        if (nav.keyboardActive) return
        nav.cursorActive = true; nav.focusSection = "list"; if (itemRow.navIndex >= 0) nav.listIndex = itemRow.navIndex
      }
      onPositionChanged: nav.keyboardActive = false
      onClicked: nav.activateRow(itemRow.rowData)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Rectangle {
        visible: itemRow.kind === "album" || itemRow.kind === "artist"
        width: Style.space(32)
        height: Style.space(32)
        radius: itemRow.kind === "artist" ? width / 2 : Style.cornerRadius
        color: Qt.darker(root.foreground, 4)
        clip: true

        Image {
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          source: itemRow.item && itemRow.item.coverArt ? nav.coverSource(itemRow.item.coverArt, 100) : ""
          asynchronous: true
        }

        // itemRow.item is null while this delegate is first constructed (the
        // Loader assigns rowData only after onLoaded), so the fetch has to be
        // triggered off the property actually becoming available rather than
        // Component.onCompleted, which would fire too early and never again.
        Component.onCompleted: if (itemRow.item && itemRow.item.coverArt) nav.requestCover(itemRow.item.coverArt, 100)
        Connections {
          target: itemRow
          function onItemChanged() {
            if (itemRow.item && itemRow.item.coverArt) nav.requestCover(itemRow.item.coverArt, 100)
          }
        }
      }

      Text {
        // Hidden (not just blank) when there's nothing to show, so the
        // RowLayout drops its width and spacing and the title lines up with
        // the artist/album rows above instead of sitting in an empty gutter.
        visible: itemRow.kind === "song" && text !== ""
        // Playing track -> play/pause glyph. Playlist -> its 1-based
        // position. Album -> the track's own album track number. Flat song
        // lists (Favourites, search results) have no meaningful number, so
        // show nothing.
        text: {
          if (itemRow.isPlayingSong) return nav.playing && !nav.paused ? "󰐊" : "󰏤"
          if (itemRow.listPos > 0) return String(itemRow.listPos)
          if (nav.topFrame && nav.topFrame.kind === "albumSongs")
            return itemRow.item && itemRow.item.track ? String(itemRow.item.track) : "•"
          return ""
        }
        color: itemRow.isPlayingSong ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.preferredWidth: Style.space(20)
        horizontalAlignment: Text.AlignRight
      }

      ColumnLayout {
        Layout.fillWidth: true
        // Capped so a long album/playlist title doesn't crowd the star and
        // duration off to the edge — it elides sooner instead of eating
        // all the way up to them.
        Layout.maximumWidth: Style.space(230)
        // Without this, Layout gives the column a minimum width equal to its
        // children's full un-elided text width (elide only affects painting,
        // not layout sizing), so RowLayout never actually shrinks it — the
        // title just keeps growing and pushes the trailing star button past
        // the row's edge, where the Flickable's clip hides it entirely.
        Layout.minimumWidth: 0
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: itemRow.item ? (itemRow.item.title || itemRow.item.name || "") : ""
          color: itemRow.isPlayingSong ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: itemRow.isPlayingSong
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          visible: text !== ""
          text: {
            if (!itemRow.item) return ""
            if (itemRow.kind === "artist") return itemRow.item.albumCount ? (itemRow.item.albumCount + (itemRow.item.albumCount === 1 ? " album" : " albums")) : ""
            if (itemRow.kind === "album") return [itemRow.item.artist, itemRow.item.year ? String(itemRow.item.year) : ""].filter(function(s){return s}).join(" · ")
            if (itemRow.kind === "playlist") return itemRow.item.songCount ? (itemRow.item.songCount + " tracks") : "Empty"
            if (itemRow.kind === "song") return [itemRow.item.artist, itemRow.item.album].filter(function(s){return s}).join(" · ")
            return ""
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: itemRow.kind === "song" && itemRow.item && itemRow.item.duration
        text: itemRow.item ? Model.formatDuration(itemRow.item.duration || 0) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        visible: itemRow.kind === "song" || itemRow.kind === "album" || itemRow.kind === "artist"
        iconText: (itemRow.item && itemRow.item.starred) ? "󰓎" : "󰓒"
        foreground: (itemRow.item && itemRow.item.starred) ? Color.accent : root.dim
        fontFamily: root.fontFamily
        size: Style.space(20)
        onClicked: nav.toggleFavorite(itemRow.item)
      }
    }
  }

  component NowPlayingBar: RowLayout {
    id: npBar
    spacing: Style.space(10)

    readonly property var song: nav.currentSong

    Rectangle {
      Layout.alignment: Qt.AlignVCenter
      width: Style.space(56)
      height: Style.space(56)
      radius: Style.cornerRadius
      color: Qt.darker(root.foreground, 4)
      clip: true

      Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: npBar.song && npBar.song.coverArt ? nav.coverSource(npBar.song.coverArt, 200) : ""
        asynchronous: true
      }
      Component.onCompleted: if (npBar.song && npBar.song.coverArt) nav.requestCover(npBar.song.coverArt, 200)
      Connections {
        target: npBar
        function onSongChanged() {
          if (npBar.song && npBar.song.coverArt) nav.requestCover(npBar.song.coverArt, 200)
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: npBar.song ? npBar.song.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Rectangle {
          id: formatPill
          readonly property string formatLabel: Model.formatAudioLabel(nav.audioCodec, nav.audioBitrate)
          visible: formatLabel !== ""
          radius: height / 2
          color: Qt.darker(root.foreground, 4)
          implicitWidth: formatPillText.implicitWidth + Style.space(12)
          implicitHeight: formatPillText.implicitHeight + Style.space(3)

          Text {
            id: formatPillText
            anchors.centerIn: parent
            text: formatPill.formatLabel
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
      Text {
        Layout.fillWidth: true
        text: npBar.song ? npBar.song.artist : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          text: Model.formatDuration(nav.position)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSlider {
          id: seekSlider
          bar: root.bar
          Layout.fillWidth: true
          minimum: 0
          maximum: Math.max(1, nav.duration)
          value: nav.position
          onMoved: function(v) { seekSlider.liveValue = v }
          onReleased: function(v) { nav.seekFraction(nav.duration > 0 ? v / nav.duration : 0) }
        }

        Text {
          text: Model.formatRemaining(nav.position, nav.duration)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Controls sit as a compact block to the right of the whole cover +
    // title/artist/seek column, vertically centered against it, rather
    // than on their own full-width row underneath (which just burned
    // vertical space without using the width already given to the info
    // column any better).
    ColumnLayout {
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(6)

      RowLayout {
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.space(6)

        PanelActionButton {
          fontSize: Style.space(16)
          size: Style.space(32)
          iconText: "󰒮"
          tooltipText: "Previous"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !nav.loading && nav.queueIndex > 0
          onClicked: nav.previous()
        }
        PanelActionButton {
          fontSize: Style.space(16)
          size: Style.space(32)
          iconText: nav.playing && !nav.paused ? "󰏤" : "󰐊"
          tooltipText: nav.paused ? "Play" : "Pause"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: nav.togglePause()
        }
        PanelActionButton {
          fontSize: Style.space(16)
          size: Style.space(32)
          iconText: "󰒭"
          tooltipText: "Next"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !nav.loading && nav.queueIndex >= 0 && nav.queueIndex < nav.queue.length - 1
          onClicked: nav.next()
        }
      }

      RowLayout {
        Layout.alignment: Qt.AlignHCenter
        spacing: Style.space(6)

        PanelActionButton {
          iconText: "󰒝"
          tooltipText: nav.shuffleEnabled ? "Shuffle: on" : "Shuffle: off"
          foreground: nav.shuffleEnabled ? Color.accent : root.foreground
          fontFamily: root.fontFamily
          enabled: nav.queueIndex >= 0
          onClicked: nav.toggleShuffle()
        }
        PanelActionButton {
          iconText: nav.repeatMode === "one" ? "󰑘" : "󰑖"
          tooltipText: "Repeat: " + nav.repeatMode
          foreground: nav.repeatMode !== "off" ? Color.accent : root.foreground
          fontFamily: root.fontFamily
          onClicked: nav.cycleRepeat()
        }
        PanelActionButton {
          iconText: (npBar.song && npBar.song.starred) ? "󰓎" : "󰓒"
          tooltipText: "Favourite"
          foreground: (npBar.song && npBar.song.starred) ? Color.accent : root.foreground
          fontFamily: root.fontFamily
          onClicked: nav.toggleFavorite(npBar.song)
        }
      }
    }
  }
}
