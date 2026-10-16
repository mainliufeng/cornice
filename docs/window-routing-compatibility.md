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
- Ordinary human SNI tray actions, after revalidating a captured primary control
  context or physical takeover of a secondary desktop. Takeover also requires
  the Broker's current human control mode, seat identity and generation to match
  the compositor-validated context. Exact unique D-Bus owners and selected menu entries remain pinned.
  The Shell does not supply a separate process-global activation token.

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

The optional KDE `ProvideXdgActivationToken(s)` setter and the subsequent
`Activate(ii)` or DBusMenu `Event(isvu)` are separate calls. A producer can
acknowledge an action before consuming the token. Another Shell or a later
action can then overwrite the producer's current token. Private regressions
demonstrated both cases while both callers reported success. Per-Shell locks,
delays and a successful method reply do not prove request-to-surface binding.

All Agent SNI and DBusMenu actions are therefore refused before sending either
a setter or an action, including services exposing that optional setter. No
request-bound tray protocol has been implemented. Merely advertising XDG
Activation, or putting a token in an unrecognized menu data variant, cannot
enable this path. This is an explicit compatibility limit, not an application
launch repair. Toolkits may still support XDG tokens on other launch paths.

For a human source, the existing ordinary-action compatibility remains after
the compositor revalidates the captured context as current primary control, or
the matching secondary context plus the Broker prove current human takeover.
No global token is injected, and a caller's `desktop=main` label alone is
insufficient. Exact owner/menu identities remain pinned. Missing, expired,
relabeled and read-only sources fail; ordinary action errors are returned
without retry or fallback. The previously verified tokenless human Fcitx path
does not require a setter, and private regressions retain that compatibility.

An ordinary human action does not supply precise source-to-window binding or
guarantee placement on the clicked workspace. Existing token-aware applications
may also decline focus without a new token. Success here acknowledges ordinary
dispatch, not a window appearing. Agent actions never use human compatibility.

The Shell shows preparation and tray refusals for 15 seconds on the captured
source desktop and output, including direct tray clicks without a completion
callback. Launcher failures use the same passive notice after the Launcher
closes. It takes no keyboard focus or pointer input and is hidden while locked;
changing the viewed desktop does not retarget an earlier result. The persistent
desktop operation result remains available for launch errors. This feedback does
not add a missing activation-token contract or prove a successful launch created
a window.

Per-desktop service processes and private D-Bus sessions can provide a default
route without modifying their toolkit, at the cost of service lifecycle,
activation and configuration orchestration. A shared producer can instead
support an explicit action token or parent. Guessing the next root for a PID is
ambiguous under concurrent or delayed actions and is not a general replacement.
These alternatives have not been automatically selected for existing apps;
in particular no additional proxy backend or application profile is started.

These tests do not establish universal multi-seat support for shared toolkit
instances, arbitrary Electron/single-instance applications, Xwayland,
ScreenCast/Screenshot portals, clipboard/drag/IME or arbitrary D-Bus activation.
They do not provide protection from malicious processes running under the same
UID or a filesystem-security boundary. Screenshot target semantics and the
separate screenshot/lock issue are outside this change.

## Reproducible checks

`test/tray-request-correlation-verify.py` runs the native router regressions and
exact-owner menu helper on fresh private buses, without a compositor or apps.
Build `cornice-desktop-action-verify` and `cornice-tray-interleaving-verify` from
`native/platform` first. The tests
require both concurrent Agent requests to fail without any setter/action/menu
delivery, and retain source-validated ordinary human dispatch and error handling.
They also check that a takeover flag alone, a paused/Agent-controlled desktop,
or a changed seat/generation cannot enable ordinary dispatch.

`chatgpt-tray-takeover-verify.py`, through `isolated-desktop-test.sh`, launches
the installed ChatGPT with an empty private profile and no network. It clicks
Quit with physical input during secondary-desktop takeover and checks that
both the tray registration and the actual application process disappear.

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
