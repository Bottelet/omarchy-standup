import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "bottelet.standup"

  // Mirrored off the panel so the bar icon can badge itself.
  readonly property int unreadCount: panelLoader.item ? panelLoader.item.unreadCount : 0
  readonly property bool busy: panelLoader.item ? panelLoader.item.busy === true : false
  readonly property color badgeColor: panelLoader.item ? panelLoader.item.badgeColor : Color.accent

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.generateNow) panelLoader.item.generateNow()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function openSettings() {
    if (panelLoader.item && panelLoader.item.openSettings) panelLoader.item.openSettings()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (see the weather plugin for the long-form rationale).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢌"
    slotSize: Style.bar.statusSlot
    active: root.unreadCount > 0
    useActiveColor: true
    activeColor: root.badgeColor
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }

  // Unread badge: standups generated since the panel was last closed.
  Rectangle {
    visible: root.unreadCount > 0
    width: Math.max(height, badgeText.implicitWidth + Style.space(4))
    height: Style.space(11)
    radius: height / 2
    color: root.badgeColor
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(1)

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: root.unreadCount > 99 ? "99+" : root.unreadCount
      textFormat: Text.PlainText
      color: Color.background
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(8, Style.font.caption - 2)
      font.bold: true
    }
  }
}
