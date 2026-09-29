import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "bottelet.standup"
  ipcTarget: "bottelet.standup"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot - BarWidget.qml - not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget (popout coordinator, switchPanelFrom).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color warn: Color.accent
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptPath: Qt.resolvedUrl("scripts/standup.sh").toString().replace("file://", "")
  readonly property var cfg: Model.settingsWithDefaults(root.settings)

  property var indexData: ({ entries: [], lastSeenTs: 0 })
  property var statusData: null
  property var agentsData: null
  property string currentId: ""
  property string bodyText: ""
  property bool busy: false
  // busy doubles as a UI spinner and is refreshed from the state file on every
  // status poll, so it cannot also be the guard against starting a second run:
  // a poll sampled before the new run marked itself running comes back
  // running:false and clears it mid-flight. This tracks a run started by this
  // panel and is cleared only when that run's own process reports back.
  property bool generating: false
  property string lastError: ""
  property int repoCount: -1
  // Set when the count could not include everything that was asked for -
  // organizations need the gh CLI, and a number that quietly left them out
  // would read as "the org is empty".
  property string repoWarning: ""

  // "main" | "history" | "settings"
  property string page: "main"

  readonly property int unreadCount: Model.unreadCount(root.indexData)
  readonly property color badgeColor: Color.accent
  readonly property var entries: root.indexData && root.indexData.entries instanceof Array ? root.indexData.entries : []
  readonly property var currentEntry: {
    for (var i = 0; i < root.entries.length; i++) {
      if (String(root.entries[i].id) === root.currentId) return root.entries[i]
    }
    return root.entries.length > 0 ? root.entries[0] : null
  }
  readonly property var lines: Model.displayLines(root.bodyText)

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function run(proc, args) {
    if (proc.running) return
    proc.command = Model.scriptCommand(root.scriptPath, args)
    proc.running = true
  }

  function refreshStatus() { run(statusProc, ["status"]) }
  function refreshIndex() { run(listProc, ["list"]) }

  function loadEntry(id) {
    root.currentId = String(id || "")
    run(showProc, root.currentId === "" ? ["show"] : ["show", root.currentId])
  }

  function generateNow() {
    if (root.busy || root.generating) return
    root.generating = true
    root.busy = true
    root.lastError = ""
    run(generateProc, Model.generateArgs(root.settings, true))
  }

  function generateScheduled() {
    if (root.busy || root.generating) return
    root.generating = true
    root.busy = true
    run(generateProc, Model.generateArgs(root.settings, false))
  }

  function markSeen() {
    if (root.unreadCount === 0) return
    run(seenProc, ["seen"])
  }

  function copyBody() {
    if (root.bodyText === "") return
    Quickshell.execDetached(["wl-copy", "--", root.bodyText])
  }

  function loadAgents() { run(agentsProc, ["agents"]) }
  function countRepos() { run(reposProc, Model.reposArgs(root.settings)) }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.onOpened()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.onOpened()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function onOpened() {
    root.page = "main"
    root.refreshIndex()
    root.loadEntry("")
    root.refreshStatus()
  }

  function openHistory() {
    if (!root.opened) root.openFromHotkey()
    root.page = "history"
    root.refreshIndex()
  }

  function openSettings() {
    if (!root.opened) root.openFromHotkey()
    root.page = "settings"
    root.loadAgents()
    root.countRepos()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Marking read on close rather than on open keeps the NEW dot visible for as
  // long as the standup is actually on screen.
  onOpenedChanged: {
    if (!root.opened) root.markSeen()
  }

  // ------------------------------------------------------------- processes

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        if (!data) return
        root.statusData = data
        if (!root.generating) root.busy = data.running === true
        // Decided here rather than on the timer tick: the tick asks for status
        // and then read root.statusData on the next line, which is always the
        // previous sample. A run that had just finished and moved lastRunTs
        // was therefore invisible, and the schedule fired a second time.
        if (!root.generating && !root.busy
            && Model.scheduleDue(root.settings, new Date(), data.lastRunTs))
          root.generateScheduled()
      }
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        if (data) root.indexData = data
      }
    }
  }

  Process {
    id: showProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        if (!data) return
        root.bodyText = String(data.body || "")
        if (data.id) root.currentId = String(data.id)
      }
    }
  }

  Process {
    id: seenProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        if (data) root.statusData = data
        root.refreshIndex()
      }
    }
  }

  Process {
    id: generateProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        root.generating = false
        root.busy = false
        if (!data || data.ok !== true) {
          root.lastError = data && data.error ? String(data.error) : "generation failed"
        } else if (data.generated === true) {
          root.lastError = ""
          root.bodyText = String(data.body || "")
          root.currentId = String(data.id || "")
        } else {
          root.lastError = "Nothing new since the last standup"
        }
        root.refreshIndex()
        root.refreshStatus()
      }
    }
    onExited: function(code) {
      root.generating = false
      root.busy = false
      if (code !== 0 && root.lastError === "") root.lastError = "generation failed"
    }
  }

  Process {
    id: agentsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        if (data) root.agentsData = data
      }
    }
  }

  Process {
    id: reposProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        root.repoCount = data && data.count !== undefined ? Number(data.count) : -1
        root.repoWarning = data && data.warnings instanceof Array && data.warnings.length > 0
                           ? String(data.warnings[0]) : ""
      }
    }
  }

  // One minute is fine granularity for a once-a-day schedule and cheap: the
  // tick only reads a small JSON state file unless a run is actually due.
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Only asks. Whether a run is due is decided when the answer arrives,
      // against that answer rather than against the previous one.
      root.refreshStatus()
      root.refreshIndex()
    }
  }

  // On a multi-monitor setup the bar - and with it this panel - is
  // instantiated once per screen, so the second instance logs a harmless
  // "handler will not be used" warning. Without the handler, though, the
  // plugin has no IPC target at all.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function generate(): void { root.generateNow() }
    function settings(): void { root.openSettings() }
    function history(): void { root.openHistory() }
  }

  // ------------------------------------------------------------------- view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: rootsField.activeFocus || reposField.activeFocus || orgsField.activeFocus
               || timeField.activeFocus || customField.activeFocus || formatField.activeFocus
      onCloseRequested: {
        if (root.page !== "main") root.page = "main"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: mainColumn
          width: scroll.width
          spacing: Style.space(10)

          // ---- Header
          Item {
            width: parent.width
            height: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

            Row {
              id: headerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: "󰢌"
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.page === "settings" ? "STANDUP SETTINGS"
                      : (root.page === "history" ? "STANDUP HISTORY" : "STANDUP")
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: headerRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                visible: root.page === "main" && root.currentEntry !== null
                text: root.currentEntry ? Model.relativeDay(root.currentEntry.date, new Date()) : ""
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                visible: root.page !== "main"
                iconText: "󰅁"
                tooltipText: "Back"
                foreground: root.fg
                fontFamily: root.fontName
                onClicked: root.page = "main"
              }

              Button {
                visible: root.page === "main"
                iconText: "󰅐"
                tooltipText: "History"
                foreground: root.fg
                fontFamily: root.fontName
                onClicked: { root.page = "history"; root.refreshIndex() }
              }

              Button {
                visible: root.page === "main"
                iconText: ""
                tooltipText: "Copy to clipboard"
                foreground: root.fg
                fontFamily: root.fontName
                enabled: root.bodyText !== ""
                onClicked: root.copyBody()
              }

              Button {
                visible: root.page === "main"
                iconText: "󰑐"
                tooltipText: root.busy ? "Generating..." : "Generate now"
                foreground: root.fg
                fontFamily: root.fontName
                iconSpinning: root.busy
                onClicked: root.generateNow()
              }

              Button {
                visible: root.page !== "settings"
                iconText: "󰒓"
                tooltipText: "Settings"
                foreground: root.fg
                fontFamily: root.fontName
                onClicked: root.openSettings()
              }
            }
          }

          // ---- Sub-header: where the bullets came from
          Text {
            visible: root.page === "main" && root.currentEntry !== null
            width: parent.width
            text: root.currentEntry ? Model.sourceLine(root.currentEntry) : ""
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelSeparator {
            visible: root.page === "main"
            width: parent.width
          }

          // ---- Main page: the bullets
          Column {
            visible: root.page === "main"
            width: parent.width
            spacing: Style.space(8)

            Text {
              visible: root.busy
              width: parent.width
              text: "Reading your commits and writing the update..."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !root.busy && root.lastError !== ""
              width: parent.width
              text: root.lastError
              textFormat: Text.PlainText
              color: Color.urgent
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !root.busy && root.lines.length === 0
              width: parent.width
              text: "No standup yet. Press the refresh icon to generate one from your recent commits."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.busy ? [] : root.lines

              Item {
                required property var modelData
                readonly property bool isBullet: modelData.kind === "bullet"
                width: mainColumn.width
                height: lineText.implicitHeight

                Text {
                  id: bulletDot
                  visible: parent.isBullet
                  anchors.left: parent.left
                  anchors.leftMargin: parent.modelData.indent * Style.space(12)
                  anchors.top: parent.top
                  width: parent.isBullet ? Style.space(14) : 0
                  text: "-"
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: lineText
                  anchors.left: parent.isBullet ? bulletDot.right : parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  text: parent.modelData.text
                  textFormat: Text.PlainText
                  // Section headings from the grouped formats carry the
                  // emphasis instead of a bullet dot.
                  color: parent.isBullet ? root.fg : root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.body
                  font.bold: !parent.isBullet
                  wrapMode: Text.WordWrap
                  lineHeight: 1.25
                }
              }
            }
          }

          // ---- History page
          Column {
            visible: root.page === "history"
            width: parent.width
            spacing: Style.space(4)

            Text {
              visible: root.entries.length === 0
              width: parent.width
              text: "No standups stored yet."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.page === "history" ? root.entries : []

              Rectangle {
                required property var modelData
                width: mainColumn.width
                height: Style.space(34)
                radius: Math.min(4, Style.cornerRadius)
                color: historyArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.relativeDay(parent.modelData.date, new Date()) + "  " + Model.timeOfDay(parent.modelData.ts)
                  textFormat: Text.PlainText
                  color: String(parent.modelData.id) === root.currentId ? Color.accent : root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.sourceLine(parent.modelData)
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: historyArea
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: {
                    root.loadEntry(parent.modelData.id)
                    root.page = "main"
                  }
                }
              }
            }
          }

          // ---- Settings page
          Column {
            visible: root.page === "settings"
            width: parent.width
            spacing: Style.space(12)

            PanelSectionHeader {
              width: parent.width
              text: "PROJECTS"
              foreground: root.dim
              fontFamily: root.fontName
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: "Folders to scan"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: rootsField
                // The key catcher is blocked while a field has focus, so without this
                // Escape went nowhere and the panel could not be closed from the keyboard.
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                width: parent.width
                text: String(root.cfg.roots)
                placeholderText: "~/Projects"
                foreground: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
                onEditingFinished: {
                  root.persistSettings({ roots: text })
                  root.repoCount = -1
                  root.repoWarning = ""
                  root.countRepos()
                }
              }

              Text {
                width: parent.width
                text: "Separated by commas. Sub-folders are scanned too."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            NumberField {
              label: "Folder depth"
              value: root.cfg.scanDepth
              from: 1
              to: 5
              foreground: root.fg
              fontFamily: root.fontName
              onModified: function(v) {
                root.persistSettings({ scanDepth: v })
                root.countRepos()
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: "Individual repos"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: reposField
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                width: parent.width
                text: String(root.cfg.repos)
                placeholderText: "~/code/thing, owner/repo"
                foreground: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
                onEditingFinished: {
                  root.persistSettings({ repos: text })
                  root.repoCount = -1
                  root.repoWarning = ""
                  root.countRepos()
                }
              }

              Text {
                width: parent.width
                text: "Repos to include wherever they live: a path on this machine, or a GitHub repo as owner/name."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: "GitHub organizations"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: orgsField
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                width: parent.width
                text: String(root.cfg.orgs)
                placeholderText: "acme-inc"
                foreground: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
                onEditingFinished: {
                  root.persistSettings({ orgs: text })
                  root.repoCount = -1
                  root.repoWarning = ""
                  root.countRepos()
                }
              }

              Text {
                width: parent.width
                text: "Every repo in the org you committed to, cloned here or not. Needs the gh CLI logged in."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // One line for the whole section: what is pointed at, and what that
            // actually resolved to the last time it was counted.
            Text {
              width: parent.width
              text: root.repoWarning !== ""
                    ? root.repoWarning
                    : (root.repoCount >= 0
                       ? Model.sourceSummary(root.settings) + " - "
                         + root.repoCount + " repo" + (root.repoCount === 1 ? "" : "s")
                         + " in scope (the standup covers the ones you committed to)"
                       : Model.sourceSummary(root.settings))
              textFormat: Text.PlainText
              color: root.repoWarning !== "" ? root.warn : root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSectionHeader {
              width: parent.width
              text: "WHAT GOES IN"
              foreground: root.dim
              fontFamily: root.fontName
            }

            Dropdown {
              width: parent.width
              label: "Time range"
              value: String(root.cfg.windowMode)
              foreground: root.fg
              fontFamily: root.fontName
              options: [
                { value: "auto", label: "Since the last standup", description: "Monday covers Friday automatically" },
                { value: "fixed", label: "A fixed number of days", description: "Always the same window" }
              ]
              onChanged: function(v) { root.persistSettings({ windowMode: v }) }
            }

            NumberField {
              visible: String(root.cfg.windowMode) === "fixed"
              label: "Days back"
              value: root.cfg.days
              from: 1
              to: 30
              foreground: root.fg
              fontFamily: root.fontName
              onModified: function(v) { root.persistSettings({ days: v }) }
            }

            Dropdown {
              width: parent.width
              label: "Whose commits"
              value: Model.authorMode(root.settings)
              foreground: root.fg
              fontFamily: root.fontName
              options: [
                { value: "me", label: "Only me", description: "Every git identity you commit under" },
                { value: "all", label: "Everyone", description: "The whole team across these repos" },
                { value: "custom", label: "Pick people", description: "Choose specific authors" }
              ]
              onChanged: function(v) { root.persistSettings({ authorMode: v }) }
            }

            MultiSelect {
              visible: String(root.cfg.authorMode) === "custom"
              width: parent.width
              label: "People"
              values: Model.authorValues(root.settings)
              optionsCommand: Model.scriptCommand(root.scriptPath, Model.authorsOptionsArgs(root.settings))
              placeholderText: "Search people..."
              emptyText: "No commits found in these folders"
              noSelectionText: "Nobody picked yet"
              foreground: root.fg
              fontFamily: root.fontName
              onChanged: function(v) { root.persistSettings({ authors: v.join(",") }) }
            }

            NumberField {
              label: "Max bullets"
              value: root.cfg.maxBullets
              from: 1
              to: 10
              foreground: root.fg
              fontFamily: root.fontName
              onModified: function(v) { root.persistSettings({ maxBullets: v }) }
            }

            PanelSectionHeader {
              width: parent.width
              text: "SHAPE"
              foreground: root.dim
              fontFamily: root.fontName
            }

            Dropdown {
              width: parent.width
              label: "Format"
              value: Model.formatSummary(root.settings) === "Custom" ? "custom" : String(root.cfg.format)
              foreground: root.fg
              fontFamily: root.fontName
              options: Model.formatOptions()
              onChanged: function(v) {
                // Picking a preset seeds the wording below so it can be edited
                // from there; Custom keeps whatever is already typed.
                if (v === "custom") root.persistSettings({ format: "custom" })
                else root.persistSettings({ format: v, formatText: Model.formatPreset(v).text })
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              TextField {
                id: formatField
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                width: parent.width
                text: Model.formatText(root.settings)
                foreground: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
                onEditingFinished: root.persistSettings({ format: "custom", formatText: text })
              }

              Text {
                width: parent.width
                text: "Describe the shape you want in your own words. The agent follows this."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSectionHeader {
              width: parent.width
              text: "WHO WRITES IT"
              foreground: root.dim
              fontFamily: root.fontName
            }

            Dropdown {
              width: parent.width
              label: "Agent"
              value: String(root.cfg.agent)
              foreground: root.fg
              fontFamily: root.fontName
              options: Model.agentOptions(root.agentsData, root.settings)
              onChanged: function(v) { root.persistSettings({ agent: v }) }
            }

            Column {
              visible: String(root.cfg.agent) === "custom"
              width: parent.width
              spacing: Style.space(4)

              TextField {
                id: customField
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                width: parent.width
                text: String(root.cfg.customCommand)
                foreground: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
                onEditingFinished: root.persistSettings({ customCommand: text })
              }

              Text {
                width: parent.width
                text: "Any command that reads a prompt on stdin, e.g. ollama run llama3.2"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSectionHeader {
              width: parent.width
              text: "SCHEDULE"
              foreground: root.dim
              fontFamily: root.fontName
            }

            Item {
              width: parent.width
              height: autoToggle.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Generate automatically"
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                id: autoToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.cfg.autoGenerate === true
                foreground: root.fg
                onToggled: root.persistSettings({ autoGenerate: !root.cfg.autoGenerate })
              }
            }

            Item {
              visible: root.cfg.autoGenerate === true
              width: parent.width
              height: timeField.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "At"
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
              }

              TextField {
                id: timeField
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(80)
                text: Model.formatTimeOfDay(Model.parseTimeOfDay(root.cfg.scheduleTime, 540))
                foreground: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                onEditingFinished: {
                  var minutes = Model.parseTimeOfDay(text, -1)
                  if (minutes < 0) {
                    text = Model.formatTimeOfDay(Model.parseTimeOfDay(root.cfg.scheduleTime, 540))
                    return
                  }
                  var value = Model.formatTimeOfDay(minutes)
                  text = value
                  root.persistSettings({ scheduleTime: value })
                }
              }
            }

            Row {
              visible: root.cfg.autoGenerate === true
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: 7

                Rectangle {
                  required property int index
                  readonly property string dayKey: Model.WEEKDAYS[index]
                  readonly property bool on: Model.scheduleDays(root.settings).indexOf(dayKey) !== -1

                  width: (mainColumn.width - Style.space(24)) / 7
                  height: Style.space(26)
                  radius: Math.min(4, Style.cornerRadius)
                  color: on ? Color.accent
                            : (dayArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent")
                  border.width: on ? 0 : Style.normalBorderWidth
                  border.color: root.dim

                  Text {
                    anchors.centerIn: parent
                    text: Model.WEEKDAY_LABELS[parent.index]
                    textFormat: Text.PlainText
                    color: parent.on ? Color.background : root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    font.bold: parent.on
                  }

                  MouseArea {
                    id: dayArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                      var days = Model.scheduleDays(root.settings)
                      var at = days.indexOf(parent.dayKey)
                      if (at === -1) days.push(parent.dayKey)
                      else days.splice(at, 1)
                      // Re-sorted into week order so the stored value reads the
                      // way the row looks.
                      days.sort(function(a, b) {
                        return Model.WEEKDAYS.indexOf(a) - Model.WEEKDAYS.indexOf(b)
                      })
                      root.persistSettings({ scheduleDays: days.join(",") })
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              text: root.cfg.autoGenerate === true
                    ? "A standup missed while the machine was off is generated at the next login."
                    : "Automatic generation is off - use the refresh icon on the main page."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }
}
