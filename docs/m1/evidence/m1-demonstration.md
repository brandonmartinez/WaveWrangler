# M1 repeatable demonstration and consented manual validation

**Owner:** Mac · **Refs:** [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-006 (#1)](https://github.com/brandonmartinez/WaveWrangler/issues/1)

This document has two parts:

1. A **repeatable synthetic demonstration** of the M1 organizer, written as copyable keyboard and menu steps, with the result observed when Mac ran it end to end through computer-use automation.
2. A **consented manual validation** on a user-provided local disposable episode copy (path withheld). Only aggregate, generic observations are recorded here.

It is manual evidence for acceptance review. It doesn't replace the automated suites (`scripts/test.sh`), and it never claims evidence that wasn't observed: a step that wasn't run, or couldn't be observed, says so.

## 1. Run record

RUN_RECORD_PLACEHOLDER

## 2. Preparation (repeatable)

Run from the repository root. Everything the demonstration creates lives under `$TMPDIR` or in the consented iCloud trial folder, never in a repository.

```sh
scripts/build.sh                                   # Debug, ad-hoc signed; app at .build/DerivedData/Build/Products/Debug/WaveWrangler.app
scripts/demo/make-synthetic-episode.sh             # writes "$TMPDIR/ww-m1-demo" (refuses to overwrite or to write inside a Git tree)
scripts/demo/fs-manifest.py snapshot "$TMPDIR/ww-m1-demo/Synthetic Episode 1" "$TMPDIR/ww-m1-demo-before.json"
open .build/DerivedData/Build/Products/Debug/WaveWrangler.app
```

The generator writes **16 files**: **9 importable "recordings"** (random bytes with `.WAV`, `.m4a` and `.aif` extensions; nothing is decodable) in three recorder folders, plus **7 decoys** that must be skipped and never opened: a text note, a `.srt` transcript, a peak file (`.pk`), a `.logicx` project folder containing a `.wav`, a hidden file and a `.png`. It also creates an empty `Relink Target` folder.

| Folder | Files | Expected suggestion |
| --- | --- | --- |
| `Recorder A/ZOOM0001` | `ZOOM0001_Tr1.WAV`, `ZOOM0001_Tr2.WAV`, `ZOOM0001_LR.WAV` (+ decoy `ZOOM0001.pk`) | Group "Recorder A", epoch from take folder `ZOOM0001` |
| `Recorder A/ZOOM0002` | `ZOOM0002_Tr1.WAV`, `ZOOM0002_Tr2.WAV` | Group "Recorder A", epoch `ZOOM0002` |
| `Recorder B` | `Alpha mic.m4a`, `Bravo mic.m4a`, `Bravo backup.m4a` | Group "Recorder B"; speakers "Alpha", "Bravo"; "backup" suggests Backup |
| `Recorder C` | `Guest 1 iso.aif` | Group "Recorder C"; speaker "Guest 1" |

`scripts/demo/fs-manifest.py` records, for every entry, a SHA-256 of the relative path plus type, size, mtime, ctime and inode from `lstat`. It never opens or hashes file contents, and it prints only aggregate counts. `compare` exits 0 only when nothing was added, removed or changed.

## 3. Synthetic demonstration script and observed results

Notation: "Menu ›" means choosing the item from the menu bar (by keyboard: ⌃F2, or Help-menu search with ⌘?). K-numbers refer to the [keyboard-only flows](../design/commands-keyboard.md#8-keyboard-only-flows-for-core-tasks). Wording in quotes is the Design catalog wording the step expects.

DEMO_TABLE_PLACEHOLDER

## 4. Consented manual validation on a real episode copy

REAL_MEDIA_PLACEHOLDER

## 5. Issues

ISSUES_PLACEHOLDER

## 6. Limits

LIMITS_PLACEHOLDER
