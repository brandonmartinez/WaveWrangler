---
name: "kickoff-preflight"
description: "Use at the start of every WaveWrangler milestone (and again before each user away window) to check host readiness and collect every user-only action into ONE consolidated ask. Does NOT perform user-only actions (sudo, unlocking 1Password, toggling Full Keyboard Access) — agents record and ask."
domain: "orchestration, host readiness"
confidence: "medium"
---

# Kickoff preflight

M1 lost about 5 hours to host problems only the user could fix (Automation Mode expiry, a locked 1Password SSH agent, Computer Use not armed, an Xcode first-launch prompt) — `docs/planning/retrospectives/m1.md` §4. Check them all up front, record PASS/FAIL in the coordinator's first status, and ask the user once.

## Checklist

Run each check; record PASS / FAIL / NOT CHECKED (with reason) and the host.

| # | Check | How | If it fails |
|---|---|---|---|
| 1 | Xcode first launch on every build/GUI host | `xcodebuild -checkFirstLaunchStatus` → exit 0 | User runs `sudo xcodebuild -runFirstLaunch`. Never run it yourself |
| 2 | SSH to each GUI host | `source "$HOME/.shell/exports.sh"; ssh -o BatchMode=yes -o ConnectTimeout=8 <host> true`; `ssh-add -l` | "The agent has no identities" = 1Password locked/quit: user unlocks it. Check once; don't loop |
| 3 | Automation Mode without authentication on each GUI host | `automationmodetool` status over SSH | User runs `sudo automationmodetool enable-automationmode-without-authentication` |
| 4 | Clean GUI host | Unlocked, awake, no alerts/update prompts/banners, Focus/Do Not Disturb on; `pgrep -fl 'WaveWrangler|xctest'` empty; audited windows on the primary display | User clears prompts / enables Focus |
| 5 | Computer Use armed | A `get_window_state` probe on the GUI host before scheduling any computer-use step | User grants Accessibility and Screen Recording / restarts the helper |
| 6 | Full Keyboard Access state | `defaults read -g AppleKeyboardUIMode` on each host — **record only**, agents never toggle it | — |
| 7 | GUI lock | `~/ww-uitest-runs/gui-lock status` on each GUI host: no holder, empty queue, no stale `.gui.lock` | Coordinator moves a stale lock aside (logged) |
| 8 | Toolchain matrix | Note CI (macos-26, Xcode 26.6 / SDK 26.5) vs hosts (macOS 27, Xcode 27) | — |
| 9 | Consents for the milestone | Compare the kickoff's consent list with what the milestone's acceptance needs (media, models, listeners, provider trials) | Include the exact scope ask in the consolidated message |
| 10 | Away windows | Ask the user for their away windows | — |

## Consolidated ask

- One message for every user-only item (consents, sudo steps, unlocks, manual checks), each with exact scope, destination and consequence.
- Before each stated away window, send one more consolidated message with everything pending.
- Through a relay session: purpose `needs_input`, batched. Never send progress chatter.
- Meanwhile continue all work that needs neither the user nor the blocked host.
