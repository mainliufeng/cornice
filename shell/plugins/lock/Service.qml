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
  // Showing the account name on the lock screen is the familiar default, but it
  // is also the one thing on it that is personal — `false` keeps it off for good
  // (screenshots, streams, shared machines).
  readonly property bool showUser: Util.option(lockConfig, "showUser", true)

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

  // Human scope uses the private protocol; full scope retains ext-session-lock.
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  property string scope: "none"
  property bool compositorHumanLockAvailable: false
  property bool nativeProviderAvailable: false
  readonly property bool humanLockAvailable: compositorHumanLockAvailable && nativeProviderAvailable
  property bool nativeOwned: false
  property bool providerUnlockReceived: false
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
    locked: root.locked && root.scope === "session" && !root.nativeOwned

    onSecureChanged: {
      if (root.scope !== "session") return
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
          visible: root.backgroundSource === ""
          color: Color.background
        }

        LockContent {
          anchors.fill: parent
          appearance: root.lockAppearance()
          user: root.user
          showUser: root.showUser
          busy: root.state === "authenticating" || pam.active
          failed: root.state === "failed"
          acceptingInput: root.acceptingInput
          message: root.message
          onEdited: text => {
            root.password = text
            if (root.state === "failed") { root.state = "locked"; root.message = "" }
          }
          onSubmitted: value => { root.password = value; root.authenticate() }
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

  readonly property Process capabilityProbe: Process {
    command: ["hyprctl", "-j", "seat", "capabilities"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try { const features = JSON.parse(text).features; root.compositorHumanLockAvailable = ["human-lock-v1", "agent-private-output", "lock-aware-seat-input", "lock-aware-agent-export", "session-guard-v1"].every(name => features.indexOf(name) >= 0) } catch (e) {}
      }
    }
  }

  readonly property Process nativeProviderProbe: Process {
    command: [root.prefix + "/bin/cornice-human-lock", "--help"]
    running: true
    onExited: (code, status) => root.nativeProviderAvailable = code === 0
  }

  readonly property Process protectionProbe: Process {
    command: ["hyprctl", "-j", "seat", "lock-state"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const actual = JSON.parse(text)
          root.compositorLocked = actual.locked === true
          if (root.nativeOwned && root.scope === actual.scope) root.secure = actual.secure === true
          if (actual.locked && !actual.ownerConnected && root.pamChecked && root.pamAvailable && root.humanLockAvailable) {
            root.nativeOwned = true; root.scope = actual.scope; root.locked = true
            const provider = actual.scope === "human" ? root.humanProvider : root.fullProvider
            if (!provider.running) root.startHumanProvider()
          }
        } catch (e) {}
      }
    }
  }
  Timer { interval: 250; running: root.humanLockAvailable; repeat: true; triggeredOnStart: true; onTriggered: if (!protectionProbe.running) protectionProbe.running = true }

  readonly property Process humanProvider: Process {
    stdinEnabled: true
    stdout: SplitParser { onRead: line => root.nativeEvent(line, "human") }
    onExited: root.nativeExited("human")
  }

  readonly property Process fullProvider: Process {
    stdinEnabled: true
    stdout: SplitParser { onRead: line => root.nativeEvent(line, "session") }
    onExited: root.nativeExited("session")
  }

  function nativeEvent(line, providerScope) {
    try {
      const event = JSON.parse(line)
      if (root.scope !== providerScope) return
      if (event.event === "secure") { root.secure = true; root.state = "locked"; root.message = "" }
      if (event.event === "authenticating") root.state = "authenticating"
      if (event.event === "authentication-failed") { root.state = "failed"; root.message = "验证失败，请重试" }
      if (event.event === "unlocked") {
        root.providerUnlockReceived = true; root.locked = false; root.secure = false; root.compositorLocked = false
        root.scope = "none"; root.state = "idle"; root.journal += "|unlock:ok"
      }
    } catch (e) { console.warn("cornice: invalid lock provider event") }
  }

  function nativeExited(providerScope) {
    if (scope === providerScope && locked && !providerUnlockReceived) {
      secure = false; state = "failed"; message = "锁屏进程已退出，桌面保持锁定"
    }
  }

  function lockAppearance() {
    return {
      background: String(Color.background), foreground: String(Color.foreground),
      accent: String(Color.accent), urgent: String(Color.urgent), muted: String(Color.muted),
      fontFamily: Style.fontFamily, iconFamily: Style.iconFamily,
      fontSize: Style.fontSize, gap: Style.gap, radius: Style.radius,
      language: I18n.language, backgroundSource: backgroundSource,
      blur: blurAmount, scrim: scrimAmount,
      labels: { authRequired: I18n.t("lock.authRequired"), password: I18n.t("lock.password"),
        checking: I18n.t("lock.checking"), rejected: I18n.t("lock.rejected"),
        tooMany: I18n.t("lock.tooMany"), hint: I18n.t("lock.hint"), dateFormat: I18n.t("lock.dateFormat") }
    }
  }

  // A screenshot may finish after the secure surface has already been mapped.
  // Update its appearance without delaying protection or recreating the lock.
  onShotRevisionChanged: {
    if (nativeOwned && locked) {
      const provider = scope === "human" ? humanProvider : fullProvider
      if (provider.running) provider.write("appearance " + JSON.stringify(lockAppearance()) + "\n")
    }
  }

  function startHumanProvider() {
    let args = [prefix + "/bin/cornice-human-lock", "--pam-service", pamService,
      "--pam-directory", pamDirectory === "" ? "/etc/pam.d" : pamDirectory, "--scope", scope,
      "--appearance", JSON.stringify(lockAppearance())]
    if (allowEmergency) args.push("--allow-emergency")
    if (!showUser) args.push("--hide-user")
    providerUnlockReceived = false
    const provider = scope === "human" ? humanProvider : fullProvider
    provider.command = args; provider.running = true
  }

  // Both providers fail closed when their owner exits. The CLI already refuses
  // ordinary stop/restart while locked; forced termination must not unlock.
  function lock(reason) {
    const full = reason === "sleep" || reason === "full" || Util.option(lockConfig, "scope", "human") === "session"
    if (locked) {
      if (full && scope === "human") {
        // The compositor replaces the human owner atomically; never unlock first.
        secure = false; scope = "session"; state = "locked"; journal += "|upgrade:session"
        if (humanLockAvailable) startHumanProvider()
        return "ok"
      }
      return "already-locked"
    }

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
    nativeOwned = humanLockAvailable
    scope = !full && nativeOwned ? "human" : "session"
    locked = true
    if (nativeOwned) startHumanProvider()
    journal = journal + "|lock:" + (reason === undefined ? "manual" : reason)
    return "ok"
  }

  function authenticate() {
    if (!locked) return "not-locked"
    if (nativeOwned) return "use-lockscreen"
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
    scope = "none"
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
    if (nativeOwned) {
      const provider = scope === "human" ? humanProvider : fullProvider
      if (!provider.running) return "provider-unavailable"
      provider.write("emergency-unlock\n")
      return "requested"
    }
    pendingPassword = ""
    password = ""
    message = ""
    state = "idle"
    secure = false
    locked = false
    scope = "none"
    journal = journal + "|emergency-unlock"
    return "ok"
  }

  ShellIpc {
    target: "lock"

    function lock(): string {
      return root.lock("ipc")
    }

    function full(): string { return root.lock("full") }

    function recover(): string {
      if (!root.pamAvailable || !root.humanLockAvailable || (root.scope !== "human" && root.scope !== "session")) return "unavailable"
      const provider = root.scope === "human" ? root.humanProvider : root.fullProvider
      if (provider.running) return "already-running"
      root.startHumanProvider(); return "ok"
    }

    function status(): string {
      return JSON.stringify({
        showUser: root.showUser,
        background: root.backgroundMode,
        backgroundSource: root.backgroundSource,
        wallpaper: root.wallpaperPath,
        scope: root.scope,
        humanLockAvailable: root.humanLockAvailable,
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
