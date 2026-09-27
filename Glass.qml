import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Glass — milky-glass control panel for the omarchy bar.
// FROST sliders apply on release (block rewrite + hyprctl reload);
// BLUR/SHAPES sliders apply live while dragging (hyprctl eval hl.config).
// Presets: the 8-style lineup (7 styles + stock) with active-chip detection
// from the backend; ⇅ Sync all; per-app keep-solid rows; in-session undo
// stack; right-click style tour with a 10s keep-or-revert trial.
// State brain lives in scripts/glass-ctl; this file is presentation.
Panel {
  id: root
  moduleName: "khwan.glass"
  ipcTarget: "khwan.glass"
  manageIpc: true

  readonly property string ctl:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/khwan.glass/scripts/glass-ctl"

  // chip order for keys 1–9/0; backend "stock" = omarchy default (block removed)
  readonly property var builtinOrder: ["milky", "cloud", "frosted", "smoke", "ink", "crystal", "veil", "gauze", "crisp", "stock"]
  // right-click style tour (favorites) — keep in step with TOUR in glass-ctl
  readonly property var tourOrder: ["cloud", "smoke", "ink", "crystal", "milky"]

  property var state: ({})
  property bool dragging: false
  property string error: ""
  property var classes: []
  property bool addingApp: false
  property bool savingPreset: false
  property string activePreset: ""
  property var userNames: []
  property var undoStack: []
  property var preDragSnap: null
  property var trial: null
  property string notice: ""
  property string lastBackup: ""
  property var expanded: ({ frost: true, blur: true, shapes: true, bar: true })
  // header+footer height around the scroller, so the list scrolls under them
  property real chromeH: Math.max(0, outerCol.implicitHeight - flick.implicitHeight)

  function stateGet(path, fallback) {
    var node = state
    var parts = path.split(".")
    for (var i = 0; i < parts.length; i++) {
      if (!node || node[parts[i]] === undefined) return fallback
      node = node[parts[i]]
    }
    return node === undefined ? fallback : node
  }

  function capName(name) {
    if (!name) return ""
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

  function parseCtlResult(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function adoptResult(text) {
    var res = parseCtlResult(text)
    if (!res) return false
    if (res.state) root.state = res.state
    if (res.ok) {
      root.error = ""
      if (res.active !== undefined) root.activePreset = res.active || ""
      if (res.user) root.userNames = res.user
    }
    if (res.note) root.setNotice(res.note)
    if (res.backup) root.lastBackup = res.backup
    if (res.restored) root.setNotice("Restored " + String(res.restored).split("/").pop())
    if (!res.ok && res.error) root.error = res.error
    return res.ok === true
  }

  function startCtl(args) {
    var parts = [root.ctl].concat(args)
    runProc.command = parts
    runProc.running = true
  }

  function refresh() { startCtl(["readback"]) }

  function liveTick(payload) {
    liveProc.command = [root.ctl, "live", JSON.stringify(payload)]
    liveProc.running = true
  }

  function persistFull() {
    // blur/shapes release: persist + block rewrite, no reload (already live)
    // roundingMem rides along so the corners switch remembers its radius
    var payload = { blur: state.blur, shapes: state.shapes,
                    roundingMem: root.stateGet("roundingMem", 16) }
    startCtl(["persist", JSON.stringify(payload)])
  }

  function releaseFrost() {
    frostDebounce.restart()
  }

  function doRevert() {
    root.cancelTrialKeep()
    startCtl(["revert"])
  }

  function loadClasses() {
    classProc.command = [root.ctl, "classes"]
    classProc.running = true
  }

  // ── undo stack (in-session) ──────────────────────────────────────────
  function setNotice(text) {
    root.notice = text
    noticeClear.restart()
  }

  function snap() {
    return {
      frost: JSON.parse(JSON.stringify(root.state.frost || {})),
      blur: JSON.parse(JSON.stringify(root.state.blur || {})),
      shapes: JSON.parse(JSON.stringify(root.state.shapes || {})),
      bar: { transparent: root.stateGet("bar.transparent", false) },
    }
  }

  function beginDrag() {
    root.keepTrial()
    if (!root.preDragSnap) root.preDragSnap = root.snap()
  }

  function endDrag(label) {
    if (!root.preDragSnap) return
    var pre = root.preDragSnap
    root.preDragSnap = null
    if (JSON.stringify(pre) === JSON.stringify(root.snap())) return  // no-op drag
    root.pushUndo(label, pre)
  }

  function pushUndo(label, snapshot) {
    var stack = root.undoStack.slice()
    stack.push({ label: label, snap: snapshot })
    if (stack.length > 20) stack = stack.slice(stack.length - 20)
    root.undoStack = stack
  }

  function undo() {
    if (root.undoStack.length === 0) return
    root.cancelTrialKeep()
    var stack = root.undoStack.slice()
    var entry = stack.pop()
    root.undoStack = stack
    root.applySnap(entry.snap)
    root.setNotice("Undo: " + entry.label)
  }

  function applySnap(snapshot) {
    startCtl(["set", JSON.stringify(snapshot)])
  }

  // ── style tour trial: apply on right-click, auto-revert in 10s ───────
  function startTrial(name, pre) {
    root.trial = { snap: pre, name: name, left: 10 }
    trialTimer.restart()
    root.setNotice("◷ " + root.capName(name) + " — auto-reverts in 10s unless you interact")
  }

  function cancelTrialKeep() {
    if (root.trial) {
      root.trial = null
      trialTimer.stop()
    }
  }

  function keepTrial() {
    if (!root.trial) return
    var t = root.trial
    root.trial = null
    trialTimer.stop()
    root.pushUndo("tour: " + t.name, t.snap)
    root.setNotice(root.capName(t.name) + " kept")
  }

  function tourNext() {
    root.keepTrial()
    var i = root.tourOrder.indexOf(root.activePreset)
    var next = root.tourOrder[(i + 1) % root.tourOrder.length]
    var pre = root.snap()
    startCtl(["preset", next])
    root.startTrial(next, pre)
  }

  // ── preset / sync / app-row actions (each undoable) ──────────────────
  function applyPreset(name) {
    root.keepTrial()
    root.pushUndo("preset " + name, root.snap())
    startCtl(["preset", name])
  }

  function saveUserPreset(name) {
    startCtl(["savepreset", name])
  }

  function deleteUserPreset(name) {
    root.keepTrial()
    startCtl(["delpreset", name])
  }

  function syncAll() {
    root.keepTrial()
    root.pushUndo("sync all apps", root.snap())
    startCtl(["sync"])
  }

  function toggleBar() {
    root.keepTrial()
    root.pushUndo("bar transparency", root.snap())
    startCtl(["bar", root.stateGet("bar.transparent", false) ? "false" : "true"])
  }

  // SHAPES corners switch: off squares the windows, on restores the last
  // radius (roundingMem, engine-maintained on every save).
  function toggleRounded() {
    root.keepTrial()
    root.beginDrag()
    var r = root.stateGet("shapes.rounding", 0)
    if (r > 0) {
      root.state.roundingMem = r
      root.state.shapes.rounding = 0
    } else {
      root.state.shapes.rounding = root.stateGet("roundingMem", 16) || 16
    }
    root.stateChanged()
    root.endDrag("rounded corners")
    root.persistFull()
  }

  function solidOn(klass) {
    return (root.stateGet("frost.keepSolid", []) || []).indexOf(klass) >= 0
  }

  function toggleSolid(klass) {
    root.keepTrial()
    root.pushUndo("keep-solid " + klass, root.snap())
    if (!state.frost) state.frost = { all: 0.85, apps: {}, keepSolid: [] }
    var ks = (state.frost.keepSolid || []).slice()
    var i = ks.indexOf(klass)
    if (i >= 0) ks.splice(i, 1)
    else ks.push(klass)
    state.frost.keepSolid = ks
    stateChanged()
    releaseFrost()
  }

  function addAppRow(klass, value) {
    root.keepTrial()
    root.pushUndo("add app " + klass, root.snap())
    if (!state.frost) state.frost = { all: 0.85, apps: {}, keepSolid: [] }
    if (!state.frost.apps) state.frost.apps = {}
    state.frost.apps[klass] = value
    stateChanged()
    releaseFrost()
  }

  function removeAppRow(klass) {
    root.keepTrial()
    if (state.frost && state.frost.apps && state.frost.apps[klass] !== undefined) {
      root.pushUndo("remove app " + klass, root.snap())
      delete state.frost.apps[klass]
      stateChanged()
      releaseFrost()
    }
  }

  function toggleSection(key) {
    root.keepTrial()
    var e = root.expanded
    var next = { frost: e.frost, blur: e.blur, shapes: e.shapes, bar: e.bar }
    next[key] = !e[key]
    root.expanded = next
  }

  function commitSave() {
    root.keepTrial()
    var name = saveField.text.trim()
    if (name === "") return
    root.saveUserPreset(name)
    saveField.text = ""
    root.savingPreset = false
  }

  Component.onCompleted: {
    startCtl(["init"])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { refresh(); loadClasses() }

  Process {
    id: runProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptResult(text)
    }
  }

  Process {
    id: liveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = parseCtlResult(text)
        if (res && res.error) root.error = res.error
        else if (res && res.ok) root.error = ""
      }
    }
  }

  // Frost applies are debounced so quick consecutive releases coalesce.
  Timer {
    id: frostDebounce
    interval: 250
    onTriggered: {
      runProc.command = [root.ctl, "frost", JSON.stringify({ frost: root.state.frost })]
      runProc.running = true
    }
  }

  // 10s keep-or-revert trial for gesture-applied style-tour presets
  Timer {
    id: trialTimer
    interval: 1000
    repeat: true
    onTriggered: {
      if (!root.trial) { stop(); return }
      var t = root.trial
      t.left -= 1
      root.trial = t
      if (t.left <= 0) {
        stop()
        root.trial = null
        root.applySnap(t.snap)
        root.setNotice("Reverted trial (" + root.capName(t.name) + ")")
      }
    }
  }

  Timer {
    id: noticeClear
    interval: 6000
    onTriggered: root.notice = ""
  }

  Process {
    id: classProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = parseCtlResult(text)
        if (res && res.ok) root.classes = res.classes || []
      }
    }
  }

  // ── bar icon ────────────────────────────────────────────────────────
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        GlassIcon {
          anchors.centerIn: parent
          size: Style.space(11)
          color: button.foreground
          frosted: root.stateGet("frost.all", 0.85) < 0.95
          blurOn: root.stateGet("blur.enabled", true)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.tourNext()
      else if (buttonCode === Qt.MiddleButton) {
        root.keepTrial()
        root.pushUndo("blur enabled", root.snap())
        root.state.blur.enabled = !root.state.blur.enabled
        root.stateChanged()
        root.persistFull()
      }
      else {
        root.keepTrial()   // interacting keeps a running trial
        root.toggle()
      }
    }
    onWheelMoved: function(delta) {
      // wheel over icon → global frost ±0.05, applied on release
      root.keepTrial()
      var step = delta > 0 ? 1 : -1
      var v = root.stateGet("frost.all", 0.85)
      v = Math.max(0.30, Math.min(1.0, Math.round((v + step * 0.05) * 100) / 100))
      root.beginDrag()
      root.state.frost.all = v
      root.stateChanged()
      wheelDebounce.restart()
    }
  }

  Timer {
    id: wheelDebounce
    interval: 350
    onTriggered: {
      root.endDrag("frost")
      root.releaseFrost()
    }
  }

  // ── panel popup ────────────────────────────────────────────────────
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(outerCol.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus || saveField.activeFocus
      onCloseRequested: root.close()
      // digits apply presets (1-9, 0 = stock); u/r undo/revert. While an
      // inline editor is focused (blocked), PanelKeyCatcher forwards instead.
      onTextKey: function(t) {
        if (t >= "1" && t <= "9") root.applyPreset(root.builtinOrder[t.charCodeAt(0) - 49])
        else if (t === "0") root.applyPreset(root.builtinOrder[9])
        else if (t === "u") root.undo()
        else if (t === "r") root.doRevert()
      }
      // arrows / j / k scroll the section list
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          var maxY = Math.max(0, flick.contentHeight - flick.height)
          flick.contentY = Math.max(0, Math.min(maxY, flick.contentY + dy * Style.space(28)))
        }
      }

      Column {
        id: outerCol
        anchors.fill: parent
        spacing: Style.space(10)

          // ── sticky header: title + preset chips + save-as + notices ──
          Column {
            id: headerBlock
            width: parent.width
            spacing: Style.space(6)

            Row {
              width: parent.width
              spacing: Style.space(6)
              PanelSectionHeader {
                text: "GLASS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.activePreset === "" ? "Custom" : root.capName(root.activePreset)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: root.builtinOrder
                Button {
                  text: root.capName(modelData)
                  fontSize: Style.font.caption
                  fontFamily: root.bar.fontFamily
                  foreground: root.bar.foreground
                  bordered: true
                  selected: root.activePreset === modelData
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  onClicked: root.applyPreset(modelData)
                }
              }
              Repeater {
                model: root.userNames
                Row {
                  spacing: Style.space(2)
                  Button {
                    text: modelData
                    fontSize: Style.font.caption
                    fontFamily: root.bar.fontFamily
                    foreground: root.bar.foreground
                    bordered: true
                    selected: root.activePreset === modelData
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(2)
                    onClicked: root.applyPreset(modelData)
                  }
                  Button {
                    text: "✕"
                    fontSize: Style.font.caption - 1
                    fontFamily: root.bar.fontFamily
                    foreground: Qt.darker(root.bar.foreground, 1.6)
                    bordered: false
                    horizontalPadding: Style.space(2)
                    verticalPadding: Style.space(2)
                    onClicked: root.deleteUserPreset(modelData)
                  }
                }
              }
              Button {
                text: root.savingPreset ? "Cancel" : "+ Save as…"
                fontSize: Style.font.caption
                fontFamily: root.bar.fontFamily
                foreground: root.bar.foreground
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                onClicked: {
                  root.keepTrial()
                  root.savingPreset = !root.savingPreset
                  if (root.savingPreset) saveField.forceActiveFocus()
                }
              }
            }

            Row {
              visible: root.savingPreset
              width: parent.width
              spacing: Style.space(6)
              TextField {
                id: saveField
                width: parent.width - saveBtn.width - parent.spacing
                placeholderText: "preset name"
                foreground: root.bar.foreground
                font.pixelSize: Style.font.caption
                verticalPadding: Style.space(3)
                onAccepted: root.commitSave()
              }
              Button {
                id: saveBtn
                text: "Save"
                fontSize: Style.font.caption
                fontFamily: root.bar.fontFamily
                foreground: root.bar.foreground
                bordered: true
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: root.commitSave()
              }
            }

            Row {
              visible: root.notice !== ""
              width: parent.width
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.notice
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              visible: root.error !== ""
              width: parent.width
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "⚠ " + root.error
                color: "#f38ba8"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.bar.foreground }

          // ── middle: accordion sections scroll under the sticky chrome ──
          Flickable {
            id: flick
            width: parent.width
            implicitHeight: innerCol.implicitHeight
            height: Math.min(Math.max(0, panel.contentHeight - root.chromeH), implicitHeight)
            contentWidth: width
            contentHeight: innerCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height && !root.dragging

            Column {
              id: innerCol
              width: flick.width
              spacing: Style.space(10)

              // ── FROST ────────────────────────────────────────────────
              Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    text: root.expanded.frost ? "▾" : "▸"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSectionHeader {
                    text: "FROST — applies on release"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TapHandler { onTapped: root.toggleSection("frost") }
                }

                Column {
                  visible: root.expanded.frost
                  width: parent.width
                  spacing: Style.space(6)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "All apps"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      id: frostSlider
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0.30
                      maximum: 1.0
                      step: 0.05
                      value: root.stateGet("frost.all", 0.85)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.frost.all = Math.round(v * 100) / 100
                        root.stateChanged()
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("frost")
                        root.releaseFrost()
                      }
                    }
                    Text {
                      text: Math.round(root.stateGet("frost.all", 0.85) * 100) + "%"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Repeater {
                    model: {
                      var apps = root.stateGet("frost.apps", {})
                      return Object.keys(apps).sort()
                    }
                    Row {
                      width: parent.width
                      spacing: Style.space(6)
                      property string klass: modelData
                      Text {
                        text: klass.length > 16 ? klass.substring(0, 15) + "…" : klass
                        color: Qt.darker(root.bar.foreground, 1.25)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        width: Style.space(84)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      WheelSafeSlider {
                        width: parent.width - parent.spacing * 4 - Style.space(84) - Style.space(34)
                               - solidBtn.implicitWidth - delBtn.implicitWidth
                        bar: root.bar
                        minimum: 0.30
                        maximum: 1.0
                        step: 0.05
                        value: root.stateGet("frost.apps." + klass, 0.85)
                        onMoved: function(v) {
                          root.dragging = true
                          root.beginDrag()
                          root.state.frost.apps[klass] = Math.round(v * 100) / 100
                          root.stateChanged()
                        }
                        onReleased: function(v) {
                          root.dragging = false
                          root.endDrag("frost " + klass)
                          root.releaseFrost()
                        }
                      }
                      Text {
                        text: Math.round(root.stateGet("frost.apps." + klass, 0.85) * 100) + "%"
                        color: Qt.darker(root.bar.foreground, 1.25)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        width: Style.space(34)
                        horizontalAlignment: Text.AlignRight
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      Button {
                        id: solidBtn
                        text: "S"
                        fontSize: Style.font.caption - 1
                        fontFamily: root.bar.fontFamily
                        foreground: root.bar.foreground
                        bordered: true
                        selected: root.solidOn(klass)
                        horizontalPadding: Style.space(4)
                        verticalPadding: Style.space(1)
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.toggleSolid(klass)
                      }
                      Button {
                        id: delBtn
                        text: "✕"
                        fontSize: Style.font.caption - 1
                        fontFamily: root.bar.fontFamily
                        foreground: Qt.darker(root.bar.foreground, 1.6)
                        bordered: false
                        horizontalPadding: Style.space(2)
                        verticalPadding: Style.space(1)
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.removeAppRow(klass)
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Button {
                      text: root.addingApp ? "Done" : "+ Add app…"
                      fontSize: Style.font.caption
                      fontFamily: root.bar.fontFamily
                      foreground: root.bar.foreground
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: {
                        root.addingApp = !root.addingApp
                        if (root.addingApp) root.loadClasses()
                      }
                    }
                    TextField {
                      id: addField
                      visible: root.addingApp
                      width: parent.width - parent.spacing - (addBtn.visible ? addBtn.width + parent.spacing : 0)
                      placeholderText: "window class"
                      foreground: root.bar.foreground
                      font.pixelSize: Style.font.caption
                      verticalPadding: Style.space(3)
                      onAccepted: {
                        if (text.trim() !== "") { root.addAppRow(text.trim(), root.stateGet("frost.all", 0.85)); text = "" }
                      }
                    }
                    Button {
                      id: addBtn
                      visible: root.addingApp
                      text: "Add"
                      fontSize: Style.font.caption
                      fontFamily: root.bar.fontFamily
                      foreground: root.bar.foreground
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: {
                        if (addField.text.trim() !== "") { root.addAppRow(addField.text.trim(), root.stateGet("frost.all", 0.85)); addField.text = "" }
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Button {
                      id: syncBtn
                      text: "⇅ Sync all"
                      fontSize: Style.font.caption
                      fontFamily: root.bar.fontFamily
                      foreground: root.bar.foreground
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.syncAll()
                    }
                    Text {
                      text: "every app on one setting — removes per-app rules"
                      color: Qt.darker(root.bar.foreground, 1.6)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption - 1
                      width: parent.width - syncBtn.width - parent.spacing
                      wrapMode: Text.WordWrap
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Flow {
                    visible: root.addingApp && root.classes.length > 0
                    width: parent.width
                    spacing: Style.space(4)
                    Repeater {
                      model: root.classes
                      Button {
                        text: modelData
                        fontSize: Style.font.caption - 1
                        fontFamily: root.bar.fontFamily
                        foreground: Qt.darker(root.bar.foreground, 1.25)
                        bordered: true
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(1)
                        onClicked: { root.addAppRow(modelData, root.stateGet("frost.all", 0.85)) }
                      }
                    }
                  }

                  Text {
                    text: "S = keep solid (1.00) · ⇅ = wipe per-app rules"
                    color: Qt.darker(root.bar.foreground, 1.6)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption - 1
                    width: parent.width
                    wrapMode: Text.WordWrap
                  }
                }
              }

              PanelSeparator { width: parent.width; foreground: root.bar.foreground }

              // ── BLUR ────────────────────────────────────────────────
              Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    text: root.expanded.blur ? "▾" : "▸"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSectionHeader {
                    text: "BLUR — applies live while dragging"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TapHandler { onTapped: root.toggleSection("blur") }
                }

                Column {
                  visible: root.expanded.blur
                  width: parent.width
                  spacing: Style.space(6)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Enabled"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: parent.width - parent.spacing - blurToggle.width
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    ToggleSwitch {
                      id: blurToggle
                      checked: root.stateGet("blur.enabled", true)
                      foreground: root.bar.foreground
                      onToggled: {
                        root.beginDrag()
                        root.state.blur.enabled = !root.state.blur.enabled
                        root.stateChanged()
                        root.endDrag("blur enabled")
                        root.persistFull()
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Size"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0
                      maximum: 24
                      step: 1
                      integer: true
                      value: root.stateGet("blur.size", 14)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.blur.size = v
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("blur")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("blur.size", 14)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Passes"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 1
                      maximum: 5
                      step: 1
                      integer: true
                      value: root.stateGet("blur.passes", 3)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.blur.passes = v
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("blur")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("blur.passes", 3)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Brightness"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0.20
                      maximum: 2.0
                      step: 0.05
                      value: root.stateGet("blur.brightness", 1.0)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.blur.brightness = Math.round(v * 100) / 100
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("blur")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("blur.brightness", 1.0).toFixed(2)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Contrast"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0.20
                      maximum: 2.0
                      step: 0.05
                      value: root.stateGet("blur.contrast", 1.0)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.blur.contrast = Math.round(v * 100) / 100
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("blur")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("blur.contrast", 1.0).toFixed(2)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Noise"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0
                      maximum: 0.10
                      step: 0.001
                      value: root.stateGet("blur.noise", 0.011)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.blur.noise = Math.round(v * 1000) / 1000
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("blur")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("blur.noise", 0.011).toFixed(3)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }

              PanelSeparator { width: parent.width; foreground: root.bar.foreground }

              // ── SHAPES ──────────────────────────────────────────────
              Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    text: root.expanded.shapes ? "▾" : "▸"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSectionHeader {
                    text: "SHAPES — applies live while dragging"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TapHandler { onTapped: root.toggleSection("shapes") }
                }

                Column {
                  visible: root.expanded.shapes
                  width: parent.width
                  spacing: Style.space(6)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Rounded corners"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: parent.width - parent.spacing - roundToggle.width
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    ToggleSwitch {
                      id: roundToggle
                      checked: root.stateGet("shapes.rounding", 0) > 0
                      foreground: root.bar.foreground
                      onToggled: root.toggleRounded()
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Rounding"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0
                      maximum: 24
                      step: 1
                      integer: true
                      value: root.stateGet("shapes.rounding", 0)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.shapes.rounding = v
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("shapes")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("shapes.rounding", 0)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: "Dim inactive"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      width: parent.width - parent.spacing - dimToggle.width
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    ToggleSwitch {
                      id: dimToggle
                      checked: root.stateGet("shapes.dimInactive", false)
                      foreground: root.bar.foreground
                      onToggled: {
                        root.beginDrag()
                        root.state.shapes.dimInactive = !root.state.shapes.dimInactive
                        root.stateChanged()
                        root.endDrag("dim inactive")
                        root.persistFull()
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    visible: root.stateGet("shapes.dimInactive", false)
                    Text {
                      text: "Strength"
                      color: Qt.darker(root.bar.foreground, 1.25)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(84)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    WheelSafeSlider {
                      width: parent.width - parent.spacing - Style.space(84) - Style.space(34)
                      bar: root.bar
                      minimum: 0
                      maximum: 0.60
                      step: 0.05
                      value: root.stateGet("shapes.dimStrength", 0.15)
                      onMoved: function(v) {
                        root.dragging = true
                        root.beginDrag()
                        root.state.shapes.dimStrength = Math.round(v * 100) / 100
                        root.stateChanged()
                        root.liveTick({ blur: root.state.blur, shapes: root.state.shapes })
                      }
                      onReleased: function(v) {
                        root.dragging = false
                        root.endDrag("shapes dim")
                        root.persistFull()
                      }
                    }
                    Text {
                      text: root.stateGet("shapes.dimStrength", 0.15).toFixed(2)
                      color: Qt.darker(root.bar.foreground, 1.25)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }

              PanelSeparator { width: parent.width; foreground: root.bar.foreground }

              // ── BAR ─────────────────────────────────────────────────
              Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    text: root.expanded.bar ? "▾" : "▸"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSectionHeader {
                    text: "BAR"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TapHandler { onTapped: root.toggleSection("bar") }
                }

                Row {
                  visible: root.expanded.bar
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    text: "Transparent"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    width: parent.width - parent.spacing - barToggle.width
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    id: barToggle
                    checked: root.stateGet("bar.transparent", false)
                    foreground: root.bar.foreground
                    onToggled: root.toggleBar()
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.bar.foreground }

          // ── sticky footer: hint / trial countdown + undo & revert ────
          Row {
            id: footerRow
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: root.trial
                ? ("◷ " + root.capName(root.trial.name) + " — reverts in " + root.trial.left + "s")
                : "wheel = frost · right-click = style tour · middle = blur · keys 1-9/0 / u / r"
              color: root.trial ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption - 1
              width: parent.width - undoBtn.width - revertBtn.width - parent.spacing * 2
              wrapMode: Text.WordWrap
              anchors.verticalCenter: parent.verticalCenter
            }
            Button {
              id: undoBtn
              text: "Undo"
              fontSize: Style.font.caption
              fontFamily: root.bar.fontFamily
              foreground: root.bar.foreground
              bordered: true
              opacity: root.undoStack.length > 0 ? 1 : 0.35
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.undo()
            }
            Button {
              id: revertBtn
              text: "Revert"
              fontSize: Style.font.caption
              fontFamily: root.bar.fontFamily
              foreground: root.bar.foreground
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.doRevert()
            }
          }
        }
    }
  }
}
