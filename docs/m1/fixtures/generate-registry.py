#!/usr/bin/env python3
"""Generate (or --check) docs/m1/fixtures/m1-fixture-registry.json.

Lead-authored source of truth for the WW-003 M1 fixture registry. The JSON is
derived output; edit this script, regenerate, and commit both.

Usage:
  python3 docs/m1/fixtures/generate-registry.py            # write registry, print counts
  python3 docs/m1/fixtures/generate-registry.py --check    # exit 1 if committed JSON differs
Standard library only; no network, no file access outside this directory.
"""
import collections, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "m1-fixture-registry.json")
SEED = "sha256(\"ww-m1-fixture|v1|\" + fixtureId + \"|\" + split + \"|\" + caseIndex) -> first 8 bytes big-endian UInt64"

SYN = {"class": "authorized-synthetic", "status": "authorized",
       "scope": "Generated in per-run temp directories by the test harness; M1 kickoff 2026-10-04 authorizes synthetic builds/tests. No user files, recordings, provider folders or network."}
GRANT = {
 "A": "Grant A (user, 2026-10-04): local GUI launch, XCUITest, accessibility audits and computer-use on the ad-hoc-signed app, under a coordinator-held single GUI lock; the user approves any prompts.",
 "B": "Grant B (user, 2026-10-04): temporary VoiceOver for the core M1 tasks.",
 "C": "Grant C (user, 2026-10-04): one iCloud Drive folder 'WaveWrangler-M1-Synthetic-Trial' with generated synthetic documents only, on this Mac: save, autosave, two-window/two-process conflict, brctl evict/download and recovery; delete the folder afterwards.",
 "D": "Grant D (user, 2026-10-04): temporary Increase Contrast, Reduce Motion and larger text; record original values and restore them.",
}
GRANT_20261005 = {
 "E": "Grant E (user, directly, 2026-10-05 13:35-13:37): synthetic iCloud Drive testing may run on this Mac and on the user's Mac mini ('Macsimus', Apple M2 Pro, macOS 27.0.1), which use the same Apple account, including deliberate multi-device testing ('yes, you can do multi-device icloud testing. ui stays on the mac mini'). Scope applied here: the 'WaveWrangler-M1-Synthetic-Trial' folder only, generated synthetic files only, each run's subfolder deleted afterwards and the deletion recorded; no user recordings; any GUI work only on the Mac mini.",
}
def granted(*keys, extra=""):
    return {"class": "authorized-user-grant", "status": "authorized (grants " + "+".join(keys) + ", relayed by M1 coordinator 2026-10-04)",
            "scope": " ".join(GRANT[k] for k in keys) + (" " + extra if extra else "")}
PROV_SYN = "Authored by Lead 2026-10-04 (this registry); generator code to be written by the owning lane (Mac for WWPersistence/WWSources/app). Truth is declared here, independently of the code under test."
LIM_SYN = "Synthetic local file-system evidence on the claimed host only (macOS 27.0.1, Xcode 27, Apple silicon, 128 GiB). Does not qualify provider (iCloud/OneDrive/Dropbox) atomicity, two-device behavior, power loss, the macOS 26/16 GB reference or real media."
LOCATIONS = ["app-container (default)", "user-chosen-folder (synthetic temp folder reached via read-write security-scoped bookmark)"]

# Show-document publication boundaries, derived from the WW-009 C3 order.
P = [
 {"id": "P1", "after": "C3.3 candidate encoded+validated", "before": "C3.4 prior retained",
  "injection": "WWPersistence publisher step hook; NSDocument path: our writeSafely(to:ofType:for:) override before calling super", "paths": ["publisher", "nsdocument"]},
 {"id": "P2", "after": "C3.4 validated prior retained in recovery store", "before": "C3.5 coordinated write / base check",
  "injection": "publisher step hook; NSDocument path: writeSafely override before super, after prior retention", "paths": ["publisher", "nsdocument"]},
 {"id": "P3", "after": "C3.5 base check passed", "before": "C3.6 bytes written",
  "injection": "publisher: NSFileCoordinator writing accessor; NSDocument path: throw from our write(to:ofType:for:originalContentsURL:) override before writing (AppKit then aborts safe save)", "paths": ["publisher", "nsdocument"]},
 {"id": "P4", "after": "C3.6 staged bytes written+flushed", "before": "C3.6 replace/publish of canonical file",
  "injection": "publisher-only (stage file -> replaceItemAt). NO public hook inside AppKit writeSafely; NSDocument path reaches this only by non-deterministic process kill (DUR-021)", "paths": ["publisher"]},
 {"id": "P5", "after": "C3.6 publication returned", "before": "C3.7 independent read-back",
  "injection": "publisher step hook; NSDocument path: writeSafely override after super returns", "paths": ["publisher", "nsdocument"]},
 {"id": "P6", "after": "C3.7 read-back verified", "before": "C3.8 library acknowledgement",
  "injection": "app save-completion handler before library ack (both paths)", "paths": ["publisher", "nsdocument"]},
 {"id": "P7", "after": "C3.8 library acknowledgement published", "before": "derived index update",
  "injection": "index updater entry (both paths)", "paths": ["publisher", "nsdocument"]},
]
# Library-document publication boundaries (library uses the WWPersistence publisher; it is not an NSDocument).
L = [
 {"id": "L1", "after": "library candidate encoded+validated", "before": "library prior retained", "injection": "library publisher step hook"},
 {"id": "L2", "after": "library prior retained", "before": "coordinated write / base check", "injection": "library publisher step hook"},
 {"id": "L3", "after": "base check passed inside NSFileCoordinator writing accessor", "before": "stage write", "injection": "coordinator accessor"},
 {"id": "L4", "after": "stage written+flushed", "before": "replaceItemAt publish", "injection": "library publisher step hook"},
 {"id": "L5", "after": "publish returned", "before": "independent read-back", "injection": "library publisher step hook"},
 {"id": "L6", "after": "read-back verified", "before": "derived index update", "injection": "index updater entry"},
]
NSDOC_NOTE = ("NSDocument path evidences P1-P3 and P5-P7 deterministically via public overrides (writeSafely override before/after super, write(to:ofType:for:originalContentsURL:) throw, completion handler, index entry). "
              "It does NOT deterministically evidence interruption inside AppKit's safe replace (P4); that boundary is evidenced only at the WWPersistence publisher level plus non-deterministic process kills. "
              "Any NSDocument claim about P4 is limited to 'AppKit stock safe-save, not independently interrupted'.")

def gen(recipe):
    return {"kind": "synthetic-deterministic", "seedDerivation": SEED, "recipe": recipe}
def syn(i, title, stratum, family, issues, recipe, truth, cal, hold, unit, limits, counts_toward=None, extra=None, permission=None, automated=True):
    e = {"id": i, "title": title, "stratum": stratum, "family": family, "issues": issues,
         "automated": automated, "generator": gen(recipe), "expectedTruth": truth,
         "permission": permission or SYN, "provenance": PROV_SYN,
         "split": {"calibration": cal, "holdout": hold, "unit": unit},
         "supportedClaimLimits": limits, "evidenceStatus": "not-yet-executed"}
    if counts_toward: e["countsToward"] = counts_toward
    if extra: e.update(extra)
    return e
def blocked(i, title, stratum, family, issues, scope, truth, limits, automated=False):
    return {"id": i, "title": title, "stratum": stratum, "family": family, "issues": issues,
            "automated": automated, "generator": {"kind": "none-until-consent", "seedDerivation": None, "recipe": "Exact operations/devices/providers specified in the consent request; synthetic generated content only unless consent says otherwise."},
            "expectedTruth": truth,
            "permission": {"class": "not-authorized", "status": "not-authorized", "scope": scope},
            "provenance": "Planned by Lead 2026-10-04; no fixture exists until consent is relayed by the M1 coordinator.",
            "split": {"calibration": None, "holdout": None, "unit": "defined at consent; frozen before holdout"},
            "supportedClaimLimits": limits, "evidenceStatus": "consent-blocked"}

F = []
# ---------------- Durability: show document ----------------
F.append(syn("M1-DUR-001","Explicit Save (new and existing document)","save/explicit-save","durability",["WW-005","WW-010","WW-049"],
  "Generate a show with 1-12 episodes, 0-40 logical sources, groups/speakers/collections; apply 1-20 edits; invoke explicit Save (and first Save to a new temp URL).",
  "On-disk file parses, checksum valid, revision = prior+1, payload equals the independently built expected value; prior revision retained in recovery store; status 'Saved on this Mac' only after read-back; library ack advances exactly once.",10,100,"documents",LIM_SYN))
F.append(syn("M1-DUR-002","Autosave ON edit-to-quiescent coherent checkpoint timing","autosave/ON","durability",["WW-005","WW-049"],
  "Default ON configuration; burst of 1-20 edits then quiescence; timestamps: last completed model mutation (monotonic) to first independent read that parses/validates the full expected state, either a published canonical revision or an unpublished edit-checkpoint record (WW-009 C2), labelled by kind.",
  "Every case reaches a coherent whole checkpoint; edit-checkpoint records carry documentID, baseRevision/baseChecksum, unpublished=true and never change canonical bytes or 'Saved' status; reported p95 and max; provisional gate <=2 s on claimed host. Callback success alone never counts.",20,100,"timing samples",LIM_SYN + " Timing is claimed-host only; not an autosave-cadence or reference-device claim (WW-052).",
  extra={"frozenGate": "<=2 s provisional (WW-005)"}))
F.append(syn("M1-DUR-003","Autosave OFF: no automatic publication, dirty preserved","autosave/OFF","durability",["WW-005","WW-049"],
  "Set OFF; edit; drive the scheduling boundary and deliver queued automatic autosave requests; observe for a bounded window.",
  "Zero automatic publications and zero edit-checkpoint records; canonical bytes unchanged; document remains dirty; automatic requests complete as non-success (never nil/success-shaped); no error loop (no repeated 1004-class errors); no autosavingFileType nil/empty.",10,100,"documents",LIM_SYN + " Model/AppKit-object level; native Close/Quit UI is M1-DUR-026."))
F.append(syn("M1-DUR-004","Autosave toggle transitions (ON->OFF with queued work; OFF->ON with pending edits)","autosave/configurable","durability",["WW-005","WW-049"],
  "Interleave: edit under ON, toggle OFF before/while an automatic request is queued; and edit under OFF, toggle ON with pending edits. Deterministic interleaving schedule from the seed.",
  "ON->OFF: no publication after OFF takes effect unless already past P4 (then reported as saved with exact revision); dirty state honest. OFF->ON: a coherent checkpoint of the pending state follows within the ON gate. Never a mixed revision.",10,100,"interleavings",LIM_SYN + " Addresses AS01 at object level only; native GUI replay is M1-DUR-026."))
F.append(syn("M1-DUR-005","Explicit Save while autosave is OFF","explicit-save/OFF","durability",["WW-005","WW-010"],
  "OFF; edits; explicit Save with valid file type.",
  "Publication of exact pending revision; dirty cleared only after successful read-back; OFF setting unchanged afterwards.",10,100,"documents",LIM_SYN))
