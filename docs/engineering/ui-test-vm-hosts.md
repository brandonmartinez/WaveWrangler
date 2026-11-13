# UI-test VM hosts

Functional hosted/UI, accessibility and ordinary regression work runs in macOS
VMs. An unavailable VM is a readiness blocker, **not permission to fall back
to the user's desktop or Mac mini**.

Physical execution requires a requirement virtualization cannot meaningfully
verify, such as physical audio-device behavior, unavailable GPU functionality
or representative hardware performance. Explain that limitation and obtain
approval for the specific host/run. VM timings do not qualify physical hardware.

## Provisioned capacity

Macatron hosts Tart/Virtualization.framework guests `ww-ui-1` and `ww-ui-2`,
each provisioned for macOS 27, four vCPUs, 16 GiB RAM and 120 GB disk with a
virtual display. Combined CPU allocation is at most eight vCPUs. Do not add a
third macOS VM or let competing heavy host builds exhaust this budget.
Verify actual configuration/toolchain before labeling evidence; provisioning
records are not live status or ownership.

The guests use local Xcode, SSH aliases with dedicated VM-only keys, auto-login,
the `~/ww-uitest-runs/gui-lock` helper and a display-awake LaunchAgent.
Never read/copy stored guest passwords. Changing login/security/SSH setup
requires explicit operational authority, not a test retry.
Consult current [Tart licensing](https://tart.run/licensing/) and Apple's
applicable macOS terms before changing virtualization capacity or distribution.

## Per-feature lifecycle

Use the complete lifecycle: **inspect, start, verify, test, collect, clean up,
stop, verify stopped**. Starting Tart is not proof of guest readiness,
and submitting a test command is not proof that tests executed.

1. **Inspect ownership and cleanliness before starting work.** On the Tart host,
   check `tart list`, `tart get ww-ui-N` and the specific guest's runner process.
   For a running guest, check SSH, `~/ww-uitest-runs/gui-lock status`, queued
   invocations and active Xcode/test/app processes before restarting or stopping
   anything. Coordinate with an existing owner; neither a running VM nor an
   empty lease alone establishes ownership. An unreachable running guest has
   unknown ownership, not permission to force a restart.
2. **Start only the guests needed for the feature.** Obtain operational
   authorization and use the independent service launches below. Record which
   guests this invocation started or explicitly took over; a borrowed guest
   must be handed back rather than stopped without agreement.
3. **Verify actual running state and readiness.** Recheck `tart list`, the
   runner process, `tart ip`, pinned SSH identity and every readiness gate below.
   Inspect free space with `df -h` and staged-run usage with
   `du -sh ~/ww-uitest-runs`. Allow room for incoming Products, test scratch and
   result bundles, not merely the transfer size. Check for abandoned
   `Products.incoming` directories, incomplete results, generated fixtures and
   leftover test applications. Investigate unexpected residue before testing.
4. **Use a fresh, verified run.** Build from the current source, stage into a
   unique directory and run a small functional smoke with those Products before
   broader selection. Record its result; an older smoke does not qualify a new
   build. Acquire a fresh lease for each invocation, with bounded workers and
   explicit selectors. Follow [build/stage/run/collect](gui-testing.md).
5. **Collect evidence before cleanup.** Retrieve results, logs, attachments and
   the source/dirty-patch identity. Confirm the local copies are readable and
   sufficient to investigate failures. Record executed identities and counts,
   environment-invalid attempts and remaining blockers.
6. **Clean only owned feature artifacts.** Once no invocation holds the lease
   and this run's test processes have exited, remove only explicitly identified
   staging, results and generated-fixture paths owned by this feature whose
   needed evidence is preserved. Clean incomplete transfers too. Never blanket
   delete `~/ww-uitest-runs`, another feature's results, shared helpers, installed
   tooling, permission state or lease/queue files. Reclaim stale ownership only
   through `gui-lock`. Unknown leftovers require owner confirmation; being old
   does not authorize deletion. Recheck free space and leftover processes.
7. **Stop and verify.** After evidence collection and cleanup, recheck leases,
   queued work and ownership, then `tart stop ww-ui-N` only for each specifically
   owned guest. Verify `tart list` reports `stopped` and its runner has exited.
   Do not leave detached guests running after feature work unless an explicit
   handoff or ongoing task requires it. Record any intentionally retained
   artifacts or guest handoff.

A clean guest need not be a freshly provisioned guest or have no historical
results. It must have known ownership, no conflicting workload or unexplained
test state, enough free space and a fresh verified run directory. Disk pressure
or unexplained residue is a readiness blocker, not authority to delete history,
reset the VM, change security settings or fall back to physical-host tests.

## Readiness gate

Before dispatch and after a reboot/restart, verify:

1. Guest process and current owner are known; its SSH alias reaches that guest.
2. Xcode license is accepted and `xcodebuild -checkFirstLaunchStatus` exits zero.
3. Console user is logged in and unlocked; display-awake assertion is active.
4. The guest has a successful functional smoke result with identified Products.
5. `~/ww-uitest-runs/gui-lock status` works and no other invocation owns the
   lease. Obtain a fresh lease for this invocation.

`pmset -g assertions` should report `PreventUserIdleDisplaySleep 1`. Disabling
sleep in preferences alone does not ensure the virtual display is awake.
Auto-login alone does not ensure the console is unlocked.
Use this nonmutating guest probe (substitute the second alias if needed):

```sh
ssh ww-ui-1 /usr/bin/swift - <<'SWIFT'
import CoreGraphics
import Darwin
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
      session["kCGSSessionOnConsoleKey"] as? Bool == true,
      session["kCGSessionLoginDoneKey"] as? Bool == true,
      session["CGSSessionScreenIsLocked"] == nil else {
    fputs("VM console locked or unavailable\n", stderr)
    exit(1)
}
print("Guest console unlocked")
SWIFT
```

`gui-lock run` also refuses a locked guest before ticket/lease acquisition.
Do not interpret an app remaining Running Background on a locked guest as a
product focus failure. Fix readiness or report the blocker.

Direct public AX diagnostics additionally require guest Accessibility trust for
the runner. Working XCTest does not imply `AXIsProcessTrusted()`. Request an
operator-approved grant through guest System Settings; never edit TCC, disable
system protections or change host permissions. Recheck after ad-hoc rebuilding
changes identity. This diagnostic grant is not required for ordinary XCTest.
VoiceOver/Full Keyboard Access settings are separate from audit plan admission.

## Process lifetime and recovery

Do not assume an earlier agent/session still owns or runs either guest.
Coordinate any restart/stop with the current owner. When startup is authorized,
run each service separately:

```sh
tart run --no-graphics --no-clipboard --no-audio ww-ui-1
tart run --no-graphics --no-clipboard --no-audio ww-ui-2
```

These are **two independent service launches**, not a combined attached shell.
In an agent tool, use one separately approved `mode: "async", detach: true`
invocation per guest so session archival cannot terminate the VM.
Do not use `nohup`, `&`, `disown` or a disposable session-owned process as a
substitute. If independent lifetime cannot be approved, report the limitation.

Verify Tart running status, SSH, console and lease helper after startup and
after the launch session ends. If a guest IP changes, inspect `tart ip`,
verify the pinned host identity and explicitly correct the known alias before
copy/run operations. A one-off SSH HostName override does not update later
rsync/SSH calls. Preserve dedicated keys and host checking.
Stop only the specifically owned guest with `tart stop ww-ui-N` when authorized.

Follow [build/stage/run/collect](gui-testing.md): checksum/signature-verified
Products, unique run directory, probe, exact plan metadata and one lease per
`test-without-building`. Never unlink the persistent guard; use the helper for
stale/dead recorded ownership.

Lost guest lifetime, lock, bad transfer or stale runner makes a run
environment-invalid, not a pass or product assertion failure. Restore readiness
before a bounded retry. Synthetic fixtures are the default; no user media,
transcripts, models or external speech may be copied/mounted without separate
authorization. Label every result with actual VM configuration, SHA/dirty patch,
selection/counts and result path rather than citing old smoke logs as readiness.
