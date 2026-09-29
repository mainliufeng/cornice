import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Idle handling inside the shell: dim the backlight, turn the display off, lock.
//
// Config (seconds, 0 disables a step):
//
//   "idle": {
//     "dimAc": 60,           // dim after this long on AC
//     "dimBattery": 0,       // ...on battery
//     "screenOffAc": 120,
//     "screenOffBattery": 300,
//     "lock": 300
//   }
//
// Unlike hypridle, the monitors respect idle inhibitors, so a video or a
// presentation inhibits dimming without extra configuration. Dimming uses the
// backlight (like the previous idle.sh did) and restores a marker file at
// startup, so a shell crash cannot leave the screen dimmed forever.
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property var settings: (host && host.config && host.config.idle) ? host.config.idle : ({})

  property bool onAc: true
  property bool dimmed: false
  property bool screenOff: false
  property string lastAction: ""

  readonly property string dimMarker: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/cornice-idle-dim"
  readonly property var lockService: host ? host.services["cn.lock"] : null

  readonly property int dimSeconds: onAc
    ? Util.option(settings, "dimAc", 60)
    : Util.option(settings, "dimBattery", 0)
  readonly property int screenOffSeconds: onAc
    ? Util.option(settings, "screenOffAc", 120)
    : Util.option(settings, "screenOffBattery", 300)
  readonly property int lockSeconds: Util.option(settings, "lock", 300)

  // Apps (browsers, Electron) hold idle inhibitors for all sorts of reasons, so
  // honouring them by default means dim/display-off/lock may never fire — which
  // is not what hypridle did. Off by default; turn on per machine if wanted.
  readonly property bool respectInhibitors: Util.option(settings, "respectInhibitors", false)

  // ---- one monitor per step -------------------------------------------------
  IdleMonitor {
    id: dimMonitor
    enabled: root.dimSeconds > 0
    timeout: root.dimSeconds
    respectInhibitors: root.respectInhibitors
    onIsIdleChanged: isIdle ? root.dim() : root.undim()
  }

  IdleMonitor {
    id: screenOffMonitor
    enabled: root.screenOffSeconds > 0
    timeout: root.screenOffSeconds
    respectInhibitors: root.respectInhibitors
    onIsIdleChanged: isIdle ? root.displayOff() : root.displayOn()
  }

  IdleMonitor {
    id: lockMonitor
    enabled: root.lockSeconds > 0
    timeout: root.lockSeconds
    respectInhibitors: root.respectInhibitors
    onIsIdleChanged: if (isIdle) root.lockNow()
  }

  // ---- actions --------------------------------------------------------------
  readonly property Process dimProcess: Process {
    command: ["sh", "-c",
      "command -v light >/dev/null 2>&1 || exit 3; " +
      "cur=$(light -G 2>/dev/null) || exit 4; " +
      "[ -n \"$cur\" ] || exit 4; " +
      "printf '%s\\n' \"$cur\" > " + JSON.stringify(dimMarker) + "; " +
      "light -S 20"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: (code, status) => {
      if (code === 0) {
        root.dimmed = true
        root.lastAction = "dim"
      } else {
        console.warn("cornice: idle dim failed (code " + code + ") — is light(1) installed and the backlight writable?")
      }
    }
  }

  readonly property Process undimProcess: Process {
    command: ["sh", "-c",
      "[ -f " + JSON.stringify(dimMarker) + " ] || exit 0; " +
      "prev=$(cat " + JSON.stringify(dimMarker) + "); " +
      "rm -f " + JSON.stringify(dimMarker) + "; " +
      "command -v light >/dev/null 2>&1 && light -S \"$prev\" 2>/dev/null || true"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: {
      root.dimmed = false
      root.lastAction = "undim"
    }
  }

  readonly property Process dpmsProcess: Process {
    property bool turnOff: false
    command: ["hyprctl", "dispatch", "dpms", turnOff ? "off" : "on"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: {
      root.screenOff = root.dpmsProcess.turnOff
      root.lastAction = turnOff ? "display-off" : "display-on"
    }
  }

  // A crash (or a killed shell) could have left the screen dimmed.
  readonly property Process restoreOnStart: Process {
    command: ["sh", "-c",
      "[ -f " + JSON.stringify(dimMarker) + " ] || exit 0; " +
      "prev=$(cat " + JSON.stringify(dimMarker) + "); " +
      "rm -f " + JSON.stringify(dimMarker) + "; " +
      "command -v light >/dev/null 2>&1 && light -S \"$prev\" 2>/dev/null || true"]
    running: true
    stdout: StdioCollector { waitForEnd: true }
  }

  readonly property Process acProbe: Process {
    command: ["sh", "-c",
      "for s in /sys/class/power_supply/A*/online; do " +
      "[ -r \"$s\" ] || continue; [ \"$(cat $s)\" = 1 ] && { echo ac; exit 0; }; done; " +
      "echo battery"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const state = String(text).trim()
        if (state !== "") root.onAc = state === "ac"
      }
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: acProbe.running = true
  }

  function dim() {
    if (dimmed) return
    dimProcess.running = true
  }

  function undim() {
    if (!dimmed) return
    undimProcess.running = true
  }

  function displayOff() {
    if (screenOff) return
    dpmsProcess.turnOff = true
    dpmsProcess.running = true
  }

  function displayOn() {
    if (!screenOff) return
    dpmsProcess.turnOff = false
    dpmsProcess.running = true
  }

  function lockNow() {
    if (!lockService || typeof lockService.lock !== "function") {
      console.warn("cornice: idle wanted to lock but the lock service is not loaded")
      return
    }
    if (lockService.compositorLocked) {
      // Locking on top of an existing (possibly dead) lock is what crashed the
      // shell once; skip and say so.
      console.warn("cornice: idle skipping lock — the compositor already reports a locked session")
      lastAction = "lock-skipped"
      return
    }
    lastAction = "lock"
    lockService.lock("idle")
  }

  ShellIpc {
    target: "idle"

    function status(): string {
      return JSON.stringify({
        onAc: root.onAc,
        dimmed: root.dimmed,
        screenOff: root.screenOff,
        lastAction: root.lastAction,
        dimSeconds: root.dimSeconds,
        screenOffSeconds: root.screenOffSeconds,
        lockSeconds: root.lockSeconds,
        lockService: root.lockService !== null,
        respectInhibitors: root.respectInhibitors,
        monitorsEnabled: { "dim": dimMonitor.enabled, "screenOff": screenOffMonitor.enabled, "lock": lockMonitor.enabled },
        monitorsIdle: { "dim": dimMonitor.isIdle, "screenOff": screenOffMonitor.isIdle, "lock": lockMonitor.isIdle }
      })
    }

    function dim(): string {
      root.dim()
      return "ok"
    }

    function undim(): string {
      root.undim()
      return "ok"
    }

    function displayOff(): string {
      root.displayOff()
      return "ok"
    }

    function displayOn(): string {
      root.displayOn()
      return "ok"
    }

    function lock(): string {
      root.lockNow()
      return "ok"
    }

    function refresh(): string {
      root.acProbe.running = true
      return "ok"
    }
  }
}