F.append(syn("M1-DUR-006","Show-document publication-boundary interruptions (injected)","interrupted-publication","durability",["WW-005","WW-049","WW-010"],
  "For each boundary in boundaries[] (derived from WW-009 C3), inject a failure at its public injection point during Save/autosave/Save As. Run each boundary on every path listed in its 'paths'; publisher-only boundaries run on the WWPersistence publisher only.",
  "Canonical location holds either the old valid revision or the complete new revision, never a mixture; recovery store holds a validated coherent prior; status is failed or acknowledgement-uncertain (P5+), never 'Saved' without read-back; library/index do not advance on failure.",130,1300,"interruptions (10 cal / 100 holdout per boundary per applicable path: 6 boundaries x 2 paths + P4 publisher-only = 13 cells)",LIM_SYN + " Injected exceptions are not power loss or provider-sync interruptions. " + NSDOC_NOTE,
  extra={"boundaries": P, "perBoundary": {"calibration": 10, "holdout": 100, "perApplicablePath": True}, "frozenGate": ">=100 interruptions per publication boundary (WW-005/WW-049)", "nsdocumentPathCoverage": NSDOC_NOTE}))
F.append(syn("M1-DUR-007","Conflict: on-disk revision changed by another writer","conflict","durability",["WW-005","WW-049","WW-010"],
  "Between load and save, a separate harness writer publishes a different valid revision (or replaces the file with another document).",
  "Save stops with Conflict; neither revision is overwritten; both remain recoverable; non-destructive choices offered; no automatic merge.",10,100,"conflicts",LIM_SYN + " Same-host writer only; iCloud trial is M1-DUR-024; other providers/two-device are M1-DUR-030/025."))
F.append(syn("M1-DUR-008","Concurrent windows on one document","concurrent-window","durability",["WW-005","WW-010"],
  "Two or more window controllers on one document issue interleaved edits/undo and saves.",
  "One shared model and undo stack; every save publishes one coherent revision containing all committed edits; no lost edits; focus/selection per window independent.",10,100,"interleavings",LIM_SYN + " Object level; visual/keyboard window behavior is M1-DUR-026/M1-A11Y-001."))
F.append(syn("M1-DUR-009","Two-process competing writers","conflict/multi-process","durability",["WW-005","WW-049"],
  "Owned helper subprocess and test process both open the same temp document and save on a seeded schedule.",
  "Zero silent overwrites: each loser reports Conflict; every on-disk state is a whole valid revision; both users' work recoverable.",10,100,"races",LIM_SYN + " Local processes; TOCTOU narrowed and detected, not eliminated; not a provider guarantee."))
F.append(syn("M1-DUR-010","Offline / unavailable destination","offline","durability",["WW-005","WW-049","WW-010"],
  "Destination directory removed, made read-only, permission-denied, or path made unresolvable before/during save (simulated offline).",
  "Save fails honestly with distinct reason; prior valid revision retained; document stays dirty; retry offered.",10,100,"documents",LIM_SYN + " Simulated offline; real iCloud offline is part of M1-DUR-024 only where observable."))
F.append(syn("M1-DUR-011","Cancel during save stages (programmatic)","cancel","durability",["WW-005","WW-049"],
  "Cancel requested at each cancellable stage before and after publication.",
  "Before publish: disk unchanged, dirty retained. After publish: reported as 'revision saved, follow-up incomplete' with the exact revision, never 'nothing happened'.",10,100,"cancellations",LIM_SYN + " Native save-panel cancel is M1-DUR-026 (grant A)."))
F.append(syn("M1-DUR-012","Retry after failure","retry","durability",["WW-005","WW-049"],
  "Inject transient failure, then retry once or more.",
  "Retry publishes exactly the current pending revision once; no duplicate revisions; statuses transition honestly.",10,100,"retries",LIM_SYN))
F.append(syn("M1-DUR-013","Disk full (ENOSPC injected)","disk-full","durability",["WW-005","WW-010"],
  "Inject ENOSPC at stage write, prior retention, edit-checkpoint write and publication.",
  "Prior valid revision intact; partial stage files cleaned or ignored; distinct 'disk full' status; dirty retained.",10,100,"documents",LIM_SYN + " Injected, not a physically full volume. The real disk-image variant is NOT authorized.",
  extra={"variants": [{"id": "M1-DUR-013-real-volume", "permission": {"class": "not-authorized", "status": "not-authorized (needs user consent; not granted 2026-10-04)", "scope": "Would create/mount a small temporary disk image and fill it with generated data."}, "evidenceStatus": "consent-blocked"}]}))
F.append(syn("M1-DUR-014","Save As (success, failure, cancel)","save-as","durability",["WW-005","WW-010"],
  "Save As to new temp URL; inject failure at each stage; programmatic cancel.",
  "Success: new documentID/location semantics recorded explicitly, original untouched, library adds only a completed coherent document. Failure/cancel: original document and edits preserved; no orphan library entry.",10,100,"operations",LIM_SYN + " Native panel UX is M1-DUR-026 (grant A)."))
F.append(syn("M1-DUR-015","Acknowledgement-uncertain publication and reconcile","interrupted-publication/ack-uncertain","durability",["WW-005","WW-049","WW-010"],
  "Fail after publication but before/at read-back or library ack; then reopen.",
  "Status 'Save may have completed - reopen to verify'; library/index not advanced; explicit reopen/reconcile adopts the coherent on-disk revision and preserves library aliases/collections/order/unavailable entries.",10,100,"documents",LIM_SYN))
F.append(syn("M1-DUR-016","Migration from older synthetic schema","migration","durability",["WW-005","WW-010"],
  "Synthetic older schema documents (not a shipped WaveWrangler format) with human work; migrate with cancel/retry and injected failures.",
  "Original bytes and non-overwriting backup preserved; migrated whole revision equals independently authored expected semantics; unknown facts stay explicitly unknown; failures leave original or coherent new revision only.",10,100,"documents",LIM_SYN + " Synthetic old schema only until a real prior M1 schema exists."))
F.append(syn("M1-DUR-017","Corrupt show document","corrupt","durability",["WW-005","WW-010"],
  "Truncated, checksum-mismatch, invalid JSON, schema-invalid, empty, duplicate-key and wrong-documentID variants.",
  "Load refuses with distinct reason; suspect file untouched; validated recovery-store checkpoint offered as a new copy; never recreated from index.",10,100,"documents",LIM_SYN))
F.append(syn("M1-DUR-018","Unknown-newer show document","unknown-newer","durability",["WW-005","WW-010"],
  "Envelope with schemaVersion greater than supported, valid or partially unknown payload.",
  "Opens read-only with accessible reason; 100% refusal of edit, Save, autosave, Save As downsave and migration; bytes unchanged.",10,100,"documents",LIM_SYN,extra={"frozenGate": "100% refusal (WW-005)"}))
F.append(syn("M1-DUR-019","Library <-> project reconciliation interruption","library-project-reconciliation","durability",["WW-005","WW-010","WW-011"],
  "Interrupt between project publication and library acknowledgement, and during library publication itself; run with the library in each location stratum.",
  "Library never claims a revision that is not coherent on disk; reopen reconciles; both documents retain prior valid state; unavailable entries retained.",20,200,"interruptions (10/100 per location stratum)",LIM_SYN,
  extra={"locationStrata": LOCATIONS}))
F.append(syn("M1-DUR-020","Derived index deletion and rebuild","index-rebuild","durability",["WW-005","WW-010","WW-011"],
  "Delete/corrupt/replace the derived index; rebuild from library + validated show revisions, including unavailable shows.",
  "Zero loss of collections, order, aliases, comments, corrections or unavailable entries; rebuilt index equals expected derived value.",10,100,"rebuilds",LIM_SYN,extra={"frozenGate": "zero semantic loss (WW-005)"}))
F.append(syn("M1-DUR-021","Owned subprocess kill at show-document publication boundaries","interrupted-publication/process-kill","durability",["WW-005","WW-049"],
  "Helper subprocess runs the WWPersistence publisher and is terminated (SIGKILL) exactly at each boundary in boundaries[]; a separate seeded set kills a helper performing NSDocument-path saves at random points (reported separately, not per-boundary).",
  "Same truth as M1-DUR-006 after restart: old valid or complete new revision, never mixed; recovery store coherent.",35,700,"kills (5 cal / 100 holdout per boundary, publisher path)",LIM_SYN + " Process kill is not power loss or kernel panic. " + NSDOC_NOTE,
  extra={"boundaries": P, "perBoundary": {"calibration": 5, "holdout": 100}, "frozenGate": ">=100 interruptions per publication boundary (WW-005/WW-049)"}))
F.append(syn("M1-DUR-022","Unknown-newer library document","unknown-newer/library","durability",["WW-005","WW-010","WW-011"],
  "Library envelope with newer schemaVersion, in each location stratum.",
  "Library read-only with reason; no save/downsave/move; show documents still openable; bytes unchanged.",20,200,"documents (10/100 per location stratum)",LIM_SYN,
  extra={"locationStrata": LOCATIONS}))
F.append(syn("M1-DUR-023","Corrupt library and prior recovery","corrupt/library","durability",["WW-005","WW-010","WW-011"],
  "Same corruption variants as M1-DUR-017 applied to the library document, in each location stratum.",
  "Validated prior library checkpoint offered; never recreated from index; suspect file retained.",20,200,"documents (10/100 per location stratum)",LIM_SYN,
  extra={"locationStrata": LOCATIONS}))
F.append(syn("M1-DUR-024","iCloud Drive canonical trial (show + library) on this Mac","cloud-canonical/icloud-trial","durability",["WW-049","WW-005","WW-010","WW-006"],
  "In the single iCloud Drive folder 'WaveWrangler-M1-Synthetic-Trial' only: generated synthetic show documents and a library relocated there. Operations: explicit Save, autosave ON/OFF, two-window and two-process conflicts, brctl evict/download of the synthetic documents, interruption at publisher boundaries, recovery, library publication/move into and out of the folder. Delete the folder afterwards and record deletion.",
  "Observed (not simulated) behavior per operation: whole valid revisions only, conflicts detected without overwrite, evicted documents report placeholder/unknown honestly and reopen after download, prior work recoverable, library at iCloud location obeys C3-C5. Provider guarantees reported as observed for iCloud Drive on this Mac only.",
  10,290,"trial operations (min holdout: 100 save/autosave publications, 100 conflict attempts, 50 evict/download cycles, 20 recovery cases, 20 library-at-iCloud publications/moves)",
  "iCloud Drive on this single Mac only; no OneDrive/Dropbox, second-device or two-machine sync claim; interruption counts at uncontrollable sync boundaries are reported, not claimed as >=100 unless achieved.",
  permission=granted("C", "A", extra="GUI portions (if any) under grant A's single GUI lock."), automated=True))
