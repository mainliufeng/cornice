# Secondary desktop launch and local overlay verification (2026-10-10)

All verification runs use real applications in the isolated nested compositor.
The physical login session is not restarted by these tests.

## Root causes and responsibility

- Hyprland secondary focus reactivated an already active Chrome toplevel when
  clicking its profile popup. The redundant activation dismissed the popup
  before the sign-in button received its click. Match the primary focus path.
- Physical takeover switches pointer ownership between the secondary workspace
  and primary shell overlays. The presentation renderer kept painting the
  secondary pointer while the primary overlay pointer was also visible. Paint
  only the current takeover pointer, including when crossing the bar.
- Launcher-side browser profile flags duplicated Broker launch policy. Launch
  argv through the Broker for secondary nonterminal applications. Physical
  launch requires the current takeover seat ID and generation; an agent cannot
  use it to bypass pause or human control. Chromium is started once with the
  Broker's managed pipe and reused by later authorized CDP connections.
- ChatGPT/Electron's singleton lock forwarded a secondary launch to the primary
  process. Supply a desktop-specific user-data-dir in addition to the app's
  CODEX_ELECTRON_USER_DATA_PATH environment setting.
- Hyprvoice used an unimplemented registration method. Register the local
  application's overlay through register-local-overlay instead. The Broker
  obtains the PID from SO_PEERCRED and restricts routing to that application's
  namespaces. The registration lasts for the socket's lifetime. Hyprland sees
  only its generic overlay configuration, with no Hyprvoice-specific policy.

## Regression coverage

- launcher-seat-regression.py: eight consecutive physical Super+R presses each
  open the launcher and focus input; moving the pointer onto the bar removes
  the old workspace cursor; actual Chrome sign-in opens Google's login URL;
  CDP reaches that same browser; actual ChatGPT opens a different process on
  the secondary workspace while the primary application stays alive.
- agent-launcher-verify.py: existing secondary launcher Enter behavior remains
  functional and does not disturb the primary browser/workspace.
- voice-overlay-verify.py: actual Hyprvoice startup-error UI is visible in both
  readonly observation and takeover; quitting removes it. Models are absent
  in this fixture, so microphone recording and ASR are not verified here.
- voice-seat-verify.py: twelve production destination/paste checks cover primary,
  two secondary seats, readonly rejection, stale focus/workspace rejection,
  launcher keyboard layers and restoration to primary. Recognized transcript
  is fixture input; actual recording/recognition remains a physical check.
- seat-focus-lifecycle-verify.py: native focus, close and xdg activation preserve
  fullscreen policies and other seats.
- desktop-switcher-verify.py: native observation/takeover, readonly workspace
  navigation, application shortcuts, screenshot button/selection, permission
  revocation, lock and crash recovery.

The intermittent report of needing two Super+R presses did not reproduce in
these eight consecutive attempts. This is a regression result, not proof of
having identified every possible shortcut timing condition.

## Local activation

A compositor change takes effect in a new login session. Prepare and arm a
candidate release for next login with the tested Cornice, Hyprland and
Hyprvoice binaries. Keep the running session's immutable release and record
backup and activation state; do not label a pending candidate as already live.
