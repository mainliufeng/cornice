# Desktop action routing: supported paths and limits

Cornice's Shell snapshots the clicked desktop, workspace, seat generation and
output before dispatching a launch or tray/menu action. Its Hyprland fork accepts
that action context and resolves windows using an explicit parent, then an
explicit action, then their connection's desktop. A seat is an input-device
group; an output or workspace alone is not a complete isolation boundary.

## Supported paths

- Ordinary GTK and Qt processes launched through the actual Shell Launcher on
  the human desktop or either of two private Agent desktops.
- Cold processes and descendants registered before execution, with an explicit
  action token. A retired generation, missing source or expired action fails
  without launching the target in the human desktop.
- Managed Chrome has a separate profile and process per Agent desktop. Repeated
  Launcher invocations forward to that desktop's existing Chrome singleton.
  Invocation tokens are transient and do not change persistent browser policy.
- Same-connection xdg-shell parents and cross-connection xdg-foreign parents,
  including the real public FileChooser portal and an unmodified shared GTK
  backend. A real Chrome test verifies that each chooser returns a synthetic
  file to the correct page, takes input from its source seat, and preserves the
  human focus.
- Token-aware SNI tray services: resolve the exact unique D-Bus owner, send
  `ProvideXdgActivationToken`, then dispatch to that owner. Serialize the token
  setter and action for services sharing a process. Menu selections retain the
  exact selected entry and destination instead of looking up a logical ID again.

## First display and late parents

The compositor routes a window before its first `openwindow` publication. The
real GTK portal backend sends an initial empty surface commit before importing
the foreign parent; an empty commit is not a mapped pixel frame. The integration
test checks that `set_parent_of` precedes the chooser's first non-null buffer and
that its first publication already names the requested workspace.

A shared connection which has a valid foreign import keeps an unattributed new
root pending until a parent or explicit action supplies its route. It does not
use a fixed delay as evidence that no parent will arrive. This conservative rule
can also keep an unrelated root on that connection pending.

An otherwise ordinary root whose producer first announces *any* parent/import
only after its first map is not universally distinguishable from a legitimate
unparented root. The negative control demonstrates an initial publication on
the original desktop before a late move. Zero incorrect first frames is **not**
promised for that path. A service dedicated to one desktop supplies a reliable
default before map; a shared service otherwise needs an explicit attribution
contract or must leave unattributed windows pending.

## Compatibility limits

Tokenless shared tray services are currently refused before their action is
sent. This includes the tested installed Fcitx tray `Activate` path, which
returns `org.freedesktop.DBus.Error.UnknownMethod` for the activation-token
method. This also restricts an action which happens not to create a window.
Cornice cannot infer that property from the base SNI interface. This is a real
behavioral limit, not full tray compatibility.

Per-desktop service processes and private D-Bus sessions can provide a default
route without modifying their toolkit, at the cost of service lifecycle,
activation and configuration orchestration. A shared producer can instead
support an explicit action token or parent. Guessing the next root for a PID is
ambiguous under concurrent or delayed actions and is not a general replacement.

These tests do not establish universal multi-seat support for shared toolkit
instances, arbitrary Electron/single-instance applications, Xwayland,
ScreenCast/Screenshot portals, clipboard/drag/IME or arbitrary D-Bus activation.
They do not provide protection from malicious processes running under the same
UID or a filesystem-security boundary. Screenshot target semantics and the
separate screenshot/lock issue are outside this change.

## Reproducible checks

Use the matching Cornice and Hyprland development builds. Tests create their own
HOME, runtime, profiles, session buses, PID/network namespaces, input clients and
synthetic files. They do not use the logged-in user's Chrome or desktop sockets.

- `test/isolated-desktop-test.sh desktop-routing-shell-verify.py`: actual GTK/Qt
  Launcher and input checks for human/A/B.
- `test/isolated-desktop-test.sh chrome-portal-routing-verify.py`: real Chrome
  singleton, complete portal return, parent/buffer timing, first publication,
  browser recovery and installed Fcitx capability checks. Set
  `CORNICE_TEST_TASKS_MAX=1024` for two Chrome processes and shared SVG loaders;
  CPU and memory remain bounded by the wrapper.
- Hyprland's `hyprtester/multiseat/sandbox.sh routing`: explicit parent/action,
  lifecycle and timing cases, including the expected unsupported late-parent
  negative control.

Set `CORNICE_TEST_HYPRLAND_SOURCE`, `CORNICE_TEST_HYPRLAND` and, where required,
`CORNICE_TEST_RENDER_NODE` to the private test build and a DRM render node. A
render node grants rendering, not physical display/input ownership.