DUR025_CELLS = [
 {"cell": "show-conflict", "calibration": 3, "holdout": 30,
  "recipe": "Both hosts open the same synthetic show (one revision r, synced and verified on both). Each host makes a different seeded edit and publishes it through the C3 order, with both publications started at a shared trigger time so they race. Then wait until both hosts observe a stable file (bounded wait, reported; timeout = case failure).",
  "variantsFreeze3": {"simultaneous": 20, "staggered": 10, "staggeredRecipe": "Host B opens revision r and holds the document (the product phase starts here). Host A publishes r+1. The harness waits, with the bounded wait, until A's r+1 digest is observed on B; if that wait expires, the case FAILS. Host B then publishes its seeded edit from the stale base r. Expected: C3 base-check Conflict on B; B's candidate preserved; B never shows Saved for it; A's r+1 stays current and byte-identical on both hosts."}},
 {"cell": "library-conflict", "calibration": 3, "holdout": 30,
  "recipe": "Both hosts use the same synthetic library in the trial folder (configured location, same libraryID, synced and verified). Each host makes a different seeded organizing edit (collection, alias, order or recents) and publishes at a shared trigger time; settle as for show-conflict. Ordering gate (m1-freeze-3): in every library case, Combine on host A is not started until host B has observed the unresolved provider version (or app-detected L4) and recorded at least two level samples while holding it, the first within 5 s of B's observation; in the concurrentCombine variant the gate applies to both hosts before round 1.",
  "variantsFreeze3": {"combineOnAThenB": 20, "concurrentCombine": 10, "concurrentCombineRecipe": "After both hosts have entered L4 (and the level-sampling gate is met on both), round 1 runs Combine (Keep Everything) on BOTH hosts at a shared trigger time. Because each Combine publishes, round 1 may itself race at the provider. Any later rounds run Combine on host A only; at most 3 rounds in total, each with a settle bound of 600 s. Converged = both hosts show one current, byte-identical library containing every seeded edit (ST-36 copies count as carried), 0 unresolved provider versions on either host, and a backup for every resolved version. Not converged after round 3, or a settle timeout = case FAIL."}},
 {"cell": "cross-machine-relink", "calibration": 2, "holdout": 20,
  "recipe": "Host A creates a synthetic show whose sources are generated random-byte files in the trial folder, with device-local access records on A only. After sync, host B opens the show with no device-local access record for it; then the harness supplies the source location to B as an explicit user choice (regrant), and B compares identity metadata. Seeded variants: same files; one source moved within the trial folder before B opens; one source replaced by a same-name different file."},
 {"cell": "recovery", "calibration": 2, "holdout": 20,
  "recipe": "Host A publishes revision r+1 while host B holds unpublished edits on revision r (edit-checkpoint record present on B). Seeded variants: B then saves (base check), B quits and relaunches before saving, and A is killed at a publisher boundary (P4 or P5) mid-publication while B is idle. Reopen on both hosts after sync settles."},
]
DUR025_RECIPE_F3 = {
 "setupPreconditions": "A case is established only when, strictly before its first product operation (see firstProductOperation), host A's setup publication of every fixture completed successfully (C3 steps 1-8, acknowledged and read back on A) and host B has observed every setup fixture (show or library publication, source files) with the expected digest or publication ID. Each fixture wait on host B is bounded at 420 s; on expiry host B calls FileManager.startDownloadingUbiquitousItem(at:) on the missing fixture (synthetic setup file only) and waits one more 420 s (worst case 840 s). setupNotEstablished is reserved for a fixture that has NOT ARRIVED on host B: at expiry it is absent there (or present only as a dataless placeholder), host A holds it readable with the expected digest, and A's setup publication completed successfully. Every other setup outcome is a case FAILURE, not setupNotEstablished: the fixture is present on host B with an unexpected digest or publication ID; it is not readable on host A with the expected digest; host A's setup publication failed, was refused, or is acknowledgement-uncertain; or a wait's expiry is not strictly earlier than the case's first product operation. Diagnostics recorded at every expiry, on BOTH hosts: the fixture's local digest or its absence, presence, size, dataless state, ubiquitousItemIsUploaded/ubiquitousItemIsUploading (A) and ubiquitousItemDownloadingStatus plus any download error (B), and host A's setup publication outcome and acknowledgement state. The case folder is deleted only at the end of the run, after diagnostics. Any timeout after the first product operation (including settle and the staggered-show wait) remains a case FAILURE. Relink truth 5 (zero source writes) is evaluated for setupNotEstablished cases too: a source digest change on either host is a FAILURE.",
 "replacement": "A setupNotEstablished slot is refilled from the frozen reserve split 'holdout-f3-reserve' (seed indices 0, 1, 2, ... consumed in order, same cell and variant as the slot; the reserve index used is recorded per refilled slot) until each cell has evaluated exactly its frozen holdout count. If setupNotEstablished exceeds 20% of a cell's frozen holdout count (more than 6 for show or library, more than 4 for relink or recovery), the cell FAILS as incomplete. Every setupNotEstablished case is reported with its diagnostics.",
 "firstProductOperation": {"show-conflict/simultaneous": "each host's open of revision r", "show-conflict/staggered": "host B's open of revision r (then held)", "library-conflict (both variants)": "the first product library load on either host", "cross-machine-relink": "host B's open of the show", "recovery": "host B's first edit on revision r", "rule": "Every case records, on both hosts, the first-product-operation timestamp and each setup wait's start and expiry (host clocks plus the measured A-B offset). A setup stall whose expiry is not strictly earlier than the first product operation is a FAILURE, never setupNotEstablished."},
 "setupConcurrency": "At most one case per run, across all cells, is in its setup phase at a time. Product phases may overlap, with at most 6 concurrent case workers.",
 "hostLabels": "Every run record carries, for BOTH hosts identified only by the pseudonyms 'host A' and 'host B' (no hostname, computer name or account identifier is recorded): hardware model, CPU brand, core count, physical memory, sw_vers product version and build, `xcodebuild -version`, `xcrun --show-sdk-version`, `swift --version`, and the sha256 of the probe binary actually run (which must match between hosts), plus the commit SHA, the git tree IDs of the harness trees run on each host, and 'same Apple account: operator-attested'. A run missing any label, or with mismatched probe hashes, is invalid and is not counted.",
 "levelSampling": "Samples use the read-only load path (lib-inspect), so sampling cannot change what it measures. On each host, sample at least every 5 s and at every load from the first observation of an unresolved provider version (or app-detected L4) until resolution. FAIL rule: any ready/L1 sample on a host while NSFileVersion.unresolvedConflictVersionsOfItem(at:) for the library file is non-empty on that host.",
 "perCaseReporting": "Protocol §4.2.1 condition 5 continues to apply to every case, as evidence (not gates): number of hosts that showed a local acknowledgement; time from trigger to settle; time to surfacing (app-detected or provider-surfaced) on each host; provider unresolved-conflict and other version counts on each host; which detection path fired. m1-freeze-3 adds: variant; setup outcome (established / setupNotEstablished with diagnostics / failure); reserve index for refilled slots; first-product-operation timestamp and every setup wait's start and expiry on both hosts; level samples with timestamps on both hosts; Combine rounds and per-round settle; the Combine summary's carried and not-carried sets next to the harness-computed sets.",
 "combineSummaryCheck": "Per library case, the Combine summary's carried and not-carried items must equal the sets computed by the harness from the before and after library models (an ST-36 copy counts as carried).",
 "calibrationCoverage": "The 10 calibration cases ('calibration-f3') include at least one staggered show case, one concurrentCombine library case and one case exercising the host-B level-sampling gate. In addition, one forced setupNotEstablished drill (an injected unreachable fixture) exercises the 420 s + download-request retry, the diagnostics and the reserve refill. The drill is reported separately and is not one of the 10 calibration cases.",
 "seeds": "Fresh splits 'calibration-f3', 'holdout-f3' and 'holdout-f3-reserve' (seed = sha256('ww-m1-fixture|v1|M1-DUR-025|' + split + '|' + caseIndex)); the m1-freeze-2 seeds are not reused for counted cases.",
}
DUR025_RECIPE_F4 = {
 "levelSamplingFailRule": "Supersedes the m1-freeze-3 levelSampling FAIL rule. A sample is a read-only evaluation of the level a product load would show at that instant, without its side effects: lib-inspect loads a LibraryStore against temporary copies of the host's library settings and recovery store, with a provider-version wrapper that never marks anything resolved; nothing on the host changes. Per sample and per unresolved provider version V of the library file on that host, the sample records: V's decode result; the product's isIncluded judgement; the fork base the product used (its identity/revision); an INDEPENDENT harness judgement of whether V's content (the seeded edits of the host that wrote V, known to the harness) is present in the sampled current library, ST-36 copies counting as present; whether a notice is shown for V; and the sampled level. A sample FAILS iff the level is ready/L1 AND at least one unresolved version V is NOT exempt. V is exempt only if ALL of: (a) V decodes as a valid library with the same libraryID; (b) the product's isIncluded is true against the sampled current library with a recorded fork base; (c) the independent harness judgement (see independentInclusionJudgement) is 'included'. A version that is undecodable, has a different libraryID, has no recorded fork base, or is not proven included by both judgements is never exempt, and ready/L1 while it is unresolved FAILS unless the sample also shows the unusable-version notice (#119) for an undecodable or different-library version. Any disagreement between (b) and (c) is reported, and a product 'included' with a harness 'not included' FAILS the sample.",
 "independentInclusionJudgement": "Computed by the harness only from its own record of the seeded edits made by the host that wrote V (collection additions, collection and alias renames, removals, reorders and recorded saves of entries or recents), compared directly against the sampled current library model on that host. An ST-36 copy of a reordered or diverging collection counts as present when it carries exactly the seeded membership and order. It must NOT call, wrap or re-derive LibraryMerge.isIncluded, LibraryReconciler or any other product merge or reconcile code, and must NOT read the product's judgement or fork base. Outcomes: 'included' (every seeded edit of that host is present), 'not included' (at least one is absent), or 'undetermined' (the harness cannot decide, e.g. an edit record is missing or the model does not decode); 'undetermined' is never exempt.",
 "truth1LibraryClause": "Truth (1)'s library clause ('... drives L4 (changedElsewhere) ... a provider conflict version that the app never surfaces is a failure') and protocol §4.2.1 condition 4 are read subject to levelSamplingFailRule, as follows. In-window (before settle): a version that is exempt under levelSamplingFailRule at a sample need not drive L4 or be surfaced at that sample. Every non-exempt unresolved version must still drive L4 or, if undecodable or a different library, the #119 notice; a sample where it does neither while the host shows ready/L1 FAILS. At settle: §4.2.1 conditions 2 and 4 apply unchanged. On each host, an unresolved provider version that at settle is neither resolved (with its backup present) nor surfaced (L4 or the #119 notice) while that host shows ready/L1 FAILS the case, even if it was exempt in-window. An indefinitely unresolved version can therefore never pass, including in combineOnAThenB, which has no zero-unresolved criterion of its own.",
 "literalReadingReport": "Each sample also records the raw unresolved-version count, and the evidence reports, per host and per case, the number of samples that would FAIL under the literal m1-freeze-3 rule (ready/L1 while the unresolved list is non-empty) next to the m1-freeze-4 result, so either reading can be recomputed from the records.",
 "combineSummaryCheck": "Supersedes the m1-freeze-3 combineSummaryCheck. The product summary lists not-carried items and counts; summary-carried is defined as the seeded edits minus summary-not-carried. Per library case the check is: summary-not-carried (entries plus queued changes) equals the harness-computed not-carried set (an ST-36 copy counts as carried); collectionsKeptAsCopies equals the number of copies observed; and every count shown in the summary equals the count the harness computes from the before and after models.",
 "hostBTreeIDs": "Host B runs only the probe binary built on host A. The run record gives the git tree IDs of the trees host A built it from, and host B is attested by a probe binary sha256 that matches host A's; a mismatch invalidates the run.",
 "uncountedSplits": "Uncounted splits: 'calibration-f3-reserve' (calibration refills), 'drill-f3' and 'drill-f3-reserve' (the forced setupNotEstablished drill). They never count toward calibration or holdout.",
 "drill": "The forced-stall drill injects the unreachable fixture as a synthetic source file in the case folder whose name ends in '.nosync' (iCloud Drive does not sync it). It is readable on host A with the expected digest; host B waits 420 s, requests the download (any error recorded), waits 420 s more; the case is setupNotEstablished with diagnostics on both hosts and a refill from 'drill-f3-reserve'. The file is deleted with the trial folder at the end of the run.",
 "variantAssignment": "Deterministic per split: for each cell, a list with the exact variant counts (show 20 simultaneous / 10 staggered; library 20 combineOnAThenB / 10 concurrentCombine) is shuffled with seed sha256('ww-m1-fixture|v1|M1-DUR-025|' + split + '|' + cell + '|variants'). Calibration is fixed: show [simultaneous, simultaneous, staggered]; library [combineOnAThenB, combineOnAThenB, concurrentCombine]; the host-B sampling gate applies to all three calibration library cases. A refilled slot keeps its slot's variant.",
 "combineOnAThenBRounds": "In combineOnAThenB, after host A's Combine round settles, host B does a product load; if B is still in L4, B runs Combine, counted as a round, within the same limit of at most 3 rounds and a 600 s settle per round. If neither an unresolved provider version nor an app-detected L4 is observed on host B within 420 s after the race trigger, the case FAILS (the product phase has started).",
}
F.append(syn("M1-DUR-025","Two-device iCloud conflict, cross-machine relink and recovery","conflict/two-device","durability",["WW-049","WW-006","WW-005","WW-012"],
  "Two Macs on the same Apple account: host A = this Mac (main), host B = the Mac mini. Both run the headless harness only (package tests / wwpersist-probe); no app GUI on host A, and none is needed on host B. All files are generated synthetic data in a per-run subfolder of 'WaveWrangler-M1-Synthetic-Trial', deleted afterwards with the deletion recorded. Four cells (see 'cells'): two-host publish race on a show; two-host publish race on the library; cross-machine relink; recovery across hosts. Each case records both hosts' outcomes, the settled on-disk revision on each host, preserved candidates/journals, NSFileVersion current/unresolved-conflict/other versions on each host, and source digests.",
  "(1) Conflict detected, by a stated mechanism (protocol §4.2.1 interpretation folded in at m1-freeze-3): a local C3 'Saved on this Mac' during a provider race is local truth, not a cross-device current-revision claim; truth is judged at the recipe's settle point, where exactly one publication is current and byte-identical on both hosts, every other locally acknowledged publication is app-detected (C3 base-check Conflict, candidate preserved) or provider-surfaced, silent last-writer-wins is a failure, no host shows a cross-device or synced claim for a losing publication, and no losing host keeps an unqualified 'Saved' after settle without a conflict indication (C3/C4). Shows: whenever the provider produces an unresolved NSFileVersion conflict version, it is surfaced as evidence (C4, no automatic merge) and never silently resolved; the count, including zero, is visible in the show's status; and any show race loses no edit, whether through the app-level base-check stop with the losing candidate preserved or through a surfaced provider version. Library: whenever an unresolved provider conflict version of the library file exists, it is detected on load, reload and before each update and drives L4 (changedElsewhere); an app-detected divergence (base-check conflict or changed-elsewhere) also drives L4. A provider conflict version that the app never surfaces is a failure; the absence of provider versions is reported, never assumed either way. Level sampling (m1-freeze-3; see recipeFreeze3.levelSampling and the library ordering gate): on EACH host, from the first observation of an unresolved provider conflict version of the library file (or app-detected L4) until it is resolved, the library level is sampled through the read-only load path at least every 5 s and at every load; any ready/L1 sample on a host while NSFileVersion.unresolvedConflictVersionsOfItem for the library file is non-empty on that host is a failure (m1-freeze-3 text; from m1-freeze-4 the FAIL predicate is recipeFreeze4.levelSamplingFailRule, which exempts only a version that decodes, has the same libraryID and is proven included both by the product against a recorded fork base and by an independent harness judgement; the literal count is still reported). "
  "(2) Both versions preserved: for shows, each host's edit is present after settle in the canonical file, the losing host's preserved candidate, or a surfaced NSFileVersion conflict version; zero silently lost edits. For the library, in every race, whether L4 came from a provider conflict version or from app-level detection, after L4 -> Combine (Keep Everything, ST-36) both Macs' changes (including each Mac's collections) are present in the current library on BOTH hosts; when provider conflict versions exist, each is copied to the device-local recovery store before it is marked resolved (nothing is discarded without a backup); concurrent Combines on the two hosts converge to a library containing both sides' changes (exercised directly in the concurrentCombine variant from m1-freeze-3). The Combine summary shown to the user is honest: its carried and not-carried items equal the sets computed from the before and after library models, per case (a change kept as an ST-36 copy is carried); it never reports a carried change as lost (m1-freeze-3; see #131). "
  "(3) No mixed revision: every reopen on either host yields one whole valid revision (checksum and payload valid) or an honest refusal; never a mixture. "
  "(4) NSFileVersion observed and reported: unresolved conflict versions and other versions are counted per case per host and reported, whatever the count; never assumed. "
  "(5) Relink needs an explicit regrant: host B never resolves a source by path or name alone; it shows a needs-relink/regrant state until the explicit choice; a moved or replaced file is reported as different, never silently substituted; zero source writes on both hosts (harness digests). "
  "(6) Recovery: work unpublished on a host stays recoverable on that host (device-local); no cross-device recovery is claimed; the app never reports Saved for content not read back on that host. "
  "(7) No provider-atomicity claim follows from any result.",
  10,100,"cases (cells: show-conflict 3/30, library-conflict 3/30, cross-machine-relink 2/20, recovery 2/20)",
  "iCloud Drive with two Macs on one Apple account (host labels recorded per run), synthetic files only. Sync timing is not controlled and is reported as observed. The headless harness is unsandboxed, so the regrant is an explicit harness-supplied choice, not the powerbox panel (sandboxed grant is M1-REF-020). No OneDrive/Dropbox, network-offline, power-loss or provider-atomicity claim. Neither host is the macOS 26 / 16 GB reference.",
  extra={"cells": DUR025_CELLS, "recipeFreeze3": DUR025_RECIPE_F3, "recipeFreeze4": DUR025_RECIPE_F4},
  permission={"class": "authorized-user-grant", "status": "authorized (grant E, given by the user directly 2026-10-05; relayed to the M1 coordinator)",
              "scope": GRANT_20261005["E"]}))
