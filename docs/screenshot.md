# Cornice screenshot module

The user flow stays in Cornice: invoke capture, drag a region, save a PNG and copy the same image, then see a Cornice confirmation. Escape/right-click cancels. Editing is intentionally absent.

## Module boundaries

- `cn.screenshot` owns a single capture transaction per shell/desktop: monitor selection, readiness, cancellation, lock/hotplug interruption and status.
- `SelectionOverlay.qml` owns a frozen Quickshell `ScreencopyView` frame and region input on each eligible output. Its selection decorations are siblings of the captured frame and never enter the exported image.
- The desktop Broker declares screenshot selection/notice as local Cornice surfaces when a secondary desktop is presented; screenshot input stays with the viewer and never becomes application input.
- Core `Cornice.Platform.ScreenshotController` handles physical pixel cropping, PNG encoding, atomic private file writes and Qt image clipboard publication. It is independent of optional `Cornice.Desktop`, brokers and external harnesses.
- `InteractionState` holds hover dismissal and releases other Cornice popup focus grabs for an owned temporary interaction. Callers acquire/release their own key on success, cancel, failure and destruction. Menus have no knowledge of screenshot tools or keyboard shortcuts.

This is an explicit first-party lifecycle, not detection of arbitrary third-party overlays. External capture tools do not participate automatically.

## Usage

The camera button on the right side of the bar starts region capture. Its tooltip explains selection; it is disabled during capture or lock. The bar layout editor can move or hide it like any other widget.

`cornice screenshot` selects a region on one of the physical outputs (or the invoking desktop's private output). `cornice screenshot screen` captures the current monitor. An optional absolute PNG destination overrides the default standard Pictures/Screenshots directory. Every successful capture copies PNG image data. Existing files are replaced atomically only after a successful encode/write. Images are owner-readable/writable only.

The supported session-trial copies route the existing known Print/Super+P region pipeline and Super+Shift+P full-screen pipeline to these commands. Custom screenshot pipelines are preserved. The screen mode is one current monitor; regions are selected within one monitor, rather than spanning outputs. Real user configuration is untouched; replacing a future-login candidate can be undone using the trial rollback path.

## Dependencies and distribution

Runtime: Socat for CLI-to-shell IPC, Quickshell, the compositor's supported screencopy protocol, Qt 6 Core/Gui/Quick/Qml. Socat and Qt base/declarative packages are explicit PKGBUILD dependencies and installed by the package manager. CMake/Ninja are build dependencies only. Packaged installs ship the compiled core QML module; source installs build it. No screenshot/editor/clipboard executable is used by this module. Grim/wl-paste may appear in isolated verification solely as independent observers of rendered pixels and clipboard data.

## Verification

The isolated desktop suite exercises physical input, different shortcuts, matching native crop/clipboard pixels at 2x scale, private default/explicit saving, cancellation, failure and repeated-request refusal. Keyboard panels also preserve their state. It covers a second physical output, output geometry changes and actual session-lock invalidation. The headless and fresh install/package suites verify module discovery and distribution.
