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
  // Set by `cornice ipc idle inhibit <seconds>` (or indefinitely with 0): a long
  // download, a presentation, or the test suite should not be interrupted by the
  // lock screen. Simpler and more reliable than an IdleInhibitor surface.
  property bool inhibited: false
  property bool logindWatching: false
  property string lastSignal: ""
  property string signalBuffer: ""
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

  // logind wiring. hypridle used to provide both of these (before_sleep_cmd and
  // its own logind Lock handler); with hypridle gone, nothing locks the session
  // on suspend or on `loginctl lock-session` unless we do it here.
  readonly property bool lockOnSleep: Util.option(settings, "lockOnSleep", true)
  readonly property bool lockOnLockSignal: Util.option(settings, "lockOnLockSignal", true)
  // Closing the lid should lock even when logind is *not* going to suspend: with
  // the default HandleLidSwitch and a plugged-in laptop there is no
  // PrepareForSleep at all, only a LidClosed property change — which is exactly
  // what "no reaction when I close the lid" was.
  readonly property bool lockOnLidClose: Util.option(settings, "lockOnLidClose", true)
  // Docked (an external screen is attached): the session keeps being used with
  // the lid shut, so locking would be wrong.
  readonly property bool docked: Quickshell.screens.length > 1

  // ---- one monitor per step -------------------------------------------------
  IdleMonitor {
    id: dimMonitor
    enabled: root.dimSeconds > 0 && !root.inhibited
    timeout: root.dimSeconds
    respectInhibitors: root.respectInhibitors
    onIsIdleChanged: isIdle ? root.dim() : root.undim()
  }

  IdleMonitor {
    id: screenOffMonitor
    enabled: root.screenOffSeconds > 0 && !root.inhibited
    timeout: root.screenOffSeconds
    respectInhibitors: root.respectInhibitors
    onIsIdleChanged: isIdle ? root.displayOff() : root.displayOn()
  }

  IdleMonitor {
    id: lockMonitor
    enabled: root.lockSeconds > 0 && !root.inhibited
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

  Timer {
    id: inhibitTimer
    repeat: false
    onTriggered: root.inhibited = false
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

  // ---- logind ---------------------------------------------------------------
  // `gdbus monitor` streams every signal from logind; the interesting ones are
  //   Manager.PrepareForSleep (true,)   → suspending now
  //   Manager.PrepareForSleep (false,)  → resumed
  //   Session.Lock ()                   → loginctl lock-session, lid scripts, ...
  // Chunks split lines, so keep the tail in signalBuffer instead of assuming one
  // line per chunk.
  function consumeSignals(chunk) {
    if (!chunk) return
    const combined = signalBuffer + chunk
    const lines = combined.split("\n")
    signalBuffer = lines.pop()
    for (const line of lines) handleSignalLine(line)
  }

  function handleSignalLine(line) {
    if (line === "" || line.indexOf("org.freedesktop.login1.") < 0) return
    lastSignal = line.trim()
    // logind reports the lid as a property change, not as a signal of its own.
    if (line.indexOf("LidClosed") >= 0) {
      const closed = line.indexOf("<true>") >= 0
      if (closed) {
        lastAction = docked ? "lid-docked" : "lid"
        if (lockOnLidClose && !docked) lockNow("lid")
      } else {
        displayOn()
        undim()
        lastAction = "lid-open"
      }
      return
    }
    if (line.indexOf("PrepareForSleep") >= 0) {
      if (line.indexOf("true") >= 0) {
        lastAction = "sleep"
        if (lockOnSleep) lockNow("sleep")
      } else {
        // Their old hypridle config ran `idle.sh display-on` after sleep: the
        // panel is often still off when the session comes back.
        displayOn()
        undim()
        lastAction = "resume"
      }
      return
    }
    if (line.indexOf(".Lock") >= 0 && lockOnLockSignal) lockNow("logind")
  }

  // Feed a line straight into the parser: the tests use it instead of actually
  // suspending the machine.
  function feedSignal(line) {
    handleSignalLine(line)
    return lastAction
  }

  function lockNow(reason) {
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
    const why = reason === undefined ? "idle" : String(reason)
    lastAction = "lock:" + why
    lockService.lock(why)
  }

  readonly property Process logindMonitor: Process {
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1"]

    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: root.consumeSignals(text)
    }

    onStarted: root.logindWatching = true
    onExited: (code, status) => {
      root.logindWatching = false
      if (code !== 0) console.warn("cornice idle: logind monitor exited with " + code + " (is gdbus installed?)")
    }
  }

  // The monitor is the only thing that learns about suspend and loginctl; if it
  // dies (a bus restart, a missing gdbus) bring it back.
  Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: if (!logindMonitor.running) logindMonitor.running = true
  }

  Component.onCompleted: logindMonitor.running = true

  ShellIpc {
    target: "idle"

    function status(): string {
      return JSON.stringify({
        onAc: root.onAc,
        inhibited: root.inhibited,
        dimmed: root.dimmed,
        screenOff: root.screenOff,
        lastAction: root.lastAction,
        dimSeconds: root.dimSeconds,
        screenOffSeconds: root.screenOffSeconds,
        lockSeconds: root.lockSeconds,
        lockService: root.lockService !== null,
        logindWatching: root.logindWatching,
        lastSignal: root.lastSignal,
        lockOnSleep: root.lockOnSleep,
        lockOnLockSignal: root.lockOnLockSignal,
        lockOnLidClose: root.lockOnLidClose,
        docked: root.docked,
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

    function inhibit(seconds: string): string {
      const value = Number(seconds || 0)
      root.inhibited = true
      if (value > 0) {
        inhibitTimer.interval = Math.max(1, value) * 1000
        inhibitTimer.restart()
      } else {
        inhibitTimer.stop()
      }
      return "inhibited" + (value > 0 ? " for " + value + "s" : " until released")
    }

    function release(): string {
      root.inhibited = false
      inhibitTimer.stop()
      return "released"
    }

    // Test hook: pretend logind sent this line (the real ones need a suspend).
    function feed(line: string): string {
      return root.feedSignal(String(line))
    }

    function refresh(): string {
      root.acProbe.running = true
      return "ok"
    }
  }
}
