# Focused source audit: direct locked tasks

This is a source audit by the implementing agent, not a claim of a separate
reviewer or formal security proof. It covers the paired feature commits
`c310022` / `4d6ef13c` and the subsequent Qt namespace-only compatibility fix.

## Checked paths

* No new user authorization step or default-off switch: allocation uses existing
  `agentAllowed` and task ownership. `locked-task-start-v1` is an internal
  compositor capability; `taskIdle` is a cause/state marker, not a permission.
* Primary requests route to the existing primary handler. Broker rejects a
  primary preferred target while locked; ordinary locked bind/resume, physical
  input and management/primary capture remain blocked. Fresh initialization
  rejects a workspace on another output.
* Compositor `allowsNewTask` requires a locked human scope, connected owner,
  actual secure coverage and exact epoch. Full/orphan lock and human-to-full
  upgrade never use the new exception. Standard ext-session-lock excludes no
  private output.
* Creation registers privacy before output announcement. Role recognition
  checks actual managed headless backend and output object identity, not names.
  The expected epoch is carried through output/seat/init/allocation. Generation
  one initialization cannot revive a paused existing seat.
* New leases rotate generation and export grant before connecting fresh input
  devices. Finish rotates authority before device withdrawal, avoiding a device
  disconnect being misclassified as interruption. Manual pause, takeover, lost
  connection and recovery remain separate from successful completion.
* Lock-created leases validate their original output and epoch on input/capture;
  moving the workspace to another output revokes control. Old frames, bindings,
  browser proxies and restoration fail after revocation. Already submitted
  browser/application actions are not claimed retractable.
* Existing pre-lock continue semantics are distinct from the new lease path.
  Clipboard primary-lock isolation and managed browser profile/proxy checks are
  retained; malformed/unknown protection fails closed. Same-UID applications
  retain filesystem/process/network access and are not an OS sandbox.
* Retired output persistence stores only desktop definitions, never live control
  credentials. A stale desktop is skipped for allocation instead of preventing
  unrelated private task creation. Broker restart keeps recovered seats paused.

## Findings and resolution

The real tests exposed and resolved normal-completion/device-disconnect ordering
and stale-output persistence issues before the feature commits were delivered.
The full lock suite then exposed the baseline Qt 6.12 `Color` name collision;
unchanged baseline reproduction and exact namespace-only reverse comparison
verified the companion fix. No remaining blocking issue was found in these
source paths. Actual private compositor, GTK, Chrome, PAM/logind and paired
login/rollback tests support this conclusion; physical acceptance remains open.

The review does not assert protection against malicious same-UID management IPC,
OS-level process isolation, or untested physical display/sleep hardware behavior.