F.append(syn("M1-DUR-026","Native GUI lifecycle: Close/Quit dirty decisions, AS01/AS05 replay, panel Save As cancel, Revert, edit-checkpoint recovery presentation","autosave/native-gui","durability",["WW-005","WW-049","WW-007"],
  "Launch the ad-hoc-signed app with synthetic documents in temp/trial folders; drive via XCUITest/computer-use: OFF dirty Close/Quit (all routes: Close, Cmd-Q, app menu, Dock), queued ON->OFF race (AS01), dirty Quit (AS05), Save As panel cancel, Revert, relaunch with a pending edit-checkpoint record.",
  "Dirty OFF or failed-autosave documents always present Save/Don't Save/Cancel on Close and every Quit route; no silent loss; edit-checkpoint offered as 'Restore unsaved changes' (dirty, not saved); AS01 and AS05 evidenced or remain open.",
  2,20,"GUI scenarios (per scenario; destructive choices only on synthetic documents)","Single claimed host; scripted UI, not human usability; AS01/AS05 stay open until these pass.",
  permission=granted("A")))
F.append(syn("M1-DUR-027","Library publication-boundary interruptions (injected)","interrupted-publication/library","durability",["WW-005","WW-049","WW-010","WW-011"],
  "Inject failure at each library boundary in boundaries[], with the library in each location stratum.",
  "Library location holds old valid or complete new library revision, never mixed; library prior checkpoint coherent; collections/order/aliases/unavailable entries intact; index not advanced on failure.",120,1200,"interruptions (10 cal / 100 holdout per boundary per location stratum)",LIM_SYN,
  extra={"boundaries": L, "locationStrata": LOCATIONS, "perBoundary": {"calibration": 10, "holdout": 100, "perLocationStratum": True}, "frozenGate": ">=100 interruptions per publication boundary (WW-005/WW-049)"}))
F.append(syn("M1-DUR-028","Owned subprocess kill at library publication boundaries","interrupted-publication/library-process-kill","durability",["WW-005","WW-049"],
  "Helper subprocess publishes the library (user-chosen-folder stratum) and is SIGKILLed exactly at each library boundary.",
  "Same truth as M1-DUR-027 after restart.",30,600,"kills (5 cal / 100 holdout per boundary)",LIM_SYN,
  extra={"boundaries": L, "perBoundary": {"calibration": 5, "holdout": 100}, "frozenGate": ">=100 interruptions per publication boundary (WW-005/WW-049)"}))
F.append(syn("M1-DUR-029","Reopen show from library after relaunch, then Save (read-write document bookmark)","reference/document-bookmark-reopen-save","durability",["WW-006","WW-010","WW-011","WW-008"],
  "Create show documents and a library entry holding a read-write security-scoped bookmark; terminate the host process; in a new process resolve the bookmark, start access, open the show, edit, Save, stop access. Variants: stale bookmark, moved document, revoked access, library at user-chosen folder.",
  "Reopen and Save succeed via the read-write bookmark with read-back verification; scopes balanced; stale/moved/revoked cases show regrant/relink without writing elsewhere; source bookmarks remain read-only (any write attempt via a source scope fails).",10,100,"relaunch cycles","Counts as sandbox evidence only when the host is sandboxed (else labelled non-sandboxed). GUI relaunch variant is part of M1-REF-020 (grant A)."))
F.append(blocked("M1-DUR-030","Other cloud providers as canonical locations (OneDrive, Dropbox)","cloud-canonical/other-providers","durability",["WW-049","WW-005","WW-010"],
  "Not granted 2026-10-04; requires exact consent naming provider, folder (generated content only), operations and network use.",
  "Per provider/operation observed publication, conflict, offline, cancel/retry behavior.",
  "OneDrive/Dropbox guarantees remain SIMULATED/UNKNOWN; no support claim."))
# ---------------- References ----------------
LIM_REF = "Synthetic generated files in temp dirs on the claimed host. Security-scoped behavior counts only when run inside a sandboxed host; otherwise labelled non-sandboxed. No real media, provider, second device or TCC/panel grants."
def ref(i, title, stratum, recipe, truth, cal=10, hold=60, counts=True, extra=None, limits=LIM_REF):
    return syn(i, title, stratum, "reference", ["WW-006","WW-012"], recipe, truth, cal, hold, "lifecycle cases", limits,
               counts_toward=["WW-006 >=1,000 lifecycle/error/cancel cases"] if counts else None, extra=extra)
F.append(ref("M1-REF-001","Add reference; read-only bookmark create/resolve","reference/add","Generate source files (random bytes, never audio decoded); add via harness; create read-only security-scoped bookmark where sandboxed.",
  "Logical SourceID assigned; hints stored; access record device-local; identity 'unverified'; source bookmark created with read-only option; zero source writes; scopes balanced."))
F.append(ref("M1-REF-002","Stale bookmark refresh while access is valid","reference/stale-bookmark","Move/rename source while access remains valid so resolution reports stale.",
  "Bookmark refreshed (still read-only) only with valid access; identity remains unverified until explicit confirmation; no substitution."))
