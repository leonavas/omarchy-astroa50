import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Astro A50 (Gen 4 or Gen 5) in the bar: the headset's battery, and the
// settings Astro Command Center / G HUB would otherwise own on Windows.
//
// Everything goes through bin/astro-a50, which speaks each generation's
// vendor HID protocol over /dev/hidrawN and reports which features the
// connected station has; every section below is gated on that list.
//
// Gen 4 writes change the station's *active* values at once; they survive a
// power cycle only after Save, the station's own two-step model, kept as-is
// rather than hidden behind an auto-save that would wear its flash on every
// slider drag. Gen 5 applies everything immediately and has no Save.
Panel {
  id: root
  moduleName: "leonavas.astroa50"
  ipcTarget: "leonavas.astroa50"
  manageIpc: false

  // ------------------------------------------------------------- settings
  readonly property string glyph: String(setting("glyph", "󰋋"))
  readonly property string offGlyph: String(setting("offGlyph", "󰟎"))
  readonly property bool showPercentage: Model.truthy(setting("showPercentage", false), false)
  readonly property bool hideWhenAbsent: Model.truthy(setting("hideWhenAbsent", true), true)
  readonly property bool dimWhenOff: Model.truthy(setting("dimWhenOff", true), true)
  readonly property bool tintWhenLow: Model.truthy(setting("tintWhenLow", true), true)
  readonly property int lowThreshold: Model.clampInt(setting("lowThreshold", 15), 0, 100)
  readonly property int criticalThreshold: Math.min(root.lowThreshold,
    Model.clampInt(setting("criticalThreshold", 5), 0, 100))
  readonly property bool notifyLow: Model.truthy(setting("notifyLow", true), true)
  readonly property int pollSeconds: Model.clampInt(setting("pollSeconds", 60), 10, 3600)

  readonly property string script: String(Qt.resolvedUrl("bin/astro-a50")).replace(/^file:\/\//, "")

  // ---------------------------------------------------------------- state
  // The last `astro-a50 status`, with optimistic edits folded in while a
  // write is in flight so a slider does not snap back under the hand.
  property var station: ({ connected: false, error: "absent" })
  property var firmware: ({})

  readonly property bool connected: !!root.station.connected && !root.station.error
  readonly property bool present: !!root.station.connected
  readonly property bool headsetOn: root.connected && !!(root.station.headset || {}).on
  readonly property bool docked: root.connected && !!(root.station.headset || {}).docked
  readonly property bool hasReading: Model.hasReading(root.station)
  readonly property int percent: root.hasReading ? Number(root.station.battery.percent) : 0
  readonly property bool charging: root.hasReading && !!root.station.battery.charging
  readonly property bool discharging: root.headsetOn && !root.docked
  readonly property string timeLeft: root.hasReading ? Model.timeLeft(root.station.battery.minutesLeft) : ""
  readonly property string alertLevel: root.hasReading
    ? Model.alertLevel(root.percent, root.charging, root.lowThreshold, root.criticalThreshold)
    : ""
  readonly property bool low: root.alertLevel.length > 0
  readonly property bool critical: root.alertLevel === "critical"
  readonly property bool unsaved: root.connected && !!root.station.unsaved

  readonly property var features: root.connected ? (root.station.features || []) : []
  function has(feature) { return root.features.indexOf(feature) !== -1 }

  // Gen 4 keeps three named presets on the station (1..3); Gen 5 has one live
  // curve (preset 0) and the panel offers starting templates for it.
  readonly property int eqPreset: root.station.eqPreset === undefined ? 1 : Number(root.station.eqPreset)
  readonly property int eqRange: Number(root.station.eqRange || 7)
  readonly property var eqGains: {
    var gains = root.station.eqGain ? root.station.eqGain[String(root.eqPreset)] : null
    return gains && gains.active ? gains.active : []
  }
  readonly property var eqFreqs: root.station.eqFreqs || []
  readonly property var eqTemplateNames: root.has("eq-templates") ? (root.station.eqNames || []) : []
  readonly property string eqTemplate: Model.matchTemplate(root.station.eqTemplates, root.eqGains)

  // The curve the station powers up with, and the one in the backup taken
  // before this widget ever wrote anything — the two ways back from an
  // accidental edit: undo what is not saved yet, or return to the original
  // even after a Save.
  readonly property var eqSaved: {
    var gains = root.station.eqGain ? root.station.eqGain[String(root.eqPreset)] : null
    return gains && gains.saved ? gains.saved : null
  }
  property var backup: null
  readonly property var eqOriginal: {
    var gains = root.backup && root.backup.eqGain ? root.backup.eqGain[String(root.eqPreset)] : null
    return gains && gains.saved ? gains.saved : null
  }
  readonly property bool eqUnsaved: root.has("save") && !!root.eqSaved && !Model.sameGains(root.eqGains, root.eqSaved)
  readonly property bool eqChanged: root.has("save") && root.backup && root.backup.generation !== "Gen 5" &&
    !!root.eqOriginal && !Model.sameGains(root.eqGains, root.eqOriginal)

  FileView {
    path: Quickshell.env("HOME") + "/.local/share/astro-a50/backup-original.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.backup = Model.parseStatus(text())
    onLoadFailed: root.backup = null
  }

  property string themeYellow: ""
  readonly property color warning: root.themeYellow.length > 0 ? root.themeYellow : "#e0af68"
  readonly property color alertColor: root.critical
    ? root.bar.urgent
    : (root.low ? root.warning : root.bar.foreground)

  PersistentProperties {
    id: persisted
    reloadableId: "leonavas-astroa50"
    property bool notifiedLow: false
    property bool notifiedCritical: false
  }

  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.themeYellow = Model.themeColor(text(), ["yellow", "bright_yellow"], "")
    onLoadFailed: root.themeYellow = ""
  }
  Connections {
    target: Color
    function onForegroundChanged() { themeColors.reload() }
  }

  // ------------------------------------------------------------ reading

  // Bumped by every write, so a status read that started before a write
  // landed is dropped instead of painting the old value back.
  property int writeSeq: 0
  property int statusSeq: 0

  function refresh() {
    if (statusProc.running) return
    root.statusSeq = root.writeSeq
    statusProc.running = true
  }

  function applyStatus(raw) {
    if (root.statusSeq !== root.writeSeq || writeProc.running) {
      settleTimer.restart()
      return
    }
    var next = Model.parseStatus(raw)
    var wasConnected = root.connected
    root.station = next
    if (root.connected && !wasConnected && !infoProc.running) infoProc.running = true
  }

  // ------------------------------------------------------------ writing

  // One write in flight at a time, the rest coalesced by key: a slider drag
  // emits far more values than the station needs, and only the latest of each
  // setting matters.
  property var pending: ({})
  property var pendingOrder: []

  function write(key, value, patch) {
    root.writeSeq++
    if (patch) {
      var next = Model.copy(root.station)
      patch(next)
      next.unsaved = true
      root.station = next
    }
    var queued = root.pending
    if (queued[key] === undefined) root.pendingOrder = root.pendingOrder.concat([key])
    queued[key] = String(value)
    root.pending = queued
    root.pumpWrites()
  }

  function pumpWrites() {
    if (writeProc.running || root.pendingOrder.length === 0) return
    var key = root.pendingOrder[0]
    var value = root.pending[key]
    var rest = root.pendingOrder.slice(1)
    var queued = root.pending
    delete queued[key]
    root.pending = queued
    root.pendingOrder = rest
    writeProc.command = [root.script, "set", key, value]
    writeProc.running = true
  }

  function setSlider(key, stateKey, value) {
    var v = Math.round(value)
    root.write(key, v, function(s) { if (s[stateKey]) s[stateKey].active = v })
  }

  function setEqPreset(preset) {
    var p = Model.clampInt(preset, 1, 3)
    // The preset is not a saved/active pair on the station — it switches at
    // once and is remembered on its own — so it leaves `unsaved` alone.
    root.write("eq-preset", p, null)
    var next = Model.copy(root.station)
    next.eqPreset = p
    root.station = next
  }

  function cycleEqPreset(step) {
    if (root.has("eq-presets")) {
      root.setEqPreset(((root.eqPreset - 1 + step + 3) % 3) + 1)
      return
    }
    var names = root.eqTemplateNames
    if (names.length === 0) return
    var at = names.indexOf(root.eqTemplate)
    var next = at === -1 ? (step > 0 ? 0 : names.length - 1) : (at + step + names.length) % names.length
    root.setEqTemplate(names[next])
  }

  function setEqTemplate(name) {
    var gains = root.station.eqTemplates ? root.station.eqTemplates[name] : null
    if (!gains) return
    var preset = String(root.eqPreset)
    root.write("eq-template", name, function(s) {
      if (s.eqGain && s.eqGain[preset]) s.eqGain[preset].active = gains.slice()
    })
  }

  function setNoiseGate(mode) {
    root.write("noise-gate", mode, function(s) { if (s.noiseGate) s.noiseGate.active = mode })
  }

  function setSidetone(value) {
    // Gen 5 has seven sidetone levels; snap so the readout shows one of them.
    var step = Number(root.station.sidetoneStep || 1)
    var v = Math.round(Math.round(value / step) * step)
    root.write("sidetone", v, function(s) { s.sidetone = { active: v, saved: v } })
  }

  function setMicEq(preset) {
    var p = Model.clampInt(preset, 0, 2)
    root.write("mic-eq", p, function(s) { if (s.micEq) s.micEq.active = p })
  }

  function nudgeBand(band, step) {
    var gains = root.eqGains.slice()
    gains[band] = Model.clampInt(Number(gains[band]) + step, -root.eqRange, root.eqRange)
    root.setBandGains(gains)
  }

  function setBandGains(gains) {
    if (!gains || gains.length !== root.eqGains.length || gains.length === 0) return
    var values = gains.map(function(g) { return Model.clampInt(g, -root.eqRange, root.eqRange) })
    var preset = String(root.eqPreset)
    root.write("eq-gain", preset + ":" + values.join(","), function(s) {
      if (s.eqGain && s.eqGain[preset]) s.eqGain[preset].active = values
    })
  }

  function save() {
    if (saveProc.running || !root.connected) return
    root.writeSeq++
    saveProc.running = true
  }

  // ------------------------------------------------------------- alerts

  function checkLow() {
    if (!root.notifyLow || !root.hasReading) return
    if (!root.low && (root.percent > root.lowThreshold || root.charging)) persisted.notifiedLow = false
    if (!root.critical && (root.percent > root.criticalThreshold || root.charging)) persisted.notifiedCritical = false
    if (!root.low || notifyProc.running) return

    if (root.critical) {
      if (persisted.notifiedCritical) return
      persisted.notifiedCritical = true
      persisted.notifiedLow = true
      notifyProc.command = ["notify-send", "--app-name=Astro A50", "--urgency=critical",
        "--expire-time=30000", "--icon=battery-caution", "Headset battery critical",
        root.percent + "% left" + (root.timeLeft.length > 0 ? " (about " + root.timeLeft + ")" : "") +
        " — dock it now, it is about to switch off."]
    } else {
      if (persisted.notifiedLow) return
      persisted.notifiedLow = true
      notifyProc.command = ["notify-send", "--app-name=Astro A50", "--urgency=normal",
        "--icon=audio-headset", "Headset battery running out",
        root.percent + "% left" + (root.timeLeft.length > 0 ? " (about " + root.timeLeft + ")" : "") +
        " — time to put it back on the dock."]
    }
    notifyProc.running = true
  }

  onLowChanged: root.checkLow()
  onCriticalChanged: root.checkLow()
  onPercentChanged: root.checkLow()
  onOpenedChanged: if (root.opened) root.refresh()

  function togglePercentage() {
    var next = {}
    for (var key in root.settings) next[key] = root.settings[key]
    next.showPercentage = !root.showPercentage
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  Component.onCompleted: root.refresh()

  // ------------------------------------------------------------------ IPC
  IpcHandler {
    target: "leonavas.astroa50"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function save(): void { root.save() }
    function set(key: string, value: string): void { root.write(key, value, null); settleTimer.restart() }
    function battery(): string { return root.hasReading ? String(root.percent) : "" }
    function status(): string { return JSON.stringify(root.station) }
  }

  // The bar only needs the battery, so it polls slowly; an open panel polls
  // fast so the headset's own EQ and mix buttons show up while you watch.
  Timer {
    interval: root.opened ? 3000 : root.pollSeconds * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Read back once the writes stop, so the panel ends on what the station
  // actually holds rather than on what was asked of it.
  Timer {
    id: settleTimer
    interval: 600
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    command: [root.script, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: infoProc
    command: [root.script, "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var info = Model.parseStatus(text)
        root.firmware = info.firmware || {}
      }
    }
  }

  property bool saveAfterWrites: false

  Process {
    id: writeProc
    onExited: {
      if (root.pendingOrder.length > 0) {
        root.pumpWrites()
      } else if (root.saveAfterWrites) {
        root.saveAfterWrites = false
        root.save()
      } else {
        settleTimer.restart()
      }
    }
  }

  Process {
    id: saveProc
    command: [root.script, "save"]
    onExited: settleTimer.restart()
  }

  Process { id: notifyProc }

  // ------------------------------------------------------------- output
  // PipeWire sees the station as two sinks, stereo-game and stereo-chat, and
  // the game/voice mix fades between them. Whichever one is the system
  // default is where YouTube, music and games land, so the panel lets you
  // pick it here instead of in the audio panel's device list.
  readonly property var astroSinks: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var out = { game: null, chat: null }
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream) continue
      var kind = Model.astroSinkKind(n.name)
      if (kind.length > 0) out[kind] = n
    }
    return out
  }
  readonly property string defaultOutput: Model.astroSinkKind(
    Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.name : "")

  PwObjectTracker { objects: [root.astroSinks.game, root.astroSinks.chat].filter(function(n) { return !!n }) }

  // Leaving game mode puts the mix back in the middle: outside it the slider
  // is hidden, and a mix left leaning one way would quietly keep one channel
  // down with no control on screen to bring it back.
  property string lastOutput: ""
  onDefaultOutputChanged: {
    var left = root.lastOutput === "game" && root.defaultOutput !== "game"
    root.lastOutput = root.defaultOutput
    if (left && root.connected && root.has("balance")) {
      root.setSlider("balance", "defaultBalance", 127)
      // Saved too, so the headset also powers up centred. SAVE_VALUES is
      // all-or-nothing on the station: anything else unsaved goes with it.
      root.saveAfterWrites = true
    }
  }

  function setOutput(kind) {
    var node = root.astroSinks[kind]
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    // Same helper the audio panel uses: sets the default and moves the
    // application streams already playing, which otherwise stay where they are.
    Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
  }

  // --------------------------------------------------------------- widget
  readonly property bool shown: root.present || !root.hideWhenAbsent

  visible: root.shown
  implicitWidth: root.shown ? button.implicitWidth : 0
  implicitHeight: root.shown ? button.implicitHeight : 0

  onShownChanged: if (!root.shown) close()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool labelled: root.showPercentage && root.hasReading && !vertical

    text: {
      var icon = root.headsetOn || root.docked ? root.glyph : root.offGlyph
      return labelled ? root.percent + "% " + icon : icon
    }
    slotSize: Style.bar.iconSlot * (labelled ? 2 : 1)
    active: root.tintWhenLow && root.low
    activeColor: root.alertColor
    dimmed: root.dimWhenOff && !root.headsetOn
    tooltipText: {
      if (!root.connected) return "Astro A50 — " + Model.stateLabel(root.station).toLowerCase()
      if (!root.hasReading) return "Astro A50 — " + Model.stateLabel(root.station).toLowerCase()
      return "Astro A50 — " + root.percent + "%, " + Model.stateLabel(root.station).toLowerCase() +
        (root.timeLeft.length > 0 ? ", " + root.timeLeft + " left" : "")
    }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.togglePercentage()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (root.connected) root.cycleEqPreset(delta > 0 ? 1 : -1)
    }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.shown
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(760))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.connected && dx !== 0) root.cycleEqPreset(dx)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: heroIcon
            text: root.hasReading ? Model.batteryIcon(root.percent, root.charging)
                                  : (root.headsetOn ? root.glyph : root.offGlyph)
            color: root.alertColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: [root.station.name || "Astro A50", root.station.generation || ""]
                .filter(function(t) { return t.length > 0 }).join(" · ")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: Model.stateLabel(root.station).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Column {
            id: heroPercent
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
              textFormat: Text.PlainText
              text: root.hasReading ? root.percent + "%" : "—"
              color: root.alertColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.right: parent.right
            }

            // How long the current discharge has left at the rate it has
            // been dropping, from the backend's battery log.
            Text {
              visible: root.hasReading && !root.charging && root.discharging
              textFormat: Text.PlainText
              text: root.timeLeft.length > 0 ? root.timeLeft + " left" : "estimating…"
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
            }
          }
        }

        Item {
          visible: root.hasReading
          width: parent.width
          implicitHeight: root.hasReading ? Style.space(8) : 0

          Rectangle {
            id: chargeTrack
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.bar.foreground, 0.12)
          }

          Rectangle {
            anchors.left: chargeTrack.left
            anchors.verticalCenter: chargeTrack.verticalCenter
            height: chargeTrack.height
            radius: chargeTrack.radius
            color: root.alertColor
            width: Math.max(chargeTrack.height, chargeTrack.width * root.percent / 100)
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          }
        }

        // ---------- Not reachable ----------
        Text {
          textFormat: Text.PlainText
          visible: !root.connected
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.station.error === "permission"
            ? "The base station is plugged in but this user cannot open it. Install udev/70-astro-a50.rules from the plugin folder into /etc/udev/rules.d/ and re-plug the base station."
            : (root.station.error === "absent"
               ? "Plug in the base station over USB."
               : String(root.station.message || "The base station did not answer."))
        }

        // ---------- Settings ----------
        Column {
          visible: root.connected
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator { foreground: root.bar.foreground }

          // Two columns: the sound on the left (EQ, mix), the microphone on
          // the right.
          Row {
            id: columns
            width: parent.width
            spacing: Style.space(24)
            readonly property real columnWidth: (width - spacing) / 2

            Column {
              width: columns.columnWidth
              spacing: Style.space(14)
              // EQ preset + its five-band curve
              Column {
                width: parent.width
                spacing: Style.space(8)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(eqHeader.implicitHeight, eqActions.implicitHeight)

                  InfoHeader {
                    id: eqHeader
                    text: "󰺢  EQUALIZER"
                    info: "What you hear in the headset: one gain per frequency band, low on the left to high on the right. Gen 4 keeps three named slots on the base station (ASTRO, PRO and STUDIO from the factory: bass-heavy, footsteps-forward, neutral) and the headset's EQ button cycles them; Gen 5 keeps one curve and the buttons are starting points. Mic EQ is separate and does not change this."
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    anchors.left: parent.left
                    anchors.right: eqActions.left
                    anchors.top: parent.top
                  }

                  Row {
                    id: eqActions
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Style.space(6)

                    Button {
                      text: "Undo"
                      visible: root.eqUnsaved
                      tooltipText: "Back to what this preset has saved on the base station"
                      fontSize: Style.font.caption
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                      bordered: true
                      verticalPadding: Style.spacing.controlPaddingY - Style.space(3)
                      onClicked: root.setBandGains(root.eqSaved)
                    }

                    Button {
                      text: "Original"
                      visible: root.eqChanged
                      tooltipText: "Back to this preset's curve in the original backup (" +
                                   (root.eqOriginal ? root.eqOriginal.map(Model.gainLabel).join(" ") : "") + ")"
                      fontSize: Style.font.caption
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                      bordered: true
                      verticalPadding: Style.spacing.controlPaddingY - Style.space(3)
                      onClicked: root.setBandGains(root.eqOriginal)
                    }
                  }
                }

                ButtonGroup {
                  visible: root.has("eq-presets")
                  options: Model.eqOptions(root.station.eqNames)
                  value: String(root.eqPreset)
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  focusable: false
                  onChanged: function(v) { root.setEqPreset(Number(v)) }
                }

                ButtonGroup {
                  visible: root.has("eq-templates")
                  options: root.eqTemplateNames
                  value: root.eqTemplate
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  focusable: false
                  onChanged: function(v) { root.setEqTemplate(v) }
                }

                Row {
                  id: bands
                  width: parent.width
                  spacing: root.eqGains.length > 5 ? Style.space(3) : Style.space(6)
                  readonly property int count: Math.max(1, root.eqGains.length)
                  readonly property real bandWidth: (width - spacing * (count - 1)) / count

                  Repeater {
                    model: root.eqGains.length
                    delegate: EqBand {
                      required property int index
                      band: index
                      width: bands.bandWidth
                      gain: Number(root.eqGains[index]) || 0
                      freq: root.eqFreqs.length > index ? Model.freqLabel(root.eqFreqs[index]) : ""
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Click above or below the line, or scroll, to move a band by 1 dB." +
                        (root.has("eq-templates") ? " Presets are starting points; the base station keeps one curve." : "")
                  color: root.bar.foreground
                  opacity: 0.5
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              PanelSeparator { foreground: root.bar.foreground }

              Column {
                width: parent.width
                spacing: Style.space(8)

                InfoHeader {
                  text: "󰕾  MIX"
                  info: "Where the PC's audio lands and how game and voice chat are balanced."
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                Item {
                  visible: !!root.astroSinks.game && !!root.astroSinks.chat
                  width: parent.width
                  implicitHeight: visible ? Math.max(outputLabel.implicitHeight, outputGroup.implicitHeight) : 0

                  InfoLabel {
                    id: outputLabel
                    text: "PC output"
                    info: "The station shows up as two sound cards, Game and Chat. This picks which one the PC's own audio (browser, music, games) plays on. Voice apps like Discord belong on Chat."
                    anchors.left: parent.left
                    anchors.top: parent.top
                    width: parent.width * 0.55
                  }

                  ButtonGroup {
                    id: outputGroup
                    anchors.right: parent.right
                    anchors.top: parent.top
                    options: [
                      { value: "game", label: "Game", tooltip: "System audio plays on the game channel" },
                      { value: "chat", label: "Chat", tooltip: "System audio plays on the chat channel" }
                    ]
                    value: root.defaultOutput
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.caption
                    spacing: Style.space(6)
                    focusable: false
                    onChanged: function(v) { root.setOutput(v) }
                  }
                }

                // The mix fades between the two sinks, so it only means something
                // while the PC plays on game and voice apps sit on chat. With the
                // default on chat everything shares one channel and the slider is
                // just a volume knob, so it steps aside.
                Text {
                  textFormat: Text.PlainText
                  visible: root.has("balance") && root.defaultOutput === "chat"
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "The game / voice mix shows while PC output is Game."
                  color: root.bar.foreground
                  opacity: 0.5
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                SettingSlider {
                  visible: root.has("balance") && root.defaultOutput !== "chat"
                  label: "Game / voice"
                  info: "Balance between the station's two channels, Game and Chat, like the mix buttons on the headset. The middle is 50/50; leaving Game as PC output puts it back there."
                  maximum: 255
                  tickCount: 3
                  value: Model.active(root.station, "defaultBalance", 127)
                  valueText: Model.balanceLabel(value)
                  onCommit: function(v) { root.setSlider("balance", "defaultBalance", v) }
                }

                SettingSlider {
                  visible: root.has("headset-volume")
                  label: "Headset volume"
                  info: "Master volume of the headset itself."
                  maximum: 100
                  value: Model.active(root.station, "headsetVolume", 0)
                  valueText: Math.round(value) + "%"
                  onCommit: function(v) { root.setSlider("headset-volume", "headsetVolume", v) }
                }

                // Gen 5's mix lives on a dial on the headset; it reads back but
                // cannot be set from here.
                Item {
                  visible: root.has("chatmix")
                  width: parent.width
                  implicitHeight: visible ? dialLabel.implicitHeight : 0

                  InfoLabel {
                    id: dialLabel
                    text: "Game / voice dial"
                    info: "The mix dial on the headset, read back from it. It can only be turned on the headset."
                    anchors.left: parent.left
                    width: parent.width * 0.55
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: Model.dialLabel(root.station.chatmix)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    anchors.right: parent.right
                  }
                }

                SettingSlider {
                  visible: root.has("dock-light")
                  label: "Dock light"
                  info: "Brightness of the light on the base station."
                  maximum: 100
                  value: Model.active(root.station, "dockLight", 100)
                  valueText: Math.round(value) + "%"
                  onCommit: function(v) { root.setSlider("dock-light", "dockLight", v) }
                }

                SettingSlider {
                  visible: root.has("alert-volume")
                  label: "Alert volume"
                  info: "Volume of the headset's own beeps and voice prompts: power, low battery, mute."
                  maximum: 100
                  value: Model.active(root.station, "alertVolume", 0)
                  valueText: Math.round(value) + "%"
                  onCommit: function(v) { root.setSlider("alert-volume", "alertVolume", v) }
                }
              }
            }

            Column {
              width: columns.columnWidth
              spacing: Style.space(14)
              Column {
                width: parent.width
                spacing: Style.space(8)

                InfoHeader {
                  text: "󰍬  MICROPHONE"
                  info: "How your voice is picked up and sent to others."
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                SettingSlider {
                  visible: root.has("mic-level")
                  label: "Level"
                  info: "Microphone gain: how loud your voice goes out. Too high also picks up keys and breathing."
                  maximum: 100
                  value: Model.active(root.station, "mic", 0)
                  valueText: Math.round(value) + "%"
                  onCommit: function(v) { root.setSlider("mic", "mic", v) }
                }

                SettingSlider {
                  label: "Sidetone"
                  info: "How much of your own voice you hear back in the headset, so you don't end up shouting. 0 is off."
                  maximum: 100
                  step: Number(root.station.sidetoneStep || 1)
                  value: Model.active(root.station, "sidetone", 0)
                  valueText: Math.round(value) + "%"
                  onCommit: function(v) { root.setSidetone(v) }
                }

                InfoLabel {
                  text: "Noise gate"
                  info: "Mutes the mic while the sound stays under a threshold, so background noise stays out between words. Streaming (Off on Gen 5) leaves it open; Night, Home and Tournament cut progressively harder. Tournament is for loud rooms."
                  width: parent.width
                }

                ButtonGroup {
                  options: Model.noiseGateOptions(root.station.generation)
                  value: String(Model.active(root.station, "noiseGate", "") || "")
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.space(6)
                  focusable: false
                  onChanged: function(v) { root.setNoiseGate(v) }
                }

                InfoLabel {
                  visible: root.has("mic-eq")
                  text: "Mic EQ"
                  info: "An equalizer for your voice as the others hear it. It does not touch what you hear, so the curve above stays put. The station only reports the preset number and what each one does is undocumented; record yourself on each to compare."
                  width: parent.width
                }

                ButtonGroup {
                  visible: root.has("mic-eq")
                  options: [{ value: "0", label: "1" }, { value: "1", label: "2" }, { value: "2", label: "3" }]
                  value: String(Model.active(root.station, "micEq", 0))
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.caption
                  focusable: false
                  onChanged: function(v) { root.setMicEq(Number(v)) }
                }
              }
            }
          }

          PanelSeparator {
            visible: root.has("save")
            foreground: root.bar.foreground
          }

          // ---------- Save ----------
          Item {
            visible: root.has("save")
            width: parent.width
            implicitHeight: Math.max(saveCaption.implicitHeight, saveButton.implicitHeight)

            Text {
              textFormat: Text.PlainText
              id: saveCaption
              anchors.left: parent.left
              anchors.right: saveButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.WordWrap
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              text: {
                var fw = root.firmware.base ? "Firmware " + root.firmware.base +
                  (root.firmware.headset ? " / " + root.firmware.headset : "") : ""
                if (saveProc.running) return "Saving…"
                if (root.unsaved) return "Changes are live. Save keeps them after the headset powers off."
                return fw.length > 0 ? "Saved on the base station · " + fw : "Saved on the base station"
              }
            }

            Button {
              id: saveButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Save"
              enabled: root.unsaved && !saveProc.running
              opacity: enabled ? 1 : 0.4
              active: root.unsaved
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              verticalPadding: Style.spacing.controlPaddingY - Style.space(2)
              onClicked: root.save()
            }
          }
        }
      }
    }
  }

  // A labelled slider row: name on the left, value on the right, the track
  // underneath. Moves preview live; the release commits.
  component SettingSlider: Column {
    id: sliderRow
    property string label: ""
    property string valueText: ""
    property real value: 0
    property real maximum: 100
    property int tickCount: 0
    property real step: 1
    property string info: ""
    property bool showInfo: false
    signal commit(real value)

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: rowLabel.implicitHeight

      Text {
        textFormat: Text.PlainText
        id: rowLabel
        text: sliderRow.label
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.left: parent.left
      }

      InfoIcon {
        info: sliderRow.info
        open: sliderRow.showInfo
        anchors.left: rowLabel.right
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: rowLabel.verticalCenter
        onToggled: sliderRow.showInfo = !sliderRow.showInfo
      }

      Text {
        textFormat: Text.PlainText
        text: sliderRow.valueText
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.right: parent.right
      }
    }

    InfoText { text: sliderRow.info; visible: sliderRow.showInfo }

    PanelSlider {
      bar: root.bar
      width: parent.width
      minimum: 0
      maximum: sliderRow.maximum
      step: sliderRow.step
      integer: sliderRow.step === 1
      tickCount: sliderRow.tickCount
      value: sliderRow.value
      onMoved: function(v) { sliderRow.commit(v) }
      onReleased: function(v) { sliderRow.commit(v) }
    }
  }

  // One EQ band: a bar growing up or down from a zero line, ±eqRange dB.
  // Gen 5's bands have fixed frequencies, printed under the gain.
  component EqBand: Item {
    id: eqBand
    property int band: 0
    property real gain: 0
    property string freq: ""

    implicitHeight: Style.space(96)

    readonly property real trackHeight: height - bandLabel.implicitHeight - Style.space(4) -
      (eqBand.freq.length > 0 ? freqText.implicitHeight : 0)
    readonly property real half: trackHeight / 2

    Rectangle {
      id: bandTrack
      width: parent.width
      height: eqBand.trackHeight
      radius: Style.space(3)
      color: Util.alpha(root.bar.foreground, bandMouse.containsMouse ? 0.12 : 0.06)
    }

    Rectangle {
      x: 0
      width: parent.width
      height: 1
      y: eqBand.half
      color: Util.alpha(root.bar.foreground, 0.3)
    }

    Rectangle {
      width: parent.width - Style.space(8)
      x: Style.space(4)
      radius: Style.space(2)
      color: root.bar.foreground
      height: Math.max(2, Math.abs(eqBand.gain) / root.eqRange * (eqBand.half - Style.space(3)))
      y: eqBand.gain >= 0 ? eqBand.half - height : eqBand.half
      Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }

    Text {
      textFormat: Text.PlainText
      id: bandLabel
      anchors.top: bandTrack.bottom
      anchors.topMargin: Style.space(4)
      anchors.horizontalCenter: parent.horizontalCenter
      text: Model.gainLabel(eqBand.gain) + (eqBand.freq.length > 0 ? "" : " dB")
      color: root.bar.foreground
      opacity: 0.7
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      id: freqText
      visible: eqBand.freq.length > 0
      anchors.top: bandLabel.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      text: eqBand.freq
      color: root.bar.foreground
      opacity: 0.45
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: bandMouse
      anchors.fill: bandTrack
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { root.nudgeBand(eqBand.band, mouse.y < eqBand.half ? 1 : -1) }
      onWheel: function(wheel) { root.nudgeBand(eqBand.band, wheel.angleDelta.y > 0 ? 1 : -1) }
    }
  }

  // A ⓘ that folds an explanation open; the owner keeps the open state.
  component InfoIcon: Text {
    id: icon
    property string info: ""
    property bool open: false
    signal toggled()
    visible: icon.info.length > 0
    textFormat: Text.PlainText
    text: icon.open ? "󰋼" : "󰋽"
    color: root.bar.foreground
    opacity: iconMouse.containsMouse || icon.open ? 1 : 0.5
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall

    MouseArea {
      id: iconMouse
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: icon.toggled()
    }
  }

  component InfoText: Text {
    textFormat: Text.PlainText
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    color: root.bar.foreground
    opacity: 0.65
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A plain row label with its own ⓘ.
  component InfoLabel: Column {
    id: infoLabel
    property string text: ""
    property string info: ""
    property bool showInfo: false
    spacing: Style.space(4)

    Row {
      spacing: Style.space(6)
      Text {
        textFormat: Text.PlainText
        text: infoLabel.text
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      InfoIcon { info: infoLabel.info; open: infoLabel.showInfo; onToggled: infoLabel.showInfo = !infoLabel.showInfo }
    }

    InfoText { text: infoLabel.info; visible: infoLabel.showInfo }
  }

  // A section header with its own ⓘ.
  component InfoHeader: Column {
    id: infoHeader
    property string text: ""
    property string info: ""
    property color foreground: root.bar.foreground
    property string fontFamily: root.bar.fontFamily
    property bool showInfo: false
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Row {
      spacing: Style.space(6)
      PanelSectionHeader { text: infoHeader.text; foreground: infoHeader.foreground; fontFamily: infoHeader.fontFamily }
      InfoIcon {
        info: infoHeader.info
        open: infoHeader.showInfo
        anchors.verticalCenter: parent.verticalCenter
        onToggled: infoHeader.showInfo = !infoHeader.showInfo
      }
    }

    InfoText { text: infoHeader.info; visible: infoHeader.showInfo }
  }
}
