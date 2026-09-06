import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "KeeperSearch.js" as Search

// Keeper vault picker. Search-as-you-type over the cached index, a detail
// pane for the selected record, and single-chord actions. Every Keeper call
// goes through bin/omarchy-keeper-action so secrets never touch QML files
// or the clipboard history.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string indexPath: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-keeper/index.json"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true

  property var status: ({ installed: false, enrolled: false, count: 0, defaultAction: "ask", clearSeconds: 45, daemon: "off" })
  property bool statusLoaded: false
  readonly property bool ready: statusLoaded && status.installed && status.enrolled

  property var records: []
  property var filtered: []

  property var detail: null
  property string detailUid: ""
  property bool detailLoading: false
  property bool revealPassword: false

  property var totp: null
  property string totpUid: ""
  property bool totpLoading: false

  // "list" or "form"; the form adds or edits a record in place.
  property string mode: "list"
  property string formUid: ""
  property bool formGenerate: true
  property bool formShowPassword: false
  property bool formBusy: false
  property bool pendingAdd: false

  property string busyText: ""
  property string toastText: ""
  property bool toastIsError: false
  property string pendingLabel: ""

  // Shares the [menu] surface tokens so themes that style the menu style this.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Style.font.caption + Style.spacing.md * 2
  property int rowHeight: Style.font.body + Style.font.caption + Style.spacing.md * 2 + Style.spacing.xs
  property int cardWidth: Math.min(Style.space(820), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  property int listWidth: Math.round((cardWidth - contentMargin * 2) * 0.52)

  readonly property string iconKey: "󰌆"
  readonly property string iconUser: "󰀄"
  readonly property string iconLink: "󰌹"
  readonly property string iconClock: "󰔛"
  readonly property string iconNote: "󰎞"
  readonly property string iconFolder: "󰉋"

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.opened = true
    root.mode = "list"
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.busyText = ""
    root.toastText = ""
    root.clearDetail()
    closeTimer.stop()
    refreshStatus()
    indexView.reload()
    rebuild()
    var wantAdd = false
    try {
      var payload = payloadJson ? JSON.parse(payloadJson) : {}
      wantAdd = payload.mode === "add"
    } catch (e) {}
    // The status probe is asynchronous; on a cold open the form has to wait
    // for it before it can be shown.
    root.pendingAdd = wantAdd
    if (wantAdd && root.ready) Qt.callLater(function() { root.pendingAdd = false; root.startAdd() })
    else Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.mode = "list"
    root.formBusy = false
    closeTimer.stop()
    totpTimer.stop()
    root.clearDetail()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "dovijoel.keeper")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function scriptPath(name) {
    return decodeURIComponent(Qt.resolvedUrl("bin/" + name).toString().replace(/^file:\/\//, ""))
  }

  // ------------------------------------------------------------------ data

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.running = true
  }

  function loadIndex(raw) {
    root.records = Search.parseIndex(raw)
    if (root.opened) rebuild()
  }

  function rebuild() {
    var out = Search.filterRecords(root.records, root.filterText, 400)
    root.filtered = out
    displayModel.clear()
    for (var i = 0; i < out.length; i++) {
      displayModel.append({ uid: out[i].uid, title: out[i].title, subtext: out[i].subtext, rtype: out[i].type, index: i })
    }
    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
    syncDetailToSelection()
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function selectedRecord() {
    if (root.filtered.length === 0) return null
    if (root.selectedIndex < 0 || root.selectedIndex >= root.filtered.length) return null
    return root.filtered[root.selectedIndex]
  }

  function clearDetail() {
    root.detail = null
    root.detailUid = ""
    root.detailLoading = false
    root.revealPassword = false
    root.totp = null
    root.totpUid = ""
    root.totpLoading = false
    totpTimer.stop()
  }

  function syncDetailToSelection() {
    var rec = selectedRecord()
    var uid = rec ? rec.uid : ""
    if (uid !== root.detailUid) {
      root.detail = null
      root.detailUid = ""
      root.detailLoading = false
      root.revealPassword = false
    }
    if (uid !== root.totpUid) {
      root.totp = null
      root.totpUid = ""
      root.totpLoading = false
      totpTimer.stop()
    }
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.cursorActive = true
    rebuild()
  }

  function move(delta) {
    if (displayModel.count === 0) return
    root.selectedIndex = Math.max(0, Math.min(displayModel.count - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    syncDetailToSelection()
  }

  function movePage(delta) {
    var visible = Math.max(1, Math.floor(resultList.height / root.rowHeight))
    move(delta * visible)
  }

  // --------------------------------------------------------------- actions

  function showToast(text, isError) {
    root.toastText = text
    root.toastIsError = !!isError
    toastTimer.restart()
  }

  function fieldLabel(field) {
    return field === "login" ? "username" : field === "totp" ? "TOTP code" : "password"
  }

  function copyField(field) {
    var rec = selectedRecord()
    if (!rec || actionProc.running) return
    root.pendingLabel = fieldLabel(field)
    root.busyText = "Fetching " + root.pendingLabel + " for " + rec.title + "…"
    actionProc.command = [scriptPath("omarchy-keeper-action"), "copy", rec.uid, field]
    actionProc.running = true
  }

  function typeField(field) {
    var rec = selectedRecord()
    if (!rec) return
    // The overlay has exclusive keyboard focus; it has to go before typing.
    var argv = [scriptPath("omarchy-keeper-action"), "type", rec.uid, field]
    root.dismiss()
    Quickshell.execDetached(argv)
  }

  function openUrl() {
    var rec = selectedRecord()
    if (!rec) return
    if (!rec.url) { showToast("No URL on " + rec.title, true); return }
    Quickshell.execDetached([scriptPath("omarchy-keeper-action"), "open", rec.uid])
    root.dismiss()
  }

  function loadDetail() {
    var rec = selectedRecord()
    if (!rec || getProc.running) return
    if (root.detail && root.detailUid === rec.uid) {
      root.revealPassword = !root.revealPassword
      return
    }
    root.detailLoading = true
    root.detailUid = rec.uid
    getProc.command = [scriptPath("omarchy-keeper-action"), "get", rec.uid]
    getProc.running = true
  }

  function loadTotp() {
    var rec = selectedRecord()
    if (!rec || totpProc.running) return
    if (root.totp && root.totpUid === rec.uid) { copyField("totp"); return }
    root.totpLoading = true
    root.totpUid = rec.uid
    totpProc.command = [scriptPath("omarchy-keeper-action"), "totp", rec.uid]
    totpProc.running = true
  }

  function syncIndex() {
    if (syncProc.running) return
    root.busyText = "Refreshing vault index…"
    syncProc.running = true
  }

  function launchSetup() {
    Quickshell.execDetached([scriptPath("omarchy-keeper-login")])
    root.dismiss()
  }

  // ------------------------------------------------------------- add / edit

  function startAdd() {
    if (!root.ready) return
    root.formUid = ""
    formTitle.text = ""
    formLogin.text = ""
    formUrl.text = ""
    formPassword.text = ""
    formNotes.text = ""
    root.formGenerate = true
    root.formShowPassword = false
    root.mode = "form"
    Qt.callLater(function() { formTitle.forceActiveFocus() })
  }

  function startEdit() {
    var rec = selectedRecord()
    if (!rec || !root.ready) return
    root.formUid = rec.uid
    formTitle.text = rec.title === "(untitled)" ? "" : rec.title
    formLogin.text = rec.login
    formUrl.text = rec.url
    formPassword.text = ""
    formNotes.text = ""
    root.formGenerate = false
    root.formShowPassword = false
    root.mode = "form"
    if (root.detail && root.detailUid === rec.uid) {
      formLogin.text = root.detail.login
      formUrl.text = root.detail.url
      formNotes.text = root.detail.notes
    } else if (!getProc.running) {
      // Pull the full record so notes come through; the fields are patched
      // in when it arrives if the user has not touched them yet.
      root.detailLoading = true
      root.detailUid = rec.uid
      getProc.command = [scriptPath("omarchy-keeper-action"), "get", rec.uid]
      getProc.running = true
    }
    Qt.callLater(function() { formTitle.forceActiveFocus() })
  }

  // Shared shortcut handling for the form fields (they hold keyboard focus,
  // so the list key catcher never sees these events).
  function formKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { cancelForm(); event.accepted = true }
    else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { submitForm(); event.accepted = true }
    else if (ctrl && event.key === Qt.Key_G) {
      root.formGenerate = !root.formGenerate
      if (!root.formGenerate) Qt.callLater(function() { formPassword.forceActiveFocus() })
      event.accepted = true
    }
    else if (ctrl && event.key === Qt.Key_H) { root.formShowPassword = !root.formShowPassword; event.accepted = true }
  }

  function cancelForm() {
    root.mode = "list"
    root.formBusy = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function formFocusNext(fromIndex) {
    var order = [formTitle, formLogin, formUrl, formPassword, formNotes]
    var next = order[(fromIndex + 1) % order.length]
    if (next === formPassword && root.formGenerate) next = formNotes
    next.forceActiveFocus()
    next.selectAll()
  }

  function submitForm() {
    if (root.formBusy || formProc.running) return
    var title = formTitle.text.trim()
    if (!title) { showToast("A title is required", true); formTitle.forceActiveFocus(); return }
    var password = root.formGenerate ? "$GEN" : formPassword.text
    if (!root.formUid && !password) { showToast("Enter a password or let Keeper generate one", true); formPassword.forceActiveFocus(); return }
    root.formBusy = true
    root.busyText = root.formUid ? "Saving " + title + "…" : "Adding " + title + "…"
    var argv = [scriptPath("omarchy-keeper-action")]
    if (root.formUid) argv = argv.concat(["edit", root.formUid, title, formLogin.text.trim(), formUrl.text.trim(), password, formNotes.text])
    else argv = argv.concat(["add", title, formLogin.text.trim(), formUrl.text.trim(), password, formNotes.text])
    formProc.command = argv
    formProc.running = true
  }

  function defaultAction() {
    if (!root.ready) { launchSetup(); return }
    if (root.status.defaultAction === "type") typeField("password")
    else copyField("password")
  }

  // ------------------------------------------------------------- processes

  ListModel { id: displayModel }

  FileView {
    id: indexView
    path: root.indexPath
    watchChanges: true
    onLoaded: root.loadIndex(text())
    onFileChanged: indexView.reload()
    onLoadFailed: root.records = []
  }

  Process {
    id: statusProc
    command: [root.scriptPath("omarchy-keeper-action"), "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          root.status = s
        } catch (e) {
          root.status = { installed: false, enrolled: false, count: 0, defaultAction: "ask", clearSeconds: 45, daemon: "off" }
        }
        root.statusLoaded = true
        if (root.pendingAdd) {
          root.pendingAdd = false
          if (root.ready) root.startAdd()
        }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { }
    onExited: function(exitCode, exitStatus) {
      root.busyText = ""
      if (exitCode === 0) {
        var rec = root.selectedRecord()
        root.showToast("Copied " + root.pendingLabel + (rec ? " for " + rec.title : "") + " · clipboard clears in " + root.status.clearSeconds + " s", false)
        closeTimer.restart()
      } else if (exitCode === 3) {
        root.showToast("This record has no " + root.pendingLabel, true)
      } else {
        root.showToast("Keeper could not fetch the " + root.pendingLabel + " — see the notification", true)
      }
    }
  }

  Process {
    id: getProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.detailLoading = false
        try {
          var d = JSON.parse(text)
          if (d && d.uid === root.detailUid) {
            root.detail = d
            if (root.mode === "form" && root.formUid === d.uid) {
              if (!formLogin.text) formLogin.text = d.login
              if (!formUrl.text) formUrl.text = d.url
              if (!formNotes.text) formNotes.text = d.notes
            }
          }
        } catch (e) {
          root.detail = null
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.detailLoading = false
      if (exitCode !== 0) root.showToast("Could not load the record — see the notification", true)
    }
  }

  Process {
    id: totpProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.totpLoading = false
        try {
          var t = JSON.parse(text)
          if (t && t.code) {
            root.totp = t
            totpTimer.restart()
          } else {
            root.totp = null
          }
        } catch (e) {
          root.totp = null
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.totpLoading = false
      if (exitCode === 3 || (exitCode === 0 && !root.totp)) root.showToast("This record has no TOTP", true)
      else if (exitCode !== 0) root.showToast("Could not fetch the TOTP code — see the notification", true)
    }
  }

  Process {
    id: formProc
    stdout: StdioCollector { }
    onExited: function(exitCode, exitStatus) {
      root.formBusy = false
      root.busyText = ""
      if (exitCode !== 0) {
        root.showToast("Keeper rejected the record — see the notification", true)
        return
      }
      var result = null
      try { result = JSON.parse(stdout.text) } catch (e) {}
      var title = result && result.title ? result.title : "record"
      var wasEdit = root.formUid !== ""
      root.mode = "list"
      root.clearDetail()
      if (result && result.copied) root.showToast((wasEdit ? "Saved " : "Added ") + title + " · new password on the clipboard, clears in " + root.status.clearSeconds + " s", false)
      else root.showToast((wasEdit ? "Saved " : "Added ") + title, false)
      root.setFilter(title)
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Process {
    id: syncProc
    command: [root.scriptPath("omarchy-keeper-sync")]
    onExited: function(exitCode, exitStatus) {
      root.busyText = ""
      if (exitCode === 0) { indexView.reload(); root.refreshStatus(); root.showToast("Vault index refreshed", false) }
      else root.showToast("Index refresh failed — see the notification", true)
    }
  }

  Timer {
    id: toastTimer
    interval: 4000
    onTriggered: root.toastText = ""
  }

  Timer {
    id: closeTimer
    interval: 900
    onTriggered: root.dismiss()
  }

  Timer {
    id: totpTimer
    interval: 1000
    repeat: true
    onTriggered: {
      if (!root.totp) { stop(); return }
      var t = root.totp
      var left = t.secondsLeft - 1
      if (left <= 0) {
        stop()
        root.totp = null
        if (root.opened && root.totpUid) {
          totpProc.command = [root.scriptPath("omarchy-keeper-action"), "totp", root.totpUid]
          root.totpLoading = true
          totpProc.running = true
        }
        return
      }
      root.totp = { code: t.code, secondsLeft: left, period: t.period }
    }
  }

  // -------------------------------------------------------------------- UI

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-keeper"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = event.modifiers & Qt.ControlModifier
          if (root.mode === "form") {
            if (event.key === Qt.Key_Escape) { root.cancelForm(); event.accepted = true }
            else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.submitForm(); event.accepted = true }
            else if (ctrl && event.key === Qt.Key_G) { root.formGenerate = !root.formGenerate; event.accepted = true }
            else if (ctrl && event.key === Qt.Key_H) { root.formShowPassword = !root.formShowPassword; event.accepted = true }
            return
          }
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (ctrl) root.typeField("password")
            else root.defaultAction()
            event.accepted = true
          } else if (ctrl && (event.key === Qt.Key_U)) {
            if (event.modifiers & Qt.ShiftModifier) root.typeField("login")
            else root.copyField("login")
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_T) {
            root.loadTotp()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_O) {
            root.openUrl()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_D) {
            root.loadDetail()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_R) {
            root.syncIndex()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_N) {
            root.startAdd()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_E) {
            root.startEdit()
            event.accepted = true
          } else if (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_K)) {
            root.move(event.key === Qt.Key_J ? 1 : -1)
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.movePage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.movePage(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Home && ctrl) {
            root.move(-100000)
            event.accepted = true
          } else if (event.key === Qt.Key_End && ctrl) {
            root.move(100000)
            event.accepted = true
          } else if (!ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Header: search text + record count
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: countText.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.mode === "form" ? (root.formUid ? "Edit login" : "New login")
                  : (root.filterText || "Search Keeper — title, email or site…")
            color: root.foreground
            opacity: (root.filterText || root.mode === "form") ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: countText
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: (root.ready && root.mode === "list") ? (root.filterText ? root.filtered.length + " / " + root.records.length : root.records.length + " records") : ""
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Body
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - Style.spacing.md * 2

          // Setup state
          Column {
            anchors.centerIn: parent
            width: parent.width * 0.7
            spacing: Style.spacing.lg
            visible: root.statusLoaded && !root.ready

            Text {
              text: root.iconKey
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              text: !root.status.installed ? "Keeper Commander is not installed yet" : "This device is not signed in to Keeper yet"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              text: "Press Enter to open the one-time enrolment. It installs the Keeper CLI if needed, signs you in once and remembers this device."
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // Add / edit form
          Column {
            id: formColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.spacing.lg
            visible: root.ready && root.mode === "form"

            FormRow {
              label: "Title"
              TextField {
                id: formTitle
                width: parent.width
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { root.formKey(event) }
                placeholderText: "e.g. GitHub"
                onAccepted: root.formFocusNext(0)
                KeyNavigation.tab: formLogin
                KeyNavigation.backtab: formNotes
              }
            }

            FormRow {
              label: "Username or email"
              TextField {
                id: formLogin
                width: parent.width
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { root.formKey(event) }
                placeholderText: "you@example.com"
                onAccepted: root.formFocusNext(1)
                KeyNavigation.tab: formUrl
                KeyNavigation.backtab: formTitle
              }
            }

            FormRow {
              label: "Website"
              TextField {
                id: formUrl
                width: parent.width
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { root.formKey(event) }
                placeholderText: "https://…"
                onAccepted: root.formFocusNext(2)
                KeyNavigation.tab: root.formGenerate ? formNotes : formPassword
                KeyNavigation.backtab: formLogin
              }
            }

            FormRow {
              label: root.formUid ? "Password  ·  leave empty to keep the current one" : "Password"
              hint: root.formGenerate ? "Keeper generates a strong password and copies it after saving   ·   Ctrl+G to type one instead"
                    : "Ctrl+G lets Keeper generate one   ·   Ctrl+H " + (root.formShowPassword ? "hides" : "shows") + " it"
              TextField {
                id: formPassword
                width: parent.width
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { root.formKey(event) }
                enabled: !root.formGenerate
                opacity: root.formGenerate ? 0.4 : 1
                password: !root.formShowPassword
                placeholderText: root.formGenerate ? "generated by Keeper" : (root.formUid ? "unchanged" : "")
                onAccepted: root.formFocusNext(3)
                KeyNavigation.tab: formNotes
                KeyNavigation.backtab: formUrl
              }
            }

            FormRow {
              label: "Notes"
              TextField {
                id: formNotes
                width: parent.width
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { root.formKey(event) }
                placeholderText: "optional"
                onAccepted: root.submitForm()
                KeyNavigation.tab: formTitle
                KeyNavigation.backtab: root.formGenerate ? formUrl : formPassword
              }
            }
          }

          Row {
            anchors.fill: parent
            spacing: Style.spacing.lg
            visible: root.ready && root.mode === "list"

            // Result list
            Item {
              width: root.listWidth
              height: parent.height

              ListView {
                id: resultList
                anchors.fill: parent
                model: displayModel
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                highlightFollowsCurrentItem: false

                delegate: Rectangle {
                  required property int index
                  required property string uid
                  required property string title
                  required property string subtext
                  required property string rtype

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

                  width: resultList.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    spacing: Style.spacing.md

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: rtype === "login" ? root.iconKey : rtype === "bankCard" || rtype === "bankAccount" ? "󰆦" : rtype.indexOf("Note") >= 0 ? root.iconNote : "󰈙"
                      color: hasCursor ? root.selectedText : root.foreground
                      opacity: hasCursor ? 1 : 0.75
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.iconLarge
                      width: Style.space(24)
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - Style.space(24) - Style.spacing.md
                      spacing: Style.spacing.xxs

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: title
                        color: hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }
                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: subtext
                        visible: subtext !== ""
                        color: root.foreground
                        opacity: 0.6
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) {
                      root.cursorActive = true
                      root.selectedIndex = index
                      root.syncDetailToSelection()
                    }
                    onClicked: {
                      root.cursorActive = true
                      root.selectedIndex = index
                      root.syncDetailToSelection()
                    }
                    onDoubleClicked: root.defaultAction()
                  }
                }
              }

              Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: Style.space(8)
                visible: displayModel.count === 0

                Text {
                  text: root.records.length === 0 ? "󰋚" : "󰈉"
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  color: root.selectedText
                  opacity: 0.8
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  text: root.records.length === 0 ? "No vault index yet — press Ctrl+R to build it" : "No matches for “" + root.filterText + "”"
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
            }

            Rectangle {
              width: Style.spacing.hairline
              height: parent.height
              color: root.border
              opacity: 0.5
            }

            // Detail pane
            Item {
              id: detailPane
              width: parent.width - root.listWidth - Style.spacing.lg * 2 - Style.spacing.hairline
              height: parent.height

              readonly property var rec: root.selectedRecord()
              readonly property var d: root.detail
              readonly property string login: d && d.login ? d.login : (rec ? rec.login : "")
              readonly property string url: d && d.url ? d.url : (rec ? rec.url : "")

              Column {
                anchors.fill: parent
                spacing: Style.spacing.md
                visible: detailPane.rec !== null

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: detailPane.rec ? detailPane.rec.title : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                  maximumLineCount: 2
                  wrapMode: Text.Wrap
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: detailPane.d ? [detailPane.d.type, detailPane.d.folder ? root.iconFolder + " " + detailPane.d.folder : "", detailPane.d.modified ? "edited " + detailPane.d.modified.substring(0, 10) : ""].filter(function(x) { return x }).join("  ·  ") : (detailPane.rec ? detailPane.rec.type : "")
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Item { width: 1; height: Style.spacing.sm }

                DetailRow {
                  icon: root.iconUser
                  label: "Username"
                  value: detailPane.login || "—"
                  hint: "Ctrl+U copies · Ctrl+Shift+U types"
                }

                DetailRow {
                  icon: root.iconKey
                  label: "Password"
                  value: root.detail && root.detailUid === (detailPane.rec ? detailPane.rec.uid : "")
                         ? (root.revealPassword ? (root.detail.password || "—") : (root.detail.password ? "••••••••••••" : "—"))
                         : "••••••••••••"
                  mono: root.revealPassword
                  hint: "Enter copies · Ctrl+Enter types · Ctrl+D " + (root.detail && root.detailUid === (detailPane.rec ? detailPane.rec.uid : "") ? (root.revealPassword ? "hides" : "reveals") : "loads details")
                }

                DetailRow {
                  icon: root.iconClock
                  label: "One-time code"
                  value: root.totpLoading ? "fetching…"
                         : (root.totp && root.totpUid === (detailPane.rec ? detailPane.rec.uid : "")) ? root.totp.code + "   ·   " + root.totp.secondsLeft + " s"
                         : (root.detail && root.detailUid === (detailPane.rec ? detailPane.rec.uid : "") && !root.detail.hasTotp) ? "—"
                         : "Ctrl+T"
                  mono: !!(root.totp && root.totpUid === (detailPane.rec ? detailPane.rec.uid : ""))
                  accentValue: !!(root.totp && root.totpUid === (detailPane.rec ? detailPane.rec.uid : ""))
                  hint: root.totp && root.totpUid === (detailPane.rec ? detailPane.rec.uid : "") ? "Ctrl+T copies the code" : "Ctrl+T fetches and shows the code"
                }

                DetailRow {
                  icon: root.iconLink
                  label: "Website"
                  value: detailPane.url || "—"
                  hint: detailPane.url ? "Ctrl+O opens it in the browser" : ""
                }

                DetailRow {
                  visible: !!(root.detail && root.detail.notes)
                  icon: root.iconNote
                  label: "Notes"
                  value: root.detail && root.detail.notes ? root.detail.notes : ""
                  multiline: true
                }

                Repeater {
                  model: root.detail && root.detail.custom ? root.detail.custom : []
                  delegate: DetailRow {
                    required property var modelData
                    icon: "󰙅"
                    label: modelData.label
                    value: modelData.value
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: root.detailLoading
                  text: "Loading record…"
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // Footer: toast / busy / key legend
        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            textFormat: Text.PlainText
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            text: root.busyText ? root.busyText
                  : root.toastText ? root.toastText
                  : (root.ready && root.mode === "form") ? "⌃↵ save   ↵ next field   ⇥ / ⇧⇥ move   ⌃G generate   ⌃H show   Esc back"
                  : (root.ready && root.status.daemon === "starting") ? "Warming up Keeper in the background — the first lookup may take a few seconds"
                  : root.ready ? "↵ " + (root.status.defaultAction === "type" ? "type" : "copy") + " password   ⌃↵ type   ⌃U username   ⌃T code   ⌃O open   ⌃D details   ⌃N new   ⌃E edit   ⌃R refresh"
                  : "↵ set up Keeper   Esc close"
            color: root.toastText ? (root.toastIsError ? root.foreground : root.selectedText) : root.foreground
            opacity: root.busyText || root.toastText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A labelled input in the add / edit form.
  component FormRow: Column {
    property string label: ""
    property string hint: ""
    default property alias content: fieldHost.data

    width: parent ? parent.width : 0
    spacing: Style.spacing.xs

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      id: fieldHost
      width: parent.width
      height: childrenRect.height
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: hint !== ""
      text: hint
      color: root.foreground
      opacity: 0.4
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // A labelled value line in the detail pane.
  component DetailRow: Column {
    property string icon: ""
    property string label: ""
    property string value: ""
    property string hint: ""
    property bool mono: false
    property bool multiline: false
    property bool accentValue: false

    width: parent ? parent.width : 0
    spacing: Style.spacing.xxs

    Row {
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        text: icon
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        width: Style.space(16)
      }
      Text {
        textFormat: Text.PlainText
        text: label
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: Style.space(16) + Style.spacing.sm
      text: value
      color: accentValue ? root.selectedText : root.foreground
      font.family: mono ? "monospace" : root.fontFamily
      font.pixelSize: Style.font.body
      elide: multiline ? Text.ElideNone : Text.ElideMiddle
      wrapMode: multiline ? Text.Wrap : Text.NoWrap
      maximumLineCount: multiline ? 4 : 1
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: Style.space(16) + Style.spacing.sm
      visible: hint !== ""
      text: hint
      color: root.foreground
      opacity: 0.4
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