F.append(ref("M1-REF-003","Regrant required","reference/regrant","Bookmark unresolvable or access expired/denied.",
  "State 'regrant required' (access denied/unknown, not missing); no automatic replacement; regrant path offered."))
F.append(ref("M1-REF-004","Moved source","reference/moved","Move source within temp tree.",
  "Location 'candidate-moved' or unresolved; explicit relink required; identity unverified; zero writes."))
F.append(ref("M1-REF-005","Copied source (original still present)","reference/copied","Copy source; optionally delete original later.",
  "Copy is never auto-selected; ambiguity surfaced; explicit choice required."))
F.append(ref("M1-REF-006","Renamed source","reference/renamed","Rename in place.",
  "Name hint updated only after explicit relink/confirmation; identity unverified."))
F.append(ref("M1-REF-007","Same-name substitute","reference/same-name-substitute","Replace file at original path with different bytes and same name (includes the bookmark-resolves-replacement counterexample).",
  "Never silently accepted; identity 'changed' or 'unverified'; explicit confirmation required; zero writes."))
F.append(ref("M1-REF-008","Denied access","reference/denied","POSIX permission removal on generated file/dir.",
  "access=denied; never labelled missing; distinct remedy."))
F.append(ref("M1-REF-009","Missing source","reference/missing","Delete generated file.",
  "location=unresolved, missing labelled distinct from denied/unknown; relink offered."))
F.append(ref("M1-REF-010","Changed source metadata","reference/changed","Change size/modification date via append to generated file.",
  "identity=changed (metadata evidence) or unverified; never auto-confirmed."))
F.append(ref("M1-REF-011","Cloud placeholder residency (test double)","reference/cloud-placeholder","Inject resource-value double reporting placeholder/not-downloaded/unknown.",
  "residency=placeholder or unknown exactly as reported; no generic classifier; OFF makes zero download requests.",
  limits=LIM_REF + " Test double only; real iCloud values are M1-SRC-ON-PROV-001 (grant C)."))
F.append(ref("M1-REF-012","Download progress known/unknown (test double)","reference/download-progress","Double emits determinate, indeterminate and absent progress.",
  "Determinate progress only when reported; otherwise 'Progress unknown'; accessible text values.",limits=LIM_REF + " Test double only."))
F.append(ref("M1-REF-013","Download cancel (test double)","reference/cancel","Cancel transfer at seeded points.",
  "transfer=cancelled; no partial state presented as available; scopes balanced.",limits=LIM_REF + " Test double only."))
F.append(ref("M1-REF-014","Download retry (test double)","reference/retry","Fail then retry.",
  "Exactly one active request; honest state transitions.",limits=LIM_REF + " Test double only."))
F.append(ref("M1-REF-015","Offline source provider (test double)","reference/offline","Double reports offline/network unavailable.",
  "transfer=failed/offline with retry; residency unchanged; no fake availability.",limits=LIM_REF + " Test double only."))
F.append(ref("M1-REF-016","Scope balance under injected error/cancel","reference/scope-lifecycle","Inject errors/cancellation at each scope acquire/use/release point across all reference, document and library-folder bookmark operations.",
  "Every successful start is balanced by exactly one stop; leaked-scope counter == 0; zero source writes.",hold=150,extra={"frozenGate": "zero leaked scopes (WW-006)"}))
F.append(ref("M1-REF-017","Cross-machine relink (simulated: no device-local access record)","reference/cross-machine-simulated","Open a show document whose sources have no access records on this device.",
  "All sources 'relink required'; hints shown as hints; explicit relink only."))
F.append(syn("M1-REF-018","Zero-source-write invariant audit","reference/immutability-audit","reference",["WW-006","WW-012"],
  "Harness digests every generated source (outside the app process) before and after every REF/SRC/DUR-029 case.",
  "All digests unchanged; no rename/move/delete; leaked scopes = 0; substitutions = 0.",0,0,"invariant over all REF/SRC cases (not additional cases)",LIM_REF + " Harness-side digests of generated files only; the app never hashes sources.",
  extra={"frozenGate": "zero source writes / substitutions (WW-006)"}))
F.append(syn("M1-REF-019","Recorder groups, epochs, channels, speakers, primary/backup","organization/groups-speakers","organization",["WW-012","WW-011"],
  "Generate episodes with 1-6 groups, 1-8 clips per group, unknown/known channel counts from synthetic safe metadata, speakers, primary/backup assignments and corrections with undo.",
  "Group clock distinct from clip start; UNKNOWN duration/channels stay UNKNOWN; provisional vs user-confirmed labels honest; primary change marks dependents stale; named undo restores exact state.",10,100,"episodes",LIM_REF))
F.append(syn("M1-REF-020","Sandboxed native panel grant/regrant/relaunch (sources read-only; documents/library folder read-write)","reference/native-grant","reference",["WW-006","WW-008","WW-012"],
  "Launch the sandboxed ad-hoc-signed app; select synthetic source files, a synthetic show document and a library folder via NSOpenPanel/NSSavePanel; quit; relaunch; resolve bookmarks; reopen show from library and Save; attempt source access after revocation/move to drive regrant.",
  "Panel grant -> bookmark of the correct mode (source read-only; document and library folder read-write) -> relaunch resolve -> start/stop balanced; reopen+Save succeeds; regrant path works; zero source writes.",
  2,20,"GUI scenarios","Single claimed host, ad-hoc signed; not Developer ID/notarized/clean-install (WW-041/052).",permission=granted("A")))
# ---------------- Source availability ----------------
F.append(syn("M1-SRC-OFF-001","Metadata-only (source availability OFF) trial set","source/metadata-only-OFF","source-availability",["WW-006","WW-012"],
  "OFF; run add reference, open show, relink, library rebuild, index rebuild, primary/backup edits, placeholder sources (double).",
  "Recording gateway: zero content reads, hashes, header reads, previews/thumbnails/QuickLook, decodes and download requests; forbidden-API check clean.",10,200,"workflows",
  "LABELLED DEFAULT-OFF METADATA SET. Proves app requests only; OS/provider/picker activity not proven absent. Not evidence for default-ON behavior.",
  extra={"trialLabel": "default-OFF metadata-only", "frozenGate": "zero app content/hash/header/preview/decode/download requests (WW-006)"}))
F.append(syn("M1-SRC-ON-001","Default-ON source availability (synthetic provider double)","source/default-ON","source-availability",["WW-006","WW-012"],
  "ON (default); double reports placeholder residency, determinate/indeterminate/absent progress, offline, errors; cancel/retry seeded.",
  "Requests availability only for placeholder sources; accessible progress/unknown/offline/cancel/retry states; no generic classifier; OFF control reachable and effective.",10,200,"workflows",
  "LABELLED DEFAULT-ON SYNTHETIC SET. Test double only; does not qualify any real provider.",extra={"trialLabel": "default-ON synthetic double"}))
F.append(syn("M1-SRC-ON-002","Toggle source availability mid-transfer","source/toggle","source-availability",["WW-006","WW-012"],
  "Switch ON->OFF and OFF->ON while transfers are pending/in progress (double).",
  "ON->OFF stops issuing new requests and cancels or reports in-flight ones honestly; OFF->ON resumes only for placeholders.",10,100,"interleavings","Test double only.",extra={"trialLabel": "default-ON synthetic double"}))
F.append(syn("M1-SRC-ON-002-REVIEW","Setting races and stale transfer states (added after PR #54 review)","source/toggle","source-availability",["WW-006","WW-012"],
  "Four seeded interleavings (double): OFF toggled while a refresh's off-main evaluation is held by a deterministic gate; explicit Make Available during an automatic transfer, then OFF; ON download, then OFF, then eviction; a stale notRequested(.awaitingAccess) state followed by fresh evidence.",
  "OFF during a held refresh issues 0 requests; an explicit request survives OFF; after OFF + eviction the state is a fresh notRequested(.availabilityOff) with the Make Available remedy; stale states never mask fresh evidence. Zero leaked scopes, source writes and substitutions.",10,100,"interleavings",
  "Test double only. Added to the matrix during PR #54 review (2026-10-05) and to the registry at the 2026-10-05 freeze; it does not count toward the WW-006 >=1,000 reference total.",
  extra={"trialLabel": "default-ON synthetic double"}))
F.append(syn("M1-SRC-ON-PROV-001","Real provider source availability: iCloud Drive trial folder","source/default-ON/icloud-trial","source-availability",["WW-006","WW-012"],
  "Generated synthetic source files (random bytes, never decoded) inside 'WaveWrangler-M1-Synthetic-Trial'; brctl evict to create placeholders; then OFF (metadata-only) and ON runs: observe residency/progress/offline/cancel/retry; brctl download where needed. Delete the folder afterwards.",
  "OFF: zero app content/download requests while placeholders stay placeholders as observed. ON: observed residency/progress (or 'Progress unknown')/cancel/retry; zero source writes; provider work observed separately.",
  5,100,"evict/availability cycles (50 OFF, 50 ON holdout)",
  "iCloud Drive on this Mac only, synthetic files only; OFF and ON reported as separately labelled sets; no OneDrive/Dropbox claim.",
  permission=granted("C"), extra={"trialLabel": "real iCloud: separate default-OFF and default-ON subsets"}))
for n, prov in [(2,"OneDrive"),(3,"Dropbox")]:
    F.append(blocked(f"M1-SRC-ON-PROV-00{n}",f"Real provider source availability: {prov}","source/default-ON/provider","source-availability",["WW-006","WW-012"],
      f"Not granted 2026-10-04; requires exact consent: {prov} folder containing generated (non-recording) files, operations, network use.",
      "Observed residency/progress/offline/cancel/retry; zero source writes; provider work observed separately.",
      f"No {prov} support claim until executed."))
# ---------------- Scale ----------------
F.append(syn("M1-SCALE-001","Library scale: 100 projects / 1,000 references","scale","scale",["WW-007","WW-011"],
  "Generate 100 show documents (>=2 episodes each), 1,000 distinct logical references, collections, >=1 unavailable show; measure model+view-model open per show and defined interactions (select show/episode, toggle collection, rename, filter sidebar). Native-window timing variant under grant A.",
  "p95 (nearest-rank ceil(0.95n)) open <1 s and interaction <100 ms on claimed host; zero main-thread provider I/O; first-open and warm reported separately.",20,600,"timing samples (100 open-first, 100 open-warm, 400 interaction)",
  "Claimed host only (macOS 27.0.1/128 GiB) -- NOT the macOS 26/16 GB reference (WW-052). Model/view-model and (grant A) native-window measurements reported separately.",
  extra={"frozenGate": "p95 open <1 s, interaction <100 ms (WW-007, provisional)"}))
# ---------------- Accessibility ----------------
TASKS = "WW-004 18 core tasks + source ON/OFF/unknown/offline/cancel/retry, relink, primary/backup, save/conflict/autosave ON/OFF/explicit Save, library location choose/move, edit-checkpoint restore"
F.append(syn("M1-A11Y-001","Keyboard-only core M1 task suite","accessibility/keyboard","accessibility",["WW-007","WW-011","WW-012"],
  "XCUITest/computer-use keyboard-only scripts over synthetic documents: " + TASKS + "; plus Xcode accessibility audits.",
  "100% core tasks completable by keyboard with visible focus; accessibility audit issues triaged with zero unresolved blockers.",2,1,"full suite runs (each covers every core task)","Scripted, single host; not participant usability (WW-052).",permission=granted("A")))
