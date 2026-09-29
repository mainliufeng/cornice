import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import qs.Commons

// Lock screen.
//
// The session lock is a Wayland protocol: while it is held, the compositor
// keeps every surface hidden and routes input to us. Two rules follow, and both
// are enforced below:
//
//   1. Never lock without a working way back in. If the PAM service is missing
//      or unreadable, lock() refuses instead of locking the user out.
//   2. A lock that is engaged must survive our own death as gracefully as
//      possible: on startup we adopt a session the compositor still reports as
//      locked (the shell crashed while locked), and `cornice restart` refuses
//      to run while the lock is secure.
//
// Authentication reuses the existing PAM service (default "hyprlock"), so the
// Howdy face-unlock stack and the login stack keep working unchanged.
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property var lockConfig: host && host.config ? Util.option(host.config, "lock", ({})) : ({})
  readonly property string pamService: Util.option(lockConfig, "pamService", "hyprlock")
  readonly property string pamDirectory: Util.option(lockConfig, "pamDirectory", "")
  readonly property bool allowEmergency: Util.option(lockConfig, "emergencyUnlock", true)

  // Which screen shows the password box; the rest only show the background and
  // the clock. Empty means "the first screen that has a field".
  readonly property string primaryScreen: Util.option(lockConfig, "primaryScreen", "")

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string user: Quickshell.env("USER") || ""
  readonly property string shotPath: runtimeDir + "/cornice-lock.png"

  // Background of the lock surface. "wallpaper" reuses whatever the background
  // plugin is showing (a still image, so it costs one decode instead of a grim
  // round trip), "screenshot" blurs the desktop as it was, "none" leaves the
  // theme colour. The screenshot stays the fallback whenever there is no
  // wallpaper to show.
  readonly property string backgroundMode: Util.option(lockConfig, "background", "wallpaper")
  readonly property real blurAmount: Util.option(lockConfig, "blur", 1.0)
  readonly property real scrimAmount: Util.option(lockConfig, "scrim", 1.0)

  readonly property var backgroundService: host ? host.services["cn.background"] : null

  readonly property string wallpaperPath: {
    const service = backgroundService
    if (!service) return ""
    if (backgroundMode !== "wallpaper") return ""
    // Another wallpaper tool (mpvpaper, hyprpaper) may own the screen: the
    // background service is inactive then and knows nothing worth showing.
    if (service.active !== true) return ""
    if (typeof service.pathFor !== "function" || typeof service.workspaceFor !== "function") return ""
    const path = String(service.pathFor(service.workspaceFor("")) || "")
    return path
  }

  readonly property bool wantedScreenshot: backgroundMode === "screenshot"
    || (backgroundMode === "wallpaper" && wallpaperPath === "")

  readonly property string backgroundSource: {
    if (wallpaperPath !== "") return "file://" + wallpaperPath
    if (wantedScreenshot && shotRevision > 0) return "file://" + shotPath + "?v=" + shotRevision
    return ""
  }

  property bool locked: false
  property bool secure: false
  property bool pamAvailable: false
  property bool compositorLocked: false
  property bool pamChecked: false
  // idle (unlocked) | locked (waiting for the password) | authenticating (a PAM
  // attempt is in flight) | failed | unlocking
  property string state: "idle"
  // Set when a PAM attempt outlives the watchdog (fingerprint readers and Howdy
  // can block for a long time). Input is accepted again so the prompt can never
  // become unusable, which is how the user got locked out before.
  property bool attemptStale: false
  readonly property bool acceptingInput: (state !== "authenticating" && state !== "unlocking") || attemptStale
  property string message: ""
  property string password: ""
  property string pendingPassword: ""
  property int shotRevision: 0
  property string journal: ""

  // ---- safety probes -------------------------------------------------------

  // Can we authenticate at all? Checked before anything may lock.
  readonly property Process pamProbe: Process {
    command: ["sh", "-c",
      "d=\"${CORNICE_PAM_DIR:-/etc/pam.d}\"; " +
      "if [ -r \"$d/" + root.pamService + "\" ]; then echo yes; else echo no; fi"]
    environment: ({ "CORNICE_PAM_DIR": root.pamDirectory === "" ? "/etc/pam.d" : root.pamDirectory })
    running: true
    stdout: SplitParser {
      onRead: line => {
        root.pamAvailable = String(line).trim() === "yes"
        root.pamChecked = true
        if (!root.pamAvailable)
          console.warn("cornice: PAM service '" + root.pamService + "' is not readable — refusing to lock")
      }
    }
  }

  // Adopt a session the compositor still holds locked (previous shell died).
  readonly property Process lockStateProbe: Process {
    command: ["sh", "-c", "command -v hyprctl >/dev/null 2>&1 && hyprctl locked 2>/dev/null | head -1 || echo false"]
    running: true
    stdout: SplitParser {
      onRead: line => {
        root.compositorLocked = String(line).trim() === "true"
        if (root.compositorLocked)
          // Two different situations look the same from here:
          //  * our own lock request is pending/queued — emergency-unlock releases it;
          //  * a previous lock client died and Hyprland is showing its
          //    crashed-lockscreen failsafe — on a hyprlang config the only way out
          //    is restarting the compositor (hl.clear_crashed_lockscreen is Lua-only).
          console.warn("cornice: the compositor reports a locked session that this shell does not own "
            + "(a previous lock client died). Try: cornice lock emergency-unlock — "
            + "if the screen still shows Hyprland's \"lockscreen app died\" message, "
            + "that failsafe can only be cleared by restarting the compositor: hyprctl dispatch exit")
      }
    }
  }

  // ---- the lock itself -----------------------------------------------------

  WlSessionLock {
    id: sessionLock
    locked: root.locked

    onSecureChanged: {
      root.secure = secure
      // Do NOT flip to "authenticating" here. Nothing is being authenticated yet,
      // and that state disables the password field — which locked the user out
      // with a "authenticating…" prompt that could never accept input.
      if (secure && root.state === "idle") root.state = "locked"
    }

    surface: Component {
      WlSessionLockSurface {
        id: lockSurface

        // width/height are read-only: Quickshell sizes a lock surface to its
        // screen. Everything below therefore anchors to plain Items.
        color: Color.background

        Component.onCompleted: console.log("CORNICE-LOCK surface "
          + (lockSurface.screen ? lockSurface.screen.name : "?") + " "
          + lockSurface.width + "x" + lockSurface.height)

        // Everything else is plain Items, so anchoring stays well-defined.
        Item {
          id: layer

          anchors.fill: parent

        // The lock background: the current wallpaper, or a blurred screenshot of
        // the desktop as it was when the lock engaged (hyprlock's
        // `path = screenshot` + blur_passes behaviour), or nothing at all.
        Image {
          id: shot
          anchors.fill: parent
          source: root.backgroundSource
          fillMode: Image.PreserveAspectCrop
          visible: false
          asynchronous: true
        }

        MultiEffect {
          anchors.fill: parent
          visible: root.backgroundSource !== "" && root.blurAmount > 0
          source: shot
          blurEnabled: true
          blur: root.blurAmount
          blurMax: 48
        }

        // Blur disabled: show the image unfiltered instead of a hole.
        Image {
          anchors.fill: parent
          visible: root.backgroundSource !== "" && root.blurAmount <= 0
          source: root.backgroundSource
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }

        // A gradient scrim instead of a flat wash: the desktop stays readable
        // behind the lock, but the type keeps its contrast.
        Rectangle {
          anchors.fill: parent
          visible: root.backgroundSource !== ""
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.62 * root.scrimAmount) }
            GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.30 * root.scrimAmount) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.66 * root.scrimAmount) }
          }
        }

        Rectangle {
          anchors.fill: parent
          visible: root.shotRevision === 0
          color: Color.background
        }

        SystemClock {
          id: surfaceClock
          precision: SystemClock.Seconds
        }

        // A soft card behind the content: a busy wallpaper should not decide
        // whether the password prompt is readable.
        Rectangle {
          anchors.horizontalCenter: content.horizontalCenter
          anchors.verticalCenter: content.verticalCenter
          width: content.width + Style.space(7)
          height: content.height + Style.space(6)
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.72)
          border.width: 1
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
        }

        Column {
          id: content

          anchors.centerIn: parent
          anchors.verticalCenterOffset: -Math.round(parent.height * 0.05)
          spacing: Style.space(1.05)

          // ---- clock ---------------------------------------------------------
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(0.7)

            Text {
              text: Qt.formatDateTime(surfaceClock.date, "HH:mm")
              color: Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Math.round(Style.fontSize * 5.2)
              font.bold: true
              font.letterSpacing: -1
            }

            Text {
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Math.round(Style.fontSize * 0.9)
              text: Qt.formatDateTime(surfaceClock.date, "ss")
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.55)
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 1.5
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(surfaceClock.date, "dddd, d MMMM").toUpperCase()
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.65)
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize * 0.95
            font.letterSpacing: 2
          }

          Item { width: 1; height: Style.space(2.6) }

          // ---- who is unlocking ----------------------------------------------
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(0.5)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf023"
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.55)
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Quickshell.env("USER") || ""
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.75)
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 0.95
              font.letterSpacing: 1
            }
          }

          Item { width: 1; height: Style.space(0.4) }

          // ---- password field ------------------------------------------------
          Item {
            id: field

            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(Style.space(26))
            height: Math.round(Style.space(4.6))

            Rectangle {
              anchors.fill: parent
              radius: Style.radius
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b,
                             input.activeFocus ? 0.10 : 0.06)

              Behavior on color {
                ColorAnimation { duration: 120 }
              }
            }

            // The underline carries the state: accent = ready, muted = busy,
            // urgent = failed.
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: 2
              color: root.state === "failed" ? Color.urgent
                   : (root.state === "authenticating" || pam.active) ? Color.muted
                   : Color.accent
            }

            Text {
              id: lead

              anchors.left: parent.left
              anchors.leftMargin: Style.space(1.2)
              anchors.verticalCenter: parent.verticalCenter
              text: root.state === "failed" ? "\uf00d" : "\uf023"
              color: root.state === "failed" ? Color.urgent : Color.muted
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize * 1.1
            }

            TextInput {
              id: input

              anchors.left: lead.right
              anchors.leftMargin: Style.space(0.9)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(1.2)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              verticalAlignment: TextInput.AlignVCenter
              horizontalAlignment: TextInput.AlignLeft
              echoMode: TextInput.Password
              passwordCharacter: "\u25cf"
              color: Color.foreground
              selectionColor: Color.accent
              selectedTextColor: Color.background
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 1.3
              focus: true
              clip: true
              // Enabled unless an attempt is really in flight: tying this to the
              // state alone is what made the prompt untypable.
              enabled: root.acceptingInput

              Component.onCompleted: forceActiveFocus()

              onTextChanged: {
                root.password = text
                if (root.state === "failed") {
                  root.state = "locked"
                  root.message = ""
                }
              }

              Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.authenticate()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  input.text = ""
                  root.password = ""
                  event.accepted = true
                }
              }
            }

            Text {
              anchors.left: lead.right
              anchors.leftMargin: Style.space(0.9)
              anchors.verticalCenter: parent.verticalCenter
              visible: input.text === ""
              text: (root.state === "authenticating" || pam.active) ? "authenticating…" : "Password"
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 1.15
            }
          }

          // Fixed height so a failure message does not move the field.
          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(Style.space(26))
            height: Style.space(2.2)

            Text {
              anchors.centerIn: parent
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.message
              color: root.state === "failed" ? Color.urgent : Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 0.95
              elide: Text.ElideRight
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Enter to unlock   ·   Esc to clear"
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.40)
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize * 0.8
            font.letterSpacing: 1
          }
        }

        }
      }
    }
  }

  Timer {
    id: attemptWatchdog
    interval: 25000
    repeat: false
    onTriggered: {
      if (root.state !== "authenticating") return
      root.attemptStale = true
      root.message = "PAM is still waiting (fingerprint or slow module?) — press Enter to retry"
      root.journal = root.journal + "|auth:stale"
      console.warn("cornice: PAM attempt exceeded 25s; re-enabling input")
    }
  }

  onStateChanged: {
    if (state === "authenticating") {
      attemptStale = false
      attemptWatchdog.restart()
    } else {
      attemptWatchdog.stop()
    }
  }

  PamContext {
    id: pam

    config: root.pamService
    // An empty configDirectory makes Quickshell refuse to start the context
    // ("specified config directory '' is not a directory"), so the system
    // default is passed explicitly.
    configDirectory: root.pamDirectory !== "" ? root.pamDirectory : "/etc/pam.d"
    user: root.user

    // PAM asks for the response once the conversation reaches the password
    // prompt (a stack may ask more than once, so every request is answered).
    onResponseRequiredChanged: {
      if (responseRequired) root.answerPrompt()
    }

    onCompleted: result => {
      console.log("CORNICE-LOCK completed result=" + result + " message=" + message + " messageIsError=" + messageIsError)
      if (result === PamResult.Success) root.authenticationSucceeded()
      else root.authenticationFailed(result === PamResult.MaxTries
        ? "Too many attempts"
        : (root.message !== "" ? root.message : "Authentication failed"))
    }

    onError: pamError => {
      console.log("CORNICE-LOCK error " + pamError)
      root.authenticationFailed(String(pamError))
    }
  }

  // ---- api -----------------------------------------------------------------

  function captureScreenshot() {
    if (!shotCapture.running) shotCapture.running = true
  }

  readonly property Process shotCapture: Process {
    command: ["sh", "-c",
      "command -v grim >/dev/null 2>&1 && grim \"" + root.shotPath + "\" 2>/dev/null || true"]
    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) root.shotRevision = root.shotRevision + 1
    }
  }

  // A session lock that outlives its client leaves Hyprland showing its
  // "lockscreen app died" failsafe, and only a compositor restart clears that.
  // Releasing on destruction means a graceful exit (cornice stop/restart,
  // SIGTERM) never strands the session. A SIGKILL still can — nothing can run
  // then — which is why `cornice stop` refuses while locked.
  Component.onDestruction: {
    if (!locked) return
    try {
      locked = false
    } catch (error) {
      console.warn("cornice: could not release the lock while shutting down: " + error)
    }
  }

  function lock(reason) {
    if (locked) return "already-locked"

    // The compositor may already hold a lock we do not own: a previous lock
    // client died, or Hyprland is showing its crashed-lockscreen failsafe.
    // Asking for a second lock in that state makes Quickshell send a request the
    // compositor rejects with a fatal protocol error, which killed the whole
    // shell (and left the session locked). Refuse instead.
    if (compositorLocked) {
      console.warn("cornice: refusing to lock — the compositor already reports a locked session")
      message = "The compositor already has a lock this shell does not own"
      return "compositor-locked"
    }
    if (!pamChecked) return "unavailable"        // still probing; caller may retry
    if (!pamAvailable) {
      message = "Refusing to lock: PAM service '" + pamService + "' is not available"
      console.warn("cornice: " + message)
      return "no-pam"
    }

    password = ""
    state = "locked"
    message = ""
    // Only screenshot when the wallpaper is not the background: grim costs a
    // frame capture and a PNG write on every lock.
    if (wantedScreenshot) captureScreenshot()
    locked = true
    journal = journal + "|lock:" + (reason === undefined ? "manual" : reason)
    return "ok"
  }

  function authenticate() {
    if (!locked) return "not-locked"
    if (pam.active) return "busy"
    if (password === "") return "empty"

    state = "authenticating"
    attemptStale = false
    message = ""
    pendingPassword = password
    const started = pam.start()
    console.log("CORNICE-LOCK start service=" + pamService + " dir=" + pamDirectory
      + " returned=" + started + " active=" + pam.active + " responseRequired=" + pam.responseRequired)
    // Some stacks are already waiting for the response as start() returns.
    if (pam.responseRequired) answerPrompt()
    return "ok"
  }

  // Answer the current prompt with the pending password; anything after the
  // first prompt (e.g. a second factor) gets an empty answer instead of
  // replaying the password.
  function answerPrompt() {
    console.log("CORNICE-LOCK answerPrompt pending=" + (pendingPassword === "" ? "empty" : "set") + " visible=" + pam.responseVisible)
    if (pendingPassword === "") {
      pam.respond("")
      return
    }
    const value = pendingPassword
    pendingPassword = ""
    pam.respond(value)
  }

  function authenticationSucceeded() {
    pendingPassword = ""
    state = "unlocking"
    message = ""
    password = ""
    journal = journal + "|unlock:ok"
    locked = false
    secure = false
    state = "idle"
  }

  function authenticationFailed(reason) {
    pendingPassword = ""
    state = "failed"
    message = reason
    password = ""
    journal = journal + "|unlock:failed"
  }

  // Emergency release for a stuck session (TTY/SSH recovery). Not exposed to
  // anything but the CLI, and it is logged.
  function emergencyUnlock() {
    if (!allowEmergency) return "disabled"
    console.warn("cornice: EMERGENCY unlock requested — the session is being released without authentication")
    pendingPassword = ""
    password = ""
    message = ""
    state = "idle"
    secure = false
    locked = false
    journal = journal + "|emergency-unlock"
    return "ok"
  }

  ShellIpc {
    target: "lock"

    function lock(): string {
      return root.lock("ipc")
    }

    function status(): string {
      return JSON.stringify({
        background: root.backgroundMode,
        backgroundSource: root.backgroundSource,
        wallpaper: root.wallpaperPath,
        locked: root.locked,
        secure: root.secure,
        state: root.state,
        pamService: root.pamService,
        pamAvailable: root.pamAvailable,
        compositorLocked: root.compositorLocked,
        message: root.message,
        journal: root.journal
      })
    }

    // Attempts an unlock with the given password (used by `cornice lock try`).
    function attempt(value: string): string {
      root.password = value
      return root.authenticate()
    }

    function emergencyUnlock(): string {
      return root.emergencyUnlock()
    }

    function cancel(): string {
      root.password = ""
      root.state = root.locked ? "locked" : "idle"
      root.message = ""
      return "ok"
    }
  }
}
