# Offline speech XPC containment: pre-code feasibility

**2026-10-09 | Mac | NO-GO for implementation or inference.** This is a new
read-only lifecycle analysis, not an amendment to the rejected #321/#324
process-group runners or approval of the earlier #23 XPC proposals. No model,
media, signed helper, network probe, or OS setting was exercised. Lead and an
independent reviewer must resolve this gate *before* speech worker code. Refs
[#23](https://github.com/brandonmartinez/WaveWrangler/issues/23),
[#32](https://github.com/brandonmartinez/WaveWrangler/issues/32) and the
[#23 lifecycle-review decision](https://github.com/brandonmartinez/WaveWrangler/issues/23#issuecomment-6072604819).

## Contract and candidate boundary (not accepted)

Selected-Primary PCM and its derivatives may not leave the local processing
boundary. An inert `socket()` is permitted; IPv4/IPv6, loopback, UDP and
Unix-to-network relays must have **no CONNECT/BIND/SEND/RECEIVE network I/O**,
including through inherited or delegated connected FDs and descendants that
call `setsid()` ([user clarification](https://github.com/brandonmartinez/WaveWrangler/issues/23#issuecomment-6073886414)).
Do not equate a failed new TCP `connect` with this entire contract.

The plausible but unproven boundary is a separately signed, app-bundled XPC
service with its **own** App Sandbox, no network client/server, user-selected
file, bookmark, app-group, or inherit entitlements. Keep the current app's
entitlements unchanged: it has selected-file/bookmark access, so running the
inferencer in the app does not establish equivalent file isolation. Link the
pinned inferencer into the service, not a production child process. The app
checks selected-Primary authority and source currency, passes bounded copied
PCM bytes over a typed XPC interface (no source path, bookmark, or writable
FD), and checks currency again before publishing bounded word data. No service
user-selected output or plaintext PCM file is proposed. Code-signing,
container identity, actual FD provenance, transitive library behavior, and
each syscall result need evidence from an app-launched signed service; an
entitlements file or `sandbox-exec` command is not evidence.

Without an app group, the proposed model path is ordered, size-capped typed
chunks into the service's private container, with independently verified full
digest and length pinned in its signed bundle, no symlink traversal, and
read-only load from the verified object. Model acquisition, staged-byte
readability, ad-hoc signing, rights/notices and safe cold restart remain
unproven. This model plan cannot compensate for a missing PCM/worker exit
witness. Apple's [App Sandbox configuration](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox.md)
describes kernel-enforced restricted resources and per-target entitlements;
its [entitlement reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
defines client/server network privileges and separate child inheritance.
Neither states that absence of those two network entitlements blocks *use of
an inherited connected socket* or all IPC to a network-capable relay. Treat
those as open proof obligations, not as properties of the sandbox.

## Required witness and transaction

For each durable request epoch `E`, a sufficient witness would bind an
OS-authenticated service *instance* `S` to `E` **before the first PCM byte**
and account for every process or delegate that could retain its PCM or an
egress-capable FD, including a reparented `setsid()` descendant. It must
remain verifiable after the app or observer crashes, distinguish `S` from a
launchd replacement or reused PID, and establish that **all** those holders
have stopped and released their handles before retiring `E` or deleting its
last controlled input copy. "No process currently found" is insufficient if
the observer missed a fork; a network deny on `S` is insufficient for a
delegated connected FD.

If that witness existed, the minimum protocol would be:

1. **Prepare:** atomically persist and sync a private metadata-only journal
   record for `E` as `unknown/blocked`, including source/selection revision
   and a unique request nonce; do not persist transcript or PCM in the
   journal. Reconcile every older epoch before admitting work.
2. **Bind:** authenticate the signed service and obtain/verify its
   OS-backed, non-reusable instance witness; durably bind it and a complete
   descendant/delegation supervision mechanism to `E` *before* dispatch.
   A newly connected service must not attest on behalf of an older instance.
3. **Work:** send bounded PCM only after the binding is durable and network,
   FD and delegation denials have been proven. Admit one epoch at a time;
   reject unknown FDs, callbacks, paths, bookmarks, extra connections,
   subprocesses, changed inputs, or a broken monitor before processing.
4. **Retire:** a normal service receipt may report stopped inference and
   closed handles, but is not independently an exit witness. Only after a
   positive, epoch-bound OS witness for the service **and all holders** may
   the app sync a terminal journal record and retire the controlled copy.
   A receipt without that witness, or a witness without durable binding,
   leaves `E` blocked.
5. **Recover:** timeout, interruption, failed/cancelled XPC, app crash, service
   crash, launchd restart and observer restart all leave `E` unknown. On
   restart, inspect the durable record *before* making any new XPC request;
   retain controlled state, refuse all inference and cleanup, and expose a
   blocked remedy until positive retirement. Never remove private input
   merely because an XPC callback, PID check, process-group check, or
   best-effort kill succeeded.

This is a **conditional protocol**, not an implementable algorithm today:
step 2 has no established witness under the approved boundary. Atomic
metadata writes cannot make an in-memory OS handle durable, and a receipt
cannot be written after a fatal service crash. The app's own crash can lose
both the receiver and the opportunity to journal a later exit. In two possible
worlds the restarted app sees the same prepared epoch and no old connection:
in one `S` and all descendants exited; in the other a detached grandchild
still holds PCM or a connected FD. Retiring on those observations is unsafe;
remaining blocked forever is safe but cannot deliver post-crash cleanup or
usable selected-Primary speech. Retaining a private copy is not proof of
on-disk confidentiality or of the absence of orphaned plaintext elsewhere.

## Documented guarantees versus unresolved hypotheses

| Mechanism | What is supported | Why it cannot currently retire `E` |
| --- | --- | --- |
| App-bundled XPC | Apple says launchd starts the service on demand, may restart it, and ties its process to the client lifetime ([XPC](https://developer.apple.com/documentation/xpc.md), [service creation](https://developer.apple.com/documentation/xpc/creating-xpc-services.md)). | No documented durable callback to a *restarted* client, complete descendant census, FD revocation, or proof that a `setsid()` grandchild exits with the service. A live service is not a cleanup witness. |
| Connection handlers / transactions | [Interruption](https://developer.apple.com/documentation/foundation/nsxpcconnection/interruptionhandler.md) reports remote exit/crash while this client is alive; [invalidation](https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidationhandler.md) also covers failure to form a connection. `xpc_transaction_begin/end` only marks non-idle work ([XPC connections](https://developer.apple.com/documentation/xpc/xpc-connections.md)). | Neither handler persists across an app crash, identifies *all* descendants, nor proves cleanup. An interruption is not an authorization to reconnect, overwrite the epoch, or delete PCM. |
| PID, PID/start time, process snapshots or `NOTE_EXIT` | A live observer can collect identity/exit hints. Apple's [process-info header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h) describes process snapshots. | PIDs can be reused; a snapshot cannot recover children forked during observer downtime and later reparented. A kqueue is an observer-owned FD lost on crash. Access, macOS 26/27 behavior and an OS-guaranteed persistent unique identity are unverified; do not interpret failed lookup or an error as exit. |
| Mach port death, file lock or pipe EOF | A currently held right/lock/FD could signal destruction or close while its observer remains alive. | A port may be destroyed or a lock/FD closed without terminating its holder; descendants may retain PCM without retaining that particular handle. The client loses its watcher on crash. No supported, durable reattach-and-census protocol for an old service epoch has been established. |
| Process group / `setsid()` | The [#23 escaped-grandchild failure](https://github.com/brandonmartinez/WaveWrangler/issues/23#issuecomment-6072098219) observed a child outside the supervised group holding synthetic input. | Group disappearance and `deny process-fork` did not establish complete quiescence; repeating that approach cannot prove the contract. |
| Endpoint Security observer | It exposes fork/exit messages, but the [client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client.md) must be requested from Apple; [sequence numbers](https://developer.apple.com/documentation/endpointsecurity/es_message_t/seq_num.md) explicitly detect dropped events. | Not in this task's permission/signing scope. A stopped or crashed observer needs a separately proven gap-free, durable journal and descendant/FD accounting; merely installing an observer would not solve the proof. |

No cited Apple API currently supplies the complete, reconnectable
**exact-instance + durable-epoch + escaped-descendant/FD** witness in this
app-bundled XPC design. This is a bounded feasibility result, not a universal
claim that macOS can never support another approved architecture.

## RED-first obligations if scope changes

Before production code, a different author and independent reviewer must
specify a candidate witness with documented macOS 26/27 availability and
failure semantics. Synthetic adversarial tests must first fail on: app death
after durable prepare/before send; death after send/before receipt; worker death
before receipt; restart/PID reuse; missing observer events; process-group exit
while a `setsid()` grandchild holds input; and a passed connected FD whose
holder outlives the service. A later success must prove the *specific* old
epoch can only retire after all holders have stopped, including after app
restart, and must demonstrate no accidental plaintext cleanup in every
failure window.

Only with separately approved synthetic runtime scope: launch the actually
signed embedded service **from the app**, verify effective sandbox/signatures
and its observed private container, and use signed test-only child and
`setsid()` grandchild plus unsandboxed positive controls. Exercise permitted
private-container write versus denied outside-container marker/symlink and
IPv4/IPv6 TCP connect/bind, UDP send/receive, loopback,
inherited/preconnected sockets and Unix-to-network relay attempts. Record
actual syscall results and denial evidence, including attempted RECEIVE on
already connected endpoints. A failed control, unknown FD, unexpected
delegation, missing exit witness or monitor gap is a RED/NO-GO, never a
partial offline pass. This paragraph requests **no permission** to perform
those trials now.

**Decision needed from Lead/user before further speech-containment work:**
whether to timebox a *separately scoped synthetic-only feasibility experiment*
for a supported durable witness and comprehensive network/relay denial (and
identify the permitted host/signing/network-control scope), or defer #23/#32
speech inference pending an approved OS-backed architecture. A privileged
system extension, networking change, reboot-dependent workflow, on-disk
protection claim, or weaker no-network/no-leak contract is **not** authorized
by this note. The current production worker must continue to refuse
inference; #23/#32 and M3 speech acceptance remain open. Lead owns that
decision before any independent pre-code review or implementation.