F.append(syn("M1-A11Y-002","VoiceOver core M1 task suite","accessibility/voiceover","accessibility",["WW-007","WW-011","WW-012"],
  "Temporarily enable VoiceOver; operator-driven (computer-use/manual) core task suite: " + TASKS + "; restore VoiceOver to its original state.",
  "100% core tasks completable with VoiceOver; names/values/states/blocked reasons announced; no unsolicited focus change; VoiceOver state restored.",1,1,"full suite runs","Single operator/host; not broader participant studies (WW-052).",permission=granted("B","A"),automated=False))
F.append(syn("M1-A11Y-003","200% text, Increase Contrast, Reduce Motion, cold/warm/recovery","accessibility/visual","accessibility",["WW-007","WW-011","WW-012"],
  "Record original OS values; temporarily enable Increase Contrast, Reduce Motion and larger text; run core task views cold/warm/recovery; restore and verify original values.",
  "Essential names/state/controls visible and reflowed at larger text/200% app text; contrast acceptable with Increase Contrast; no essential motion; original OS values restored exactly.",1,1,"full suite runs","Single host; measured contrast ratios reported where tooling allows; reference device -> WW-052.",permission=granted("D","A")))
F.append(syn("M1-A11Y-004","Static accessibility audit","accessibility/static","accessibility",["WW-007","WW-011","WW-012"],
  "Enumerate controls/status values from view models and source; check labels, values, hints, identifiers, non-colour status text, menu/keyboard equivalents for each core task.",
  "100% core-task controls have accessible name/value/action and a keyboard/menu path; status text never colour-only.",0,1,"audit run",
  "Static/code-level only; NOT a VoiceOver or human usability result."))
# ---------------- User-provided ----------------
F.append({"id": "M1-USER-001","title": "User-provided local disposable episode copy (path withheld)","stratum": "manual/real-media-organizer","family": "user-provided",
  "issues": ["WW-012","WW-011","WW-006"],"automated": False,
  "generator": {"kind": "user-provided","seedDerivation": None,"recipe": "Selected by the user/coordinator-designated operator through the app's native panel at validation time. Path, file names and content are never recorded here, in tests, logs committed to the repo, or PR text."},
  "expectedTruth": "Manual checklist: references added without source writes; recorder grouping/speaker/primary-backup assignment and correction work; relink path works; metadata-only and default-ON states shown honestly; duration/channels UNKNOWN unless safe metadata. Operator records pass/fail per checklist item only.",
  "permission": {"class": "consent-relayed-manual","status": "consented (relayed by M1 coordinator 2026-10-04; Lead has not seen the original user message)",
    "scope": "M1 manual import/library/recorder-grouping/primary-backup/relink validation only; read-only; no decode, analysis, hashing, preview or transcription; never in automated tests or the repository; disposable copy."},
  "provenance": "User-supplied disposable copy; provenance details intentionally withheld for privacy.",
  "split": {"calibration": 0,"holdout": 0,"unit": "manual validation session (not a statistical sample)"},
  "supportedClaimLimits": "One user-provided episode; supports only 'the organizer workflow was manually exercised on one real episode copy'. No media, format, provider, accuracy or performance claim.",
  "evidenceStatus": "not-yet-executed"})

LATER = [
  {"milestone": "M2", "strata": "short/long durations, rates, shared-clock, unequal starts, affine/nonlinear drift, discontinuities, acoustic-delay negatives, noise/silence/bleed/overlap", "issues": ["WW-015 (#10)","WW-016 (#15)","WW-017 (#11)","WW-018 (#13)"]},
  {"milestone": "M2", "strata": "import priming/padding/rate/channel/codec cases", "issues": ["WW-050 (#45)","WW-020 (#19)"]},
  {"milestone": "M3", "strata": "English native/Whisper timing/provisioning/offline", "issues": ["WW-026 (#23)","WW-027 (#21)"]},
  {"milestone": "M3", "strata": "common-map shortening, mode changes, partial inverses, occurrences, crossfades, protected speech", "issues": ["WW-028 (#25)","WW-043 (#40)","WW-045 (#41)"]},
  {"milestone": "M3", "strata": "review keyboard/VoiceOver", "issues": ["WW-029 (#26)","WW-044 (#48)"]},
  {"milestone": "M4", "strata": "neutral stems/record/restoration and listening", "issues": ["WW-036 (#34)","WW-038 (#33)","WW-040 (#37)"]},
]

