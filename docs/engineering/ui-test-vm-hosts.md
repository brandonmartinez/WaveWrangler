# Headless XCUITest VM hosts

WaveWrangler has two provisioned functional GUI-test VM hosts on Macatron:
`ww-ui-1` and `ww-ui-2`. They run macOS 27 under Tart
(Virtualization.framework), each with a 1920x1200-point virtual display,
four vCPUs, 16 GiB RAM and a 120 GB virtual disk. The combined CPU
allocation is at most eight vCPUs. They run without host-side windows and
do not take over the user's desktop.

The guests are based on Cirrus Labs'
`ghcr.io/cirruslabs/macos-golden-gate-vanilla` image at
`sha256:b78a521145ebef24e9916c0b3999e165bb12b587d11524c5fa3ba4fe7bf79bb9`
(macOS 27.0). Each has a local copy of the development Mac's exact Xcode
27.0 build 27A266a, SSH with a dedicated VM-only key, auto-login, sleep
and lock disabled, and the same `~/ww-uitest-runs/gui-lock` lease helper
used on the mini. The image's auto-login is already configured for its guest
admin account (`sysadminctl -autologin status` confirms it, and
`/etc/kcpassword` exists); its stored password is never read or copied.
Guest loginwindow has `DisableScreenLockImmediate` enabled. Each guest's
login session runs a persistent `caffeinate -di`
LaunchAgent (`com.wavewrangler.keep-guest-display-awake`): `pmset -g assertions`
must show `PreventUserIdleDisplaySleep 1` before dispatching XCUITests.
The guest's virtual display can otherwise sleep despite `displaysleep 0`,
preventing XCTest from bringing the app to the foreground.
The console must also be unlocked: an auto-logged-in guest can retain a
screen lock across restarts and leave the test app in `Running Background`.
Tart's [personal-workstation license](https://tart.run/licensing/)
is royalty-free; Apple's [macOS license](https://www.apple.com/legal/sla/docs/macOSGoldenGate.pdf)
limits this Mac to two additional macOS virtualized instances.

After a host reboot, start each guest in its **own** detached,
session-independent background process. The VM service must not be owned by
an app/agent session that can be archived later; otherwise archiving that
session can stop the host. Start the two guests separately:

```sh
# Detached host service A
tart run --no-graphics --no-clipboard --no-audio ww-ui-1
# Detached host service B
tart run --no-graphics --no-clipboard --no-audio ww-ui-2
```

Use `tart list` and `tart ip ww-ui-1` (or `ww-ui-2`) for status and address.
The local SSH aliases are `ww-ui-1` and `ww-ui-2`. If an address changes,
probe it with `ssh -o HostName="$(tart ip ww-ui-1)" ww-ui-1`, then update
that alias's `HostName` in `~/.ssh/config` **before** copying Products or
running the pipeline; the one-off override does not change later SSH or
rsync commands. Keep its key and pinned host identity unchanged. Check
`ssh ww-ui-1 '~/ww-uitest-runs/gui-lock status'` before each run, and stop
with `tart stop ww-ui-1` (similarly for `ww-ui-2`). Do not add a third
macOS VM on this host.

Check the guest's console lock before dispatching a test (substitute `ww-ui-2`
as needed). The command succeeds only when a console user has finished logging
in and the screen is unlocked; a locked or unavailable console fails closed:

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

**Readiness gate:** do not dispatch tests to a VM until its Xcode license is
accepted, `ssh ww-ui-N 'xcodebuild -checkFirstLaunchStatus'` exits 0, the
console is unlocked, and the guest's first functional smoke-test `.xcresult`
shows Passed. A configured VM without these checks is not an available GUI
host; use the mini instead.

Follow the [GUI lease pipeline](../../.squad/skills/gui-lock-mac-mini/SKILL.md):
build-for-testing on the development Mac from a clean, committed and pushed
SHA (`-jobs 4`, isolated DerivedData); copy signed Products atomically to
a per-run guest directory; verify `rsync -c` and both code signatures.
On the guest, use one `gui-lock run` lease for one
`xcodebuild test-without-building` invocation, then retrieve its
`.xcresult`. The helper also rejects a locked VM before acquiring a ticket
or lease, reporting `VM console locked`; it does not change the physical
mini's preflight. Only synthetic fixtures are allowed inside the VMs: never
mount or copy the user's recordings or test media. Label the result
`VM ww-ui-N (Virtualization.framework, macOS 27, 4 vCPU)` with the SHA.

**VM timings are not valid for performance gates.** Run
`ResponsivenessUITests` and other performance measurements on the Mac mini,
which remains the default physical GUI host. Keep the guests within their
eight-vCPU combined budget and avoid competing heavy builds on the host.

## Initial functional smoke (2026-10-08)

Both guests ran `LibraryProviderConflictUITests` under their own `gui-lock`
leases with signed Products built from pushed `origin/main` SHA
`5ae7fa4a0430ab0780f5dc93dff0af34f79ec000`. Each `.xcresult`
reports **2 passed, 0 failed, 0 skipped**:

| Evidence label | Guest result bundle |
| --- | --- |
| VM ww-ui-1 (Virtualization.framework, macOS 27, 4 vCPU) | `~/ww-uitest-runs/smoke-5ae7fa4-20261008/result.xcresult` |
| VM ww-ui-2 (Virtualization.framework, macOS 27, 4 vCPU) | `~/ww-uitest-runs/smoke-5ae7fa4-20261008-final/result.xcresult` |

No TCC or damaged-app prompts were observed. `ww-ui-2` required a one-time
manual unlock of a persisted guest-console lock before its successful run;
it stayed unlocked through two subsequent cold headless restarts. Both
guests retained auto-login, `DisableScreenLockImmediate`, their display-awake
assertion, and an unlocked console after **two cold restarts each**. A fresh
leased `testNoNoticeWithoutConflicts` app-launch smoke passed **1/1** after
each boot:

| Evidence label | Cold boot 1 result | Cold boot 2 result |
| --- | --- | --- |
| VM ww-ui-1 (Virtualization.framework, macOS 27, 4 vCPU) | `~/ww-uitest-runs/smoke-5ae7fa4-20261008-cold1/result.xcresult` | `~/ww-uitest-runs/smoke-5ae7fa4-20261008-cold2/result.xcresult` |
| VM ww-ui-2 (Virtualization.framework, macOS 27, 4 vCPU) | `~/ww-uitest-runs/smoke-5ae7fa4-20261008-cold1/result.xcresult` | `~/ww-uitest-runs/smoke-5ae7fa4-20261008-cold2/result.xcresult` |

Recheck the console and display-awake assertion after future restarts. A
locked or unavailable VirtualMac console is rejected by `gui-lock run`
before starting the test or acquiring a lease.
