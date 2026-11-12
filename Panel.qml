import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bambu Lab printers on your own network, read and controlled straight from this
// laptop through the bundled `bambu` command (bin/bambu). No cloud, no account.
// One icon for all printers: it shows the one that needs you most. The panel has a
// switcher when there is more than one.
//
// Bar: yellow while printing, green when a print is done and waits on the bed, red when
// it paused, failed or reports an error, dimmed when it can't be reached or isn't set up.
// Hover for progress and time left. A notification when a print finishes, fails or pauses.
// Click: the panel (camera, temperatures, AMS, controls). Right click: a fresh picture.
Panel {
  id: root
  moduleName: "jespermakes.bambu-printer"
  ipcTarget: "jespermakes.bambu-printer"
  manageIpc: true

  readonly property string bin: String(Qt.resolvedUrl("bin/bambu")).replace(/^file:\/\//, "")
  readonly property string snapPath: (Quickshell.env("XDG_RUNTIME_DIR") || (Quickshell.env("HOME") + "/.cache/bambu-printer")) + "/bambu-printer-snap-" + (selId || "x") + ".jpg"
  readonly property int cameraMs: 1000 * Math.max(5, Number(setting("cameraIntervalSec", 15)))

  property var cfg: null          // from `bambu config`: {configured, printers: [{id, name, model, controls}]}
  property var printerStates: ({})       // id -> latest line from `bambu watch --json`
  property var lastPrinterStates: ({})   // id -> state, for notifications
  property string selId: ""       // the printer the panel shows
  property string problem: ""
  property int snapVersion: 0
  property bool snapping: false
  property string snapProblem: ""
  property double snapAt: 0
  property double nowMs: Date.now()
  property string actionNote: ""
  property bool actionError: false
  property bool confirmStop: false

  readonly property bool configured: cfg !== null && cfg.configured === true
  readonly property var printerList: configured ? (cfg.printers || []) : []
  readonly property bool multi: printerList.length > 1
  readonly property var st: printerStates[selId] !== undefined ? printerStates[selId] : null
  readonly property bool reachable: configured && st !== null && st.ok === true
  readonly property string pstate: reachable ? String(st.state || "UNKNOWN") : "OFFLINE"
  readonly property bool printing: pstate === "RUNNING" || pstate === "PREPARE"
  readonly property bool paused: pstate === "PAUSE"
  readonly property bool active: printing || paused
  readonly property bool trouble: reachable && (paused || pstate === "FAILED" || String(st.error || "") !== "")
  readonly property int progress: reachable ? Number(st.progress || 0) : 0
  readonly property bool controls: reachable && st.controls === true
  readonly property string printerName: st && st.name ? String(st.name) : nameOf(selId)

  function nameOf(id) {
    for (var i = 0; i < printerList.length; i++) if (printerList[i].id === id) return String(printerList[i].name)
    return "Printer"
  }

  // The bar shows the printer that needs you most: trouble, then printing, then done.
  function rank(s) {
    if (!s || !s.ok) return 0
    if (s.state === "PAUSE" || s.state === "FAILED" || String(s.error || "") !== "") return 4
    if (s.state === "RUNNING" || s.state === "PREPARE") return 3
    if (s.state === "FINISH") return 2
    return 1
  }
  readonly property var topPrinter: {
    var best = null
    for (var i = 0; i < printerList.length; i++) {
      var s = printerStates[printerList[i].id]
      if (s && (best === null || rank(s) > rank(best))) best = s
    }
    return best
  }
  readonly property string topState: topPrinter && topPrinter.ok ? String(topPrinter.state || "") : "OFFLINE"
  readonly property bool anyReachable: topPrinter !== null && topPrinter.ok === true
  readonly property bool anyTrouble: rank(topPrinter) === 4

  function stateLine(s, name) {
    if (!s) return name + ": connecting…"
    if (!s.ok) return name + ": " + String(s.error || "not reachable")
    if (s.state === "RUNNING" || s.state === "PREPARE")
      return name + " printing " + String(s.job || "") + ", " + Number(s.progress || 0) + "%, " + minutes(s.remaining_min) + " left"
    return name + ": " + String(s.state_word || "").toLowerCase() + (s.job ? ", " + s.job : "")
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The theme's own yellow and green, re-read every 30 s so a theme switch follows.
  property color yellow: "#dbbc7f"
  property color green: "#a7c080"
  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    onLoaded: {
      var t = themeColors.text()
      var y = /^\s*yellow\s*=\s*"(#[0-9a-fA-F]{6,8})"/m.exec(t)
      var g = /^\s*green\s*=\s*"(#[0-9a-fA-F]{6,8})"/m.exec(t)
      if (y) root.yellow = y[1]
      if (g) root.green = g[1]
    }
  }
  Timer { interval: 30000; running: true; repeat: true; onTriggered: themeColors.reload() }

  function minutes(m) {
    var n = Math.max(0, Math.round(Number(m || 0)))
    return n < 60 ? n + " min" : Math.floor(n / 60) + " h " + (n % 60) + " min"
  }

  function temps() {
    if (!reachable) return ""
    var parts = []
    var nz = st.nozzles || []
    for (var i = 0; i < nz.length; i++) {
      var label = nz.length === 1 ? "Nozzle" : (i === 0 ? "Left" : "Right")
      parts.push(label + " " + nz[i].now + "°" + (nz[i].target ? "/" + nz[i].target + "°" : ""))
    }
    if (st.bed) parts.push("Bed " + st.bed.now + "°" + (st.bed.target ? "/" + st.bed.target + "°" : ""))
    if (st.chamber !== null && st.chamber !== undefined) parts.push("Chamber " + st.chamber + "°")
    return parts.join("   ")
  }

  // ---------------------------------------------------------------- talking to bin/bambu

  function checkConfig() { if (!configReader.running) configReader.running = true }

  Process {
    id: configReader
    command: [root.bin, "config"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var c = JSON.parse(String(text || "").trim())
          root.cfg = c
          var ids = (c.printers || []).map(function(p) { return p.id })
          if (ids.indexOf(root.selId) < 0) root.selId = ids.length ? ids[0] : ""
          var kept = {}
          for (var k in root.printerStates) if (ids.indexOf(k) >= 0) kept[k] = root.printerStates[k]
          root.printerStates = kept
          if (c.configured && !watcher.running) watcher.running = true
          root.problem = ""
        } catch (e) {
          root.problem = "bambu command did not answer"
          restartWatch.interval = 10000
          restartWatch.start()  // try again; the 5 s timer only runs while nothing is set up
        }
      }
    }
  }

  // One long-lived connection: `bambu watch --json` prints a line whenever the printer changes.
  Process {
    id: watcher
    command: [root.bin, "watch", "--json"]
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var d = JSON.parse(String(line || "").trim())
          if (!d.id) return
          var next = Object.assign({}, root.printerStates)
          next[d.id] = d
          root.printerStates = next
          if (d.ok) {
            var before = root.lastPrinterStates[d.id] || ""
            var ls = Object.assign({}, root.lastPrinterStates)
            ls[d.id] = String(d.state || "")
            root.lastPrinterStates = ls
            root.announce(before, ls[d.id], d)
          }
        } catch (e) {}
      }
    }
    // Exit 0 means the printer list changed (setup ran): restart at once. Anything else: wait.
    onExited: function(exitCode) { restartWatch.interval = exitCode === 0 ? 500 : 10000; restartWatch.start() }
  }
  Timer { id: restartWatch; interval: 10000; onTriggered: root.checkConfig() }

  // Until a printer is set up, look for the config every 5 s so finishing setup lights the icon.
  Timer {
    interval: 5000
    running: !root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkConfig()
  }

  function snap() {
    if (snapper.running || !reachable) return
    root.snapping = true
    snapper.running = true
  }

  Process {
    id: snapper
    command: [root.bin, "snapshot", "-p", root.selId, root.snapPath]
    stderr: StdioCollector { id: snapErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.snapping = false
      if (exitCode === 0) { root.snapVersion += 1; root.snapAt = Date.now(); root.snapProblem = "" }
      else root.snapProblem = String(snapErr.text || "No camera picture").trim()
    }
  }

  function act(args, note) {
    if (actor.running) return
    root.actionNote = note
    root.actionError = false
    actor.command = [root.bin].concat(args).concat(["-p", root.selId])
    actor.running = true
  }

  Process {
    id: actor
    stdout: StdioCollector { id: actOut; waitForEnd: true }
    stderr: StdioCollector { id: actErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionError = exitCode !== 0
      root.actionNote = exitCode === 0 ? String(actOut.text || "Done.").trim()
                                       : String(actErr.text || "The printer did not take it.").trim().split("\n")[0]
      clearNote.restart()
    }
  }
  Timer { id: clearNote; interval: 8000; onTriggered: root.actionNote = "" }
  Timer { id: stopArm; interval: 4000; onTriggered: root.confirmStop = false }

  function select(id) {
    if (id === selId) return
    selId = id
    snapVersion = 0
    snapProblem = ""
    confirmStop = false
    if (opened && setting("showCamera", true)) snap()
  }

  function setup() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.bin + " setup"])
    root.close()
  }

  function doctor() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.bin + " doctor " + root.selId])
    root.close()
  }

  // One notification per change, never on the first reading.
  function announce(before, now, d) {
    if (before === "" || before === now) return
    var job = String(d.job || "the print")
    var name = String(d.name || "Printer")
    if (now === "FINISH" && (before === "RUNNING" || before === "PAUSE"))
      Quickshell.execDetached(["omarchy-notification-send", "-g", "󰐫", name + ": done", job + " is finished. The bed is yours."])
    else if (now === "FAILED")
      Quickshell.execDetached(["omarchy-notification-send", "-u", "critical", "-g", "󰐫", name + ": failed", job + " stopped."])
    else if (now === "PAUSE")
      Quickshell.execDetached(["omarchy-notification-send", "-u", "critical", "-g", "󰐫", name + ": paused", job + " is paused. It may need you."])
  }

  Timer {
    interval: root.cameraMs
    running: root.opened && root.reachable && root.setting("showCamera", true)
    repeat: true
    onTriggered: root.snap()
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    confirmStop = false
    if (!configured) checkConfig()
    if (setting("showCamera", true) && Date.now() - snapAt > 10000) snap()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---------------------------------------------------------------- the bar icon

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐫"
    active: root.anyTrouble
    foreground: !root.anyReachable || (root.topState === "IDLE" && root.setting("hideWhenIdle", false))
      ? Qt.darker(root.barForeground, 1.55)
      : root.topState === "RUNNING" || root.topState === "PREPARE" ? root.yellow
      : root.topState === "FINISH" ? root.green : root.barForeground
    tooltipText: root.opened ? ""
      : !root.configured ? "3D printer: not set up yet. Click to set it up."
      : root.printerList.map(function(p) { return root.stateLine(root.printerStates[p.id], String(p.name)) }).join("\n")
    onPressed: function(buttonCode) {
      if (!root.configured && buttonCode === Qt.LeftButton) { root.toggle(); return }
      if (buttonCode === Qt.RightButton) { root.snap(); root.open() }
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- the panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key >= "1" && key <= "9" && Number(key) <= root.printerList.length) root.select(root.printerList[Number(key) - 1].id)
        else if (key === "c") root.snap()
        else if (key === "s" && !root.configured) root.setup()
        else if (key === "p" && root.controls && root.active) root.act([root.paused ? "resume" : "pause"], root.paused ? "Resuming…" : "Pausing…")
        else if (key === "l" && root.controls) root.act(["light", root.st.light === "on" ? "off" : "on"], "Light…")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          x: Style.space(2)
          width: panelFlick.width - Style.space(4)
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: root.configured ? root.printerName : "3D printer"
            detail: !root.configured ? "Not set up" : root.reachable ? String(root.st.state_word || "") : root.st ? "Offline" : "…"
            meta: !root.configured ? "Bambu Lab, on your own network"
              : root.reachable ? ([String(root.st.model || "") === root.printerName ? "" : String(root.st.model || ""),
                                   String(root.st.job || "")].filter(function(x) { return x !== "" }).join("  ·  ") || "no job")
              : root.st ? String(root.st.error || "not reachable") : (root.problem || "connecting…")
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰐫"
                color: root.trouble ? root.urgent : (root.reachable ? root.foreground : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---- Switcher, when there is more than one printer ----
          Flow {
            visible: root.multi
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.printerList
              delegate: Button {
                required property var modelData
                required property int index
                readonly property var s: root.printerStates[modelData.id]
                text: String(modelData.name) + (s && s.ok && (s.state === "RUNNING" || s.state === "PAUSE") ? "  " + s.progress + "%" : "")
                iconText: "󰐫"
                selected: modelData.id === root.selId
                bordered: true
                foreground: root.rank(s) === 4 ? root.urgent : root.rank(s) === 3 ? root.yellow
                  : root.rank(s) === 2 ? root.green : (s && s.ok ? root.foreground : root.dim)
                fontFamily: root.fontFamily
                tooltipText: root.stateLine(s, String(modelData.name)) + "   (key " + (index + 1) + ")"
                onClicked: root.select(modelData.id)
              }
            }
          }

          // ---- Not set up: walk the user into the wizard ----
          Column {
            visible: !root.configured
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Setup finds your printer on the network, asks for the access code from the printer screen, and checks the camera and controls. About a minute."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              text: "Set up printer"
              iconText: "󰐫"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setup()
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Or in a terminal: " + root.bin.replace(Quickshell.env("HOME"), "~") + " setup"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Set up, but not answering ----
          Column {
            visible: root.configured && !root.reachable && root.st !== null
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Can't reach the printer. Is it on, and is this laptop on the same network?"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(8)
              Button { text: "Check connection"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.doctor() }
              Button { text: "Set up again"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.setup() }
            }
          }

          // ---- Progress ----
          Column {
            visible: root.reachable && root.active
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Math.max(Style.space(5), Math.round(Style.spacing.controlHeight * 0.18))
              Rectangle { id: trackBar; anchors.fill: parent; radius: height / 2; color: root.track }
              Rectangle {
                anchors.left: trackBar.left
                height: trackBar.height
                radius: trackBar.radius
                width: trackBar.width * Math.max(0, Math.min(1, root.progress / 100))
                color: root.trouble ? root.urgent : root.foreground
                Behavior on width { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.reachable
                ? root.progress + "%   ·   layer " + (root.st.layer || 0) + " of " + (root.st.layers || 0)
                  + "   ·   " + root.minutes(root.st.remaining_min) + " left"
                : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            visible: root.reachable
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.temps() + (root.reachable && String(root.st.error || "") !== "" ? "\nError " + root.st.error : "")
            color: root.reachable && String(root.st.error || "") !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- AMS spools ----
          Repeater {
            model: root.reachable ? (root.st.ams || []) : []
            delegate: Row {
              required property var modelData
              spacing: Style.space(10)
              Repeater {
                model: modelData.slots
                delegate: Row {
                  required property var modelData
                  spacing: Style.space(4)
                  Rectangle {
                    width: Style.space(12); height: width; radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: modelData.empty ? "transparent" : modelData.color
                    border.color: Util.alpha(root.foreground, 0.4)
                    border.width: 1
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.empty ? "empty" : String(modelData.type) + (modelData.remain !== null && modelData.remain !== undefined ? " " + modelData.remain + "%" : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---- Camera ----
          Item {
            width: parent.width
            height: Math.round(width * 9 / 16)
            visible: root.reachable && root.setting("showCamera", true)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)
            }

            Image {
              id: cam
              anchors.fill: parent
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              source: root.snapVersion > 0 ? "file://" + root.snapPath + "?v=" + root.snapVersion : ""
            }

            Text {
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              visible: cam.status !== Image.Ready
              textFormat: Text.PlainText
              text: root.snapping ? "Getting a picture from the chamber…" : (root.snapProblem || "No camera picture yet")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(4)
              visible: cam.status === Image.Ready
              textFormat: Text.PlainText
              text: root.snapping ? "updating…" : Math.max(0, Math.round((root.nowMs - root.snapAt) / 1000)) + " s ago"
              color: "white"
              style: Text.Outline
              styleColor: "black"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (cam.status === Image.Ready) {
                Quickshell.execDetached(["imv", root.snapPath])
                root.close()
              }
            }
          }

          // ---- Controls ----
          Flow {
            visible: root.controls
            width: parent.width
            spacing: Style.space(8)

            Button {
              visible: root.active
              text: root.paused ? "Resume" : "Pause"
              iconText: root.paused ? "󰐊" : "󰏤"
              bordered: true
              enabled: !actor.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.act([root.paused ? "resume" : "pause"], root.paused ? "Resuming…" : "Pausing…")
            }

            Button {
              visible: root.active
              text: root.confirmStop ? "Really stop?" : "Stop"
              iconText: "󰓛"
              bordered: true
              enabled: !actor.running
              foreground: root.confirmStop ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                if (!root.confirmStop) { root.confirmStop = true; stopArm.restart(); return }
                root.confirmStop = false
                root.act(["stop", "--yes"], "Stopping…")
              }
            }

            Button {
              text: root.reachable && root.st.light === "on" ? "Light off" : "Light on"
              iconText: "󰌵"
              bordered: true
              enabled: !actor.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.act(["light", root.st.light === "on" ? "off" : "on"], "Light…")
            }

            Button {
              visible: root.printing
              text: "Speed: " + String(root.reachable ? root.st.speed || "?" : "?")
              iconText: "󰓅"
              bordered: true
              enabled: !actor.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: "Click for the next speed: silent, standard, sport, ludicrous"
              onClicked: {
                var order = ["silent", "standard", "sport", "ludicrous"]
                var i = order.indexOf(String(root.st.speed || "standard"))
                root.act(["speed", order[(i + 1) % order.length]], "Speed…")
              }
            }
          }

          Text {
            visible: root.actionNote !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.actionNote
            color: root.actionError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            visible: root.reachable && root.st.controls === false
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Pause, stop, light and speed need Developer Mode on the printer (Settings > Network > LAN Only Mode, then Developer Mode). It turns off the Bambu Handy app and cloud printing."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Button { text: "I turned it on, check again"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.doctor() }
          }

          PanelSeparator { visible: root.configured; foreground: root.foreground }

          Button {
            visible: root.configured
            text: "Add a printer"
            iconText: "󰐕"
            bordered: true
            foreground: root.dim
            fontFamily: root.fontFamily
            onClicked: root.setup()
          }

          Text {
            visible: root.configured
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: (root.multi ? "1-" + root.printerList.length + ": switch printer  ·  " : "") + "C: new picture" + (root.controls ? "  ·  P: pause/resume  ·  L: light" : "") + "  ·  click the picture to open it big"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