FROZEN_CLASSES = ("authorized-synthetic", "authorized-user-grant")
FREEZE_BASE = "7087aa33b07b805defa024bdc3af1aa8e975b7ed"
FREEZE = {
  "freezeID": "m1-freeze-1",
  "date": "2026-10-05",
  "recordedBy": "Lead (WW-003 protocol author), at the M1 coordinator's direction",
  "baseCommit": FREEZE_BASE,
  "baseCommitNote": "main at the time this freeze was authored (merge of PR #60). The freeze takes effect at the merge commit of the PR that adds this record.",
  "scope": "Every entry whose permission class is authorized-synthetic or authorized-user-grant: ID, generator recipe, expected truth, split (calibration/holdout counts and unit), gate values and supported-claim limits exactly as written in this registry. Not-authorized entries are frozen only after exact consent is relayed. M1-USER-001 is a manual, non-statistical validation and is not frozen.",
  "gateChanges": "None. Gate values, truth definitions and per-entry counts are unchanged from the protocol merged in PR #51 (m1-fixtures-v2-draft). The only registry change is the addition of M1-SRC-ON-002-REVIEW, which already ran on main.",
  "deviation": "RETROACTIVE FREEZE. The protocol was defined at the PR #51 merge but was not frozen before execution. Runs reported in PRs #54, #56, #57, #58 and #60 were made from the seeded registry derivation without a dated freeze record, so they are labelled PRE-FREEZE and are retained unchanged, never relabelled as holdout.",
  "preFreezeExecutions": [
    {"pr": "https://github.com/brandonmartinez/WaveWrangler/pull/54", "families": "M1-REF-001..017, M1-SRC-OFF-001, M1-SRC-ON-001/002, M1-SRC-ON-002-REVIEW (lifecycle matrix); M1-SRC-ON-PROV-001 (iCloud trial, grant C)"},
    {"pr": "https://github.com/brandonmartinez/WaveWrangler/pull/58", "families": "lifecycle matrix re-runs incl. M1-REF-015 stall variants"},
    {"pr": "https://github.com/brandonmartinez/WaveWrangler/pull/56", "families": "M1-DUR-* (fault-injection harness, process kills, two-process conflicts, timings), M1-DUR-024 (iCloud trial, grant C), M1-DUR-026 native autosave XCUITests (grant A)"},
    {"pr": "https://github.com/brandonmartinez/WaveWrangler/pull/57", "families": "M1-SCALE-001 model-level timings; M1-A11Y-001 partial XCUITest keyboard flows and audits (grant A)"},
    {"pr": "https://github.com/brandonmartinez/WaveWrangler/pull/60", "families": "library regrant/schema 2 tests within M1-DUR-019/022/023/029 strata"},
  ],
  "postFreezeRule": "A run counts as post-freeze holdout only when it executes on a commit that contains this freeze record's merge commit, and is reported with commit SHA, host, every case (including failures and exclusions) and actual counts. Harness counts may exceed the frozen holdout minimums; they never fall below them. The frozen definition is the registry recipe, expected truth, split and gate; harness code that implements that definition at the frozen counts (for example new loops or parameterized tests) does not change it, and each post-freeze run reports the git tree IDs of the test trees it ran. A change to a frozen recipe, truth, count or gate requires a new dated freeze revision with fresh holdout; the earlier run is retained. Pre-freeze runs serve as the calibration record; post-freeze runs report holdout only (any extra calibration is reported separately and never tunes gates or truth).",
  "generatorSourceTreesAtBase": {
    "note": "git tree object IDs at baseCommit (verify with: git rev-parse <baseCommit>:<path>): the pre-freeze harness. Post-freeze runs report the tree IDs they actually ran.",
    "Packages/WaveWranglerKit/Tests/WWSourcesTests": "b8698a4f4889dd83c9c4e20a7852a18093765e29",
    "Packages/WaveWranglerKit/Tests/WWPersistenceTests": "11be08b1ed2bed02eff235375c5693255739e284",
    "Packages/WaveWranglerKit/Sources/WWPersistenceProbe": "fd55f678056943dd946b7f9440c0a6653c9cd6f5",
    "Packages/WaveWranglerKit/Tests/WWOrganizerTests": "ba48e1362e460df541df75459ca0b44b224a9997",
    "Packages/WaveWranglerKit/Tests/WWCoreTests": "20280f521d55436e41b5f7906ad280c042ff03f3",
    "WaveWranglerTests": "7e1d35b09de7b68ec61289a4c75ba7e50837c301",
    "WaveWranglerUITests": "d24d20620b51b9e9b112c318c827f4c61107d011",
  },
  "familyGenerators": {
    "durability": ["Packages/WaveWranglerKit/Tests/WWPersistenceTests", "Packages/WaveWranglerKit/Sources/WWPersistenceProbe", "WaveWranglerUITests (M1-DUR-026)"],
    "reference": ["Packages/WaveWranglerKit/Tests/WWSourcesTests", "WaveWranglerUITests (M1-REF-020)"],
    "organization": ["Packages/WaveWranglerKit/Tests/WWSourcesTests", "Packages/WaveWranglerKit/Tests/WWCoreTests"],
    "source-availability": ["Packages/WaveWranglerKit/Tests/WWSourcesTests"],
    "scale": ["Packages/WaveWranglerKit/Tests/WWOrganizerTests", "Packages/WaveWranglerKit/Tests/WWPersistenceTests"],
    "accessibility": ["WaveWranglerUITests", "Packages/WaveWranglerKit/Tests/WWOrganizerTests"],
  },
  "host": "macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, 18-core Apple silicon, 128 GiB -- claimed internal host, not the macOS 26/16 GB reference",
}
FROZEN_STATUS = "frozen m1-freeze-1 (2026-10-05); post-freeze holdout not yet reported in this registry"
FROZEN2_IDS = ()
FROZEN2_STATUS = "frozen m1-freeze-2 (2026-10-05); post-freeze holdout not yet reported in this registry"
FROZEN3_IDS = ()
FROZEN3_STATUS = "frozen m1-freeze-3 (2026-10-05); the m1-freeze-2 holdout FAILED (95/100) and is retained; m1-freeze-3 holdout not yet reported in this registry"
FREEZE2 = {
  "freezeID": "m1-freeze-2",
  "date": "2026-10-05",
  "recordedBy": "Lead (WW-003 protocol author), authorized by the M1 coordinator after the user's grant E",
  "baseCommit": "251d122dc8db378de92a4c15bc12069410864132",
  "baseCommitNote": "main when this revision was authored. It takes effect at the merge commit of the PR that adds it. It is made before any HOLDOUT execution of M1-DUR-025. Disclosed: a development smoke run of the two-host harness (1 case per cell, synthetic, not calibration and not holdout, not counted) ran while this freeze was in review; it found P0 #117 (an iCloud library conflict version left unsurfaced), which led to the explicit detection-mechanism truth above. Truth was tightened, never loosened, and counts are unchanged.",
  "scope": "M1-DUR-025 only: recipe, cells, expected truth, split (10 calibration / 100 holdout by cell), gate and supported-claim limits exactly as written in its registry entry. Every m1-freeze-1 entry is unchanged.",
  "trigger": "User grant E (2026-10-05): multi-device iCloud testing on this Mac and the Mac mini; UI stays on the Mac mini.",
  "postFreezeRule": "Same as m1-freeze-1: a holdout run counts only on a clean commit containing this revision's merge, runs once, reports every case (including failures, timeouts and exclusions) with both hosts' labels (sw_vers, hardware, Xcode), the commit SHA and the git tree IDs of the harness trees it ran on each host. Calibration may run before or after the merge and is reported separately; it never tunes truth, counts or gates. Changing the recipe, truth, counts or gate needs a new dated freeze revision.",
  "generatorSourceTrees": "Not yet written at freeze time (the persistence lane builds the two-host headless harness against this definition); each run record reports its tree IDs.",
}
FROZEN4_IDS = ("M1-DUR-025",)
FROZEN4_STATUS = "frozen m1-freeze-4 (2026-10-05); m1-freeze-2 holdout FAILED (95/100) and is retained; no m1-freeze-3 or m1-freeze-4 calibration or holdout has run; holdout not yet reported in this registry"
FREEZE3 = {
  "freezeID": "m1-freeze-3",
  "date": "2026-10-05",
  "recordedBy": "Lead (WW-003 protocol author), authorized by the M1 coordinator",
  "baseCommit": "6e35da201a4ab151e793e8aaee0da63e08ba3071",
  "baseCommitNote": "main when this revision was authored. It takes effect at the merge commit of the PR that adds it, and is made before any m1-freeze-3 calibration or holdout run.",
  "scope": "M1-DUR-025 only (supersedes m1-freeze-2 for that entry). Counts and cells unchanged (10 calibration / 100 holdout; show 3/30, library 3/30, relink 2/20, recovery 2/20). Truths unchanged or tighter: the protocol §4.2.1 interpretation is folded into truth 1; per-host level sampling while holding a conflict; concurrent Combine and staggered (app-level base-check) variants exercised; Combine-summary honesty (#131). Recipe additions (persistence-lane numbers accepted by Lead): frozen setup preconditions (420 s, then a download request and one more 420 s) with diagnostics, reserve-seed replacement capped at 20% per cell, one case in setup at a time across all cells (at most 6 product workers), a library ordering gate so host B is sampled while holding the conflict, a bounded concurrent-Combine termination rule (at most 3 rounds, 600 s each), complete pseudonymous host labels (no hostname) including `xcodebuild -version`, the SDK version and matching probe hashes, setupNotEstablished reserved for a not-arrived fixture with named first product operations and both-host diagnostics, §4.2.1 condition 5 reporting retained, fresh f3 seed splits, and calibration coverage of every new path plus a forced setup-stall drill. Every other entry is unchanged.",
  "supersededResult": {
    "freeze": "m1-freeze-2",
    "result": "FAILED (retained, not re-labelled): holdout ran once at 8456bcd (contains ad9af5a, ce1eb23, e0ac452, d1aeb9f): show-conflict 30/30, library-conflict 30/30, cross-machine-relink 15/20, recovery 20/20 = 95/100.",
    "reason": "Relink cases 61-65 failed in setup: a third generated source file never reached host B with the expected digest within 3 x 420 s while those 5 cases set up concurrently with other cells; no product truth was evaluated in them; cause not determined. Independent review of the evidence (PR #128) also found: host B's library level was not sampled while B held an unresolved conflict version (§4.2.1 condition 4 not evidenced on B), the run record lacked `xcodebuild -version`, concurrent Combine and the show app-level base-check path were not exercised, and P1 #131 (the Combine message reports an ST-36-kept reorder as not carried).",
    "evidence": "https://github.com/brandonmartinez/WaveWrangler/pull/128",
  },
  "postFreezeRule": "As m1-freeze-2: a holdout run counts only on a clean commit containing this revision's merge, runs once, and reports every case (including failures, timeouts, setupNotEstablished and reserve replacements) with complete host labels for both hosts, the commit SHA and harness tree IDs. Calibration ('calibration-f3') is reported separately and never tunes truth, counts or gates. A further change needs a new dated freeze revision; the m1-freeze-2 result stays recorded as failed.",
}
DEFERRED_IDS = ("M1-DUR-025",)
DEFERRED_STATUS = "deferred by user to #146 (post-M4); definition frozen at m1-freeze-4 (unchanged); holdouts retained as FAILED: m1-freeze-2 95/100 (relink setup stalls; reported in #128, docs/m1/evidence/dur025-two-device.md), m1-freeze-4 99/100 (show case 15 exceeded the 420 s settle bound; reported in #144, docs/m1/evidence/dur025-freeze4-holdout.md); live two-Mac tests disabled, simulated unit tests kept"
USER_DEFERRAL = {
  "date": "2026-10-05",
  "entry": "M1-DUR-025",
  "decision": "User scope decision, 2026-10-05 23:10, relayed verbatim by the M1 coordinator: \"let's move finishing the icloud sync discrepancy to after M4. That's a nice feature, but for initial MVP it's overkill. Unless it's blocking, don't remove any protections that are currently in place, but let's disable the tests for them.\" Follow-up (relayed): disable only the two-Mac / live-iCloud tests; keep the fast simulated unit tests.",
  "receivingIssue": "https://github.com/brandonmartinez/WaveWrangler/issues/146",
  "milestone": "Future - Optional extensions (after M4)",
  "effect": "Status and evidence only. The M1-DUR-025 definition (recipe, truth, split, gate) stays as frozen by m1-freeze-4 and is not a new freeze revision; nothing is relabelled. The m1-freeze-2 (95/100; reported in #128, docs/m1/evidence/dur025-two-device.md) and m1-freeze-4 (99/100; reported in #144, docs/m1/evidence/dur025-freeze4-holdout.md) holdout results stay recorded as FAILED. The withdrawn m1-freeze-5 proposal (PR #145, closed unmerged) never took effect. Product protections (provider-conflict detection, L4 -> Combine, backup-before-resolve, notices, honest status) stay in place; their simulated unit tests stay enabled in scripts/test.sh and CI. Any future qualification under #146 needs a new dated freeze revision before its holdout.",
  "recordedBy": "Lead (WW-003 protocol author); Lead has not seen the user's original message",
}
FREEZE4 = {
  "freezeID": "m1-freeze-4",
  "date": "2026-10-05",
  "recordedBy": "Lead (WW-003 protocol author), at the M1 coordinator's request, on harness-feasibility points raised by the persistence lane",
  "baseCommit": "d55f9924b92e69b72ded627b34d9193f91c8b37a",
  "baseCommitNote": "main when this revision was authored (the m1-freeze-3 merge). It takes effect at the merge commit of the PR that adds it, and is made before any m1-freeze-3 or m1-freeze-4 calibration or holdout run (none has run).",
  "scope": "M1-DUR-025 only; supersedes m1-freeze-3 for exactly the fields in recipeFreeze4. Everything else in m1-freeze-3 (counts 10/100 and cells, variants, setup preconditions, 20% cap, first product operations, host labels, seeds, per-case reporting, all other truths) is unchanged. Every other registry entry is unchanged.",
  "whyFreezeNotInterpretation": "Lead judgement: the m1-freeze-3 level-sampling FAIL rule, read literally, fails correct product behaviour in a real timing window: after host A's Combine, host B can receive the combined current library before the provider propagates resolution of a version whose content it already contains, and a read-only sample cannot resolve it. Replacing that FAIL predicate with a narrower one is a change to frozen gate text, not an interpretation, so it is frozen here before any run rather than recorded as a note. The new predicate exempts only objectively decidable, provably included versions (both the product's recorded-fork-base judgement and an independent harness judgement); undecodable, different-library, base-less or not-provably-included versions are never exempt; and the literal-reading count is reported alongside. The exemption is scoped by truth1LibraryClause (in-window only; at settle every unresolved version must be resolved with a backup or surfaced) and uses an independent harness judgement that never reuses product merge code. The other six items (Combine summary check, host-B tree IDs, uncounted split names, drill mechanism, variant assignment, combineOnAThenB rounds) fill gaps in m1-freeze-3 text and are frozen in the same revision for clarity; each is equal to or stricter than m1-freeze-3.",
  "postFreezeRule": "As m1-freeze-3; a run counts only on a clean commit containing this revision's merge.",
}
FROZEN5_IDS = ("M1-REF-020",)
FROZEN5_STATUS = "frozen m1-freeze-5 (2026-10-05; definition unchanged from m1-freeze-1); the m1-freeze-1 holdout FAILED as short and is retained: 16/20 scenarios executed at 08f62ee (12 pass, 4 fail, 4 not executed; all failures and the abort were harness defects; 0 product failures; reported in PR #111, docs/m1/evidence/ww-007-accessibility-responsiveness.md section 2.3); m1-freeze-5 holdout not yet reported in this registry"
FREEZE5 = {
  "freezeID": "m1-freeze-5",
  "date": "2026-10-05",
  "recordedBy": "Lead (WW-003 protocol author), at the M1 coordinator's request after the user's decision of 2026-10-05 23:30 (relayed): finish the remaining M1 evidence runs before closing",
  "baseCommit": "73119505883fb3a573dced19fd28c287e154da20",
  "baseCommitNote": "main when this revision was re-pinned (the #157 merge). It contains the final REF-020 harness from PR #152 (8526737). It takes effect at the merge commit of the PR that adds it, and is made before any m1-freeze-5 run of M1-REF-020. First drafted at 270b00b, then held at the coordinator's direction until the harness was finalized; the harness was finalized before this freeze.",
  "nameNote": "The ID m1-freeze-5 was first used by a DUR-025 proposal (PR #145), which was closed unmerged and never took effect. This revision reuses the ID for M1-REF-020 only; it has no relation to DUR-025, which stays user-deferred to #146.",
  "scope": "M1-REF-020 only. Its recipe, expected truth, split (2 calibration / 20 holdout GUI scenarios = 5 cycles x grant, relaunch, regrant, relink), gate and supported-claim limits are unchanged from m1-freeze-1. Every other registry entry, freeze revision and deferral is unchanged.",
  "trigger": "The m1-freeze-1 holdout ran once at 08f62ee and executed only 16 of 20 scenarios: 12 pass and 4 fail on a harness row-selection defect, and cycle 5 aborted on a harness defect (4 not executed). No product failure was observed. Follow-up #151.",
  "retainedResult": {
    "freeze": "m1-freeze-1",
    "result": "FAILED (short; retained, not re-labelled): 16/20 executed at 08f62ee; grant 4/4, relaunch 4/4, regrant 2/4, relink 2/4 = 12 pass, 4 fail; 4 not executed.",
    "evidence": "https://github.com/brandonmartinez/WaveWrangler/pull/111 (docs/m1/evidence/ww-007-accessibility-responsiveness.md section 2.3)",
    "laterExecutionsNotCounted": "The post-correction and Mac mini re-executions (241396a, 4a109aa, 9e994b1, and the labelled 20/20 at 550506d) ran before this revision. They are supporting evidence only and are not holdout results.",
  },
  "harness": {
    "test": "WaveWranglerUITests/SourceGrantHoldoutUITests.swift testGrantRelaunchRegrantRelink, with TEST_RUNNER_WW_FIXTURE_SPLIT=holdout and TEST_RUNNER_WW_HOLDOUT_SCENARIOS=20 (5 cycles) and WW_PROBE set (scripts/test.sh --ui path). The harness itself fails a holdout run whose count isn't exactly 20, and fails if fewer than 20 scenarios were executed.",
    "finalizedBeforeFreeze": "Coordinator decision (2026-10-05): extend the harness to cover the full frozen recipe rather than narrow the freeze. PR #152 (merged 8526737, before this revision) does that. Each cycle's grant scenario selects sources (read-only) and a library folder (read-write, Settings > Library location > Choose Folder... > Move Library) through the sandboxed panels. The relaunch scenario resolves the library from that folder, reopens the show from the library, edits it and saves it with Cmd-S, with a disk read-back. Fixture bytes and the show document come from the registry seed derivation, one case per GUI scenario: cycle c covers case indices 4c..4c+3; the show uses seed(4c), and the sources use seed(4c+1) and seed(4c+2).",
    "fixesSinceFirstHoldout": "launch once for documents (app.launchOnce(opening:), PR #135, ade082f) instead of launch() + open(), which spawned two app processes; the show window found by accessibility identifier (ww.show.window), not its changing title; source rows selected by clicking at several horizontal offsets until selected, with a row predicate; Setup Name cells matched on label or value; UI-test storage and preferences reset before each test class (PR #166). These change how the harness drives the GUI and which fixture it uses, not what the frozen truth checks.",
    "pinnedAtBase": {
      "WaveWranglerUITests/SourceGrantHoldoutUITests.swift": "d1bb41238ca26544e9b7945b29b1eda51949d4bc",
      "WaveWranglerUITests/AcceptanceSupport.swift": "b2d87c3e843a6b3d6c0d267acd67319439021aa1",
      "WaveWranglerUITests/UITestIsolation.swift": "20c7ae150abaa2084a0896952f1574790c30a2ba",
      "WaveWranglerUITests (tree)": "9afecfa4979dfc529cafd9f38b2ad3f4d85eedab",
    },
    "pinNote": "git object IDs at baseCommit (verify with: git rev-parse 7311950:<path>). The three harness files above are the binding pin: the run reports their blob IDs, and any difference fails the pin unless a new dated revision is made first. The whole-directory tree ID is informational, because unrelated UI test classes may merge before the run; the run reports the tree it actually ran.",
  },
  "host": "The user's Mac mini (Apple M2 Pro, 12 cores, 32 GiB, macOS 27.0.1) under grant A and the standing Mac mini UI consent: build-for-testing on this Mac, test-without-building on the mini, one GUI run under the coordinator's GUI lock. The run record labels the host (sw_vers, hardware, Xcode).",
  "postFreezeRule": "The holdout runs ONCE, on a clean commit that contains this revision's merge, and is recorded as-is: every scenario (pass, fail, not executed, abort) with its cycle, the commit SHA, the harness tree ID, the host label and the source SHA-256 and mtime checks, in docs/m1/evidence and this registry. A harness failure or abort is a FAILED scenario (no re-run, no replacement, no exclusion). Calibration (2 scenarios) may run before the holdout and is reported separately; it never tunes truth, counts or gates. Any further change needs a new dated revision before a further run.",
}

