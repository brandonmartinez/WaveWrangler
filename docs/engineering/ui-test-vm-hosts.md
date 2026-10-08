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
used on the mini. Each guest's login session runs a persistent `caffeinate -di`
LaunchAgent (`com.wavewrangler.keep-guest-display-awake`): `pmset -g assertions`
must show `PreventUserIdleDisplaySleep 1` before dispatching XCUITests.
The guest's virtual display can otherwise sleep despite `displaysleep 0`,
preventing XCTest from bringing the app to the foreground.
The console must also be unlocked: an auto-logged-in guest can retain a
screen lock across restarts and leave the test app in `Running Background`.
Tart's [personal-workstation license](https://tart.run/licensing/)
is royalty-free; Apple's [macOS license](https://www.apple.com/legal/sla/docs/macOSGoldenGate.pdf)
limits this Mac to two additional macOS virtualized instances.

After a host reboot, start each guest in its **own** persistent background
process. Each `tart run` stays attached while its VM runs, so the two
commands must not be executed sequentially in one shell:

```sh
# Separate persistent process A
tart run --no-graphics --no-clipboard --no-audio ww-ui-1
# Separate persistent process B
tart run --no-graphics --no-clipboard --no-audio ww-ui-2
```

Use `tart list` and `tart ip ww-ui-1` (or `ww-ui-2`) for status and address.
The local SSH aliases are `ww-ui-1` and `ww-ui-2`; if an address changes,
`ssh -o HostName="$(tart ip ww-ui-1)" ww-ui-1` resolves it without changing
the alias's key and pinned host identity. Check
`ssh ww-ui-1 '~/ww-uitest-runs/gui-lock status'` before each run, and stop
with `tart stop ww-ui-1` (similarly for `ww-ui-2`). Do not add a third
macOS VM on this host.

Check the guest's console lock before dispatching a test (substitute `ww-ui-2`
as needed); `0` means unlocked, `1` means locked:

```sh
ssh ww-ui-1 "swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print(d[\"CGSSessionScreenIsLocked\"] ?? 0)'"
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
`.xcresult`. Only synthetic fixtures are allowed inside the VMs: never
mount or copy the user's recordings or test media. Label the result
`VM ww-ui-N (Virtualization.framework, macOS 27, 4 vCPU)` with the SHA.

**VM timings are not valid for performance gates.** Run
`ResponsivenessUITests` and other performance measurements on the Mac mini,
which remains the default physical GUI host. Keep the guests within their
eight-vCPU combined budget and avoid competing heavy builds on the host.
