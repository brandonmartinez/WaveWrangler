# M1 interaction and accessibility specification

**Owner:** Design (Squad). **Milestone:** [M1 — Durable organizer](https://github.com/brandonmartinez/WaveWrangler/milestone/1). **Status:** specification only, for Mac UI implementation. It is **not implemented, executed or user-tested**. **Refs:** [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12).

This spec evolves the documentary [WW-004 specification](../../research/foundation-spikes.md#ww-004-documentary-native-m1-specification) (18/18 documentary tasks) into concrete, testable M1 interaction design for an AppKit `NSDocument` app that hosts SwiftUI views on macOS 26+.

| Document | Contents |
| --- | --- |
| [information-architecture.md](information-architecture.md) | Vocabulary, window/document model, Library window, show window, sidebar, destinations (later ones gated with reasons), inspector, Import Review, status placement, accessibility identifiers, scale, restoration |
| [states-and-recovery.md](states-and-recovery.md) | Exact wording, symbols, VoiceOver values and remedies for 16 document save states; five independent source dimensions; relink/regrant; library reconciliation; source download On/Off; announcements |
| [commands-keyboard.md](commands-keyboard.md) | Full menu bar, shortcut register, named undo, focus order, list keys, non-drag alternatives, context menus, Settings window, in-app text size, keyboard-only flows K01–K25 |
| [accessibility-acceptance.md](accessibility-acceptance.md) | Fixtures, cross-cutting conditions (keyboard, VoiceOver, 200% text, Increase Contrast, Reduce Motion, colour independence), automated vs manual checks, core task suite T01–T24 |
| [sources.md](sources.md) | Apple HIG and developer pages Design actually fetched on 2026-10-04 (A1–A33), plus failed fetches and unverified claims |

## Invariant trace

| Product invariant | Where the design enforces it |
| --- | --- |
| Originals immutable; path/name never identity; no silent substitution | IA §1 vocabulary; IA-14, IA-18; states §3.5, §4 (ST-20 – ST-23); commands §5–§6 wording ("file isn't changed or deleted") |
| Unknown/denied/missing/changed/unverified/residency/transfer stay distinct | states ST-01, §3.1–§3.6 (no "Offline" catch-all; denied ≠ missing); acceptance A-03, T12, T13 |
| Metadata-only/downloads-Off makes zero content requests | IA-14; states §6; acceptance A-08, T19 |
| Autosave On by default, configurable, explicit Save, no false "saved" | states §2, ST-10 – ST-14; commands §7; acceptance A-04, A-07, T14, T15, T23 |
| Cloud canonical documents: never assume atomicity, retain prior work, unknown-newer refuses edit/save/down-save | states D1 wording (local copy ≠ upload), D5–D11, D12/ST-14, §2.2, §2.3; acceptance T16, T17, T20, T21 |
| Source downloads On by default, configurable, honest progress/unknown/offline/cancel/retry | states §3.4, §6; commands Source menu; acceptance T18, T19 |
| Essential keyboard + VoiceOver, visible focus, non-drag/numeric alternatives, 200% text, contrast, reduced motion, accessible blocked reasons | commands CMD-01 – CMD-07, §4, §5, §8, CMD-20; IA-12/IA-13; acceptance §3, §5 |
| No decode/analysis/alignment/transcription in M1 | IA §4.2 blocked destinations state "hasn't read or analysed any audio"; identity is metadata-only (states §3.5) |

## Limits

- This is documentary design. Proof requires implementation plus the [acceptance suite](accessibility-acceptance.md). Running that suite **needs GUI/OS-setting permission, which is pending the user's answer**.
- The ⌃⌘S sidebar shortcut, AppKit announcement API naming, AX role names and a possible macOS system per-app text-size setting are marked **(unverified)**.
- SF Symbol names resolved on the macOS 27.0.1 host only. macOS 26 availability is an automated acceptance check (A-01).
- Provider-specific behaviour (pause support, provider-finished downloads, detection of a location as unavailable) depends on Mac's observations. The wording covers both outcomes and never asserts what Mac can't observe.