def build():
    for f in F:
        if f["id"] in DEFERRED_IDS and f["evidenceStatus"] == "not-yet-executed":
            f["evidenceStatus"] = DEFERRED_STATUS
            f["userDeferral"] = USER_DEFERRAL
    for f in F:
        if f["id"] in FROZEN5_IDS and f["evidenceStatus"] == "not-yet-executed":
            f["evidenceStatus"] = FROZEN5_STATUS
        elif f["id"] in FROZEN4_IDS and f["evidenceStatus"] == "not-yet-executed":
            f["evidenceStatus"] = FROZEN4_STATUS
        elif f["id"] in FROZEN3_IDS and f["evidenceStatus"] == "not-yet-executed":
            f["evidenceStatus"] = FROZEN3_STATUS
        elif f["id"] in FROZEN2_IDS and f["evidenceStatus"] == "not-yet-executed":
            f["evidenceStatus"] = FROZEN2_STATUS
        elif f["permission"]["class"] in FROZEN_CLASSES and f["evidenceStatus"] == "not-yet-executed":
            f["evidenceStatus"] = FROZEN_STATUS
        elif f["id"] == "M1-USER-001":
            f["evidenceStatus"] = "manual; not frozen (non-statistical); not yet reported in this registry"
    ids = [f["id"] for f in F]
    assert len(ids) == len(set(ids)), "duplicate ids"
    for f in F:
        for k in ["id","stratum","generator","expectedTruth","permission","provenance","split","supportedClaimLimits"]:
            assert f.get(k) not in (None, ""), (f["id"], k)
    by_class = collections.Counter(f["permission"]["class"] for f in F)
    def tot(cls, key):
        return sum(f["split"][key] for f in F if f["permission"]["class"] == cls)
    counts = {
      "entries": len(F),
      "byPermissionClass": dict(sorted(by_class.items())),
      "consentBlockedEntries": sum(1 for f in F if f["evidenceStatus"] == "consent-blocked"),
      "consentBlockedVariants": sum(1 for f in F for v in f.get("variants", []) if v.get("evidenceStatus") == "consent-blocked"),
      "authorizedSynthetic": {"calibration": tot("authorized-synthetic","calibration"), "holdout": tot("authorized-synthetic","holdout")},
      "authorizedUserGrant": {"calibration": tot("authorized-user-grant","calibration"), "holdout": tot("authorized-user-grant","holdout")},
      "ww006LifecycleHoldout": sum(f["split"]["holdout"] for f in F if f.get("countsToward")),
      "showPublicationBoundaries": len(P), "libraryPublicationBoundaries": len(L),
      "perBoundaryHoldoutMinimum": 100,
      "frozenEntries": sum(1 for f in F if f["evidenceStatus"] in (FROZEN_STATUS, FROZEN2_STATUS, FROZEN3_STATUS, FROZEN4_STATUS, FROZEN5_STATUS, DEFERRED_STATUS)),
      "frozenEntriesByRevision": {"m1-freeze-1": sum(1 for f in F if f["evidenceStatus"] == FROZEN_STATUS), "m1-freeze-2": sum(1 for f in F if f["evidenceStatus"] == FROZEN2_STATUS), "m1-freeze-3": sum(1 for f in F if f["evidenceStatus"] == FROZEN3_STATUS), "m1-freeze-4": sum(1 for f in F if f["evidenceStatus"] == FROZEN4_STATUS), "m1-freeze-5": sum(1 for f in F if f["evidenceStatus"] == FROZEN5_STATUS), "m1-freeze-4, deferred by user to #146": sum(1 for f in F if f["evidenceStatus"] == DEFERRED_STATUS)},
    }
    assert all(f["evidenceStatus"] in (FROZEN_STATUS, FROZEN2_STATUS, FROZEN3_STATUS, FROZEN4_STATUS, FROZEN5_STATUS, DEFERRED_STATUS) for f in F if f["permission"]["class"] in FROZEN_CLASSES), "unfrozen authorized entry"
    r20 = next(f for f in F if f["id"] == "M1-REF-020")
    assert r20["split"] == {"calibration": 2, "holdout": 20, "unit": "GUI scenarios"}, "REF-020 counts unchanged"
    d25 = next(f for f in F if f["id"] == "M1-DUR-025")
    for c in d25["cells"]:
        if "variantsFreeze3" in c:
            assert sum(v for k, v in c["variantsFreeze3"].items() if isinstance(v, int)) == c["holdout"], ("DUR-025 variants", c["cell"])
    assert d25["split"]["calibration"] >= 10 and d25["split"]["holdout"] >= 100, "DUR-025 counts never lowered"
    assert sum(c["holdout"] for c in d25["cells"]) == d25["split"]["holdout"] and sum(c["calibration"] for c in d25["cells"]) == d25["split"]["calibration"], "DUR-025 cells"
    assert counts["ww006LifecycleHoldout"] >= 1000, counts
    for f in F:
        if "perBoundary" in f:
            assert f["perBoundary"]["holdout"] >= 100, f["id"]
    d6 = next(f for f in F if f["id"] == "M1-DUR-006")
    assert d6["split"]["holdout"] == 100 * sum(len(b["paths"]) for b in P), "DUR-006 cells"
    return {
     "registryVersion": "m1-fixtures-v7-frozen5-ref020",
     "date": "2026-10-05",
     "generatedBy": "docs/m1/fixtures/generate-registry.py (do not hand-edit; regenerate)",
     "owner": "Lead (protocol); WW-003 informational owner Pipeline",
     "issue": "https://github.com/brandonmartinez/WaveWrangler/issues/5",
     "protocol": "docs/m1/ww-003-fixture-protocol.md",
     "status": "FROZEN 2026-10-05 (m1-freeze-1, retroactive; M1-DUR-025: m1-freeze-2 FAILED 95/100 and m1-freeze-4 FAILED 99/100, both retained; M1-DUR-025 deferred by user to #146, post-M4; M1-REF-020: m1-freeze-1 holdout FAILED short 16/20, retained, re-frozen unchanged as m1-freeze-5 for one run with the fixed harness) / PRE-FREEZE RUNS DISCLOSED / POST-FREEZE HOLDOUT REPORTED IN docs/m1/evidence/",
     "freezeRule": "Each family is frozen (generator source hash, recipe, truth, counts, gate) in a dated freeze record before its first holdout case runs. Counts may increase before freeze; never decrease below a frozen gate minimum without explicit Lead/Brandon approval.",
     "freeze": FREEZE,
     "freezeRevisions": [FREEZE2, FREEZE3, FREEZE4, FREEZE5],
     "userDeferrals": [USER_DEFERRAL],
     "seedDerivation": SEED,
     "claimedHost": "macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), 18-core Apple silicon, 128 GiB -- not the macOS 26/16 GB reference",
     "userGrants20261004": GRANT,
     "userGrants20261005": GRANT_20261005,
     "stillBlocked": ["OneDrive", "Dropbox", "disk-image (real full-volume) tests", "network disconnection"],
     "permissionClasses": {
       "authorized-synthetic": "Generated deterministic data in temp dirs; authorized by the pasted M1 kickoff.",
       "authorized-user-grant": "Synthetic data exercised through a user grant of 2026-10-04 (A-D) relayed by the M1 coordinator, within its exact scope.",
       "consent-relayed-manual": "Specific user consent relayed by the M1 coordinator; manual use within stated scope only.",
       "not-authorized": "Not granted; exact user consent required."},
     "showPublicationBoundaries": P,
     "libraryPublicationBoundaries": L,
     "nsdocumentPathCoverage": NSDOC_NOTE,
     "counts": counts,
     "fixtures": F,
     "laterMilestonePointers": {"note": "Pointers only; NOT M1 obligations. Qualification remains in each domain issue.", "items": LATER},
    }

def render(reg):
    return json.dumps(reg, indent=2, ensure_ascii=False) + "\n"

if __name__ == "__main__":
    reg = build(); text = render(reg)
    if "--check" in sys.argv[1:]:
        current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if current != text:
            print("m1-fixture-registry.json is out of date; regenerate.", file=sys.stderr); sys.exit(1)
        print("registry up to date")
    else:
        open(OUT, "w", encoding="utf-8").write(text)
    print(json.dumps(reg["counts"], indent=1))
