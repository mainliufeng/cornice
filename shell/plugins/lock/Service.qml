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
          console.warn("cornice: the compositor reports a locked session that this shell does not own "
            + "(a previous lock client died). Unlock from a TTY with: cornice lock emergency-unlock")
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

        // Screenshot of the desktop as it was when the lock engaged, blurred the
        // way hyprlock's `path = screenshot` + blur_passes did.
        Image {
          id: shot
          anchors.fill: parent
          source: root.shotRevision > 0 ? "file://" + root.shotPath + "?v=" + root.shotRevision : ""
          fillMode: Image.PreserveAspectCrop
          visible: false
          asynchronous: true
        }

        MultiEffect {
          anchors.fill: parent
          visible: root.shotRevision > 0
          source: shot
          blurEnabled: true
          blur: 1.0
          blurMax: 48
        }

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, root.shotRevision > 0 ? 0.45 : 1)
        }

        SystemClock {
          id: surfaceClock
          precision: SystemClock.Seconds
        }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          y: Math.round(parent.height * 0.30)
          spacing: Style.space(0.6)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(surfaceClock.date, "HH:mm:ss")
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize * 5
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(surfaceClock.date, "yyyy.MM.dd")
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize * 1.4
          }

          Item { width: 1; height: Style.space(3) }

          // Password box: the visible part is ours, the input is invisible but
          // focused, so the dots stay centred like hyprlock's.
          Rectangle {
            id: field

            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(Style.space(24))
            height: Math.round(Style.space(4.6))
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
            border.width: 2
            border.color: root.state === "failed" ? Color.urgent : Color.surfaceBorder
            radius: Style.radius

            TextInput {
              id: input

              anchors.fill: parent
              anchors.leftMargin: Style.space(1.2)
              anchors.rightMargin: Style.space(1.2)
              horizontalAlignment: TextInput.AlignHCenter
              verticalAlignment: TextInput.AlignVCenter
              echoMode: TextInput.Password
              passwordCharacter: "●"
              color: Color.foreground
              selectionColor: Color.accent
              selectedTextColor: Color.background
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 1.3
              focus: true
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
              anchors.centerIn: parent
              visible: input.text === ""
              text: (root.state === "authenticating" || pam.active) ? "authenticating…" : "Password"
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 1.2
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.message !== ""
            text: root.message
            color: root.state === "failed" ? Color.urgent : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
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

  function lock(reason) {
    if (locked) return "already-locked"
    if (!pamChecked) return "unavailable"        // still probing; caller may retry
    if (!pamAvailable) {
      message = "Refusing to lock: PAM service '" + pamService + "' is not available"
      console.warn("cornice: " + message)
      return "no-pam"
    }

    password = ""
    state = "locked"
    message = ""
    captureScreenshot()
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
