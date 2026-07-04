# Pill + app-lifecycle redesign

Two changes John asked for, with reference screenshots: (A) make wispr-local a normal openable/closable app, and (B) redesign the pill — tiny by default, expanding into a ✕ / waveform / ✓ control while recording.

## A. Openable / closable app
- Today the app is a menubar-only agent (`LSUIElement = true`, no dock icon). Change it to a **regular app**: dock icon, appears in the app switcher, can be opened and quit normally.
- **Open** (launch, or click the dock icon / reopen) → shows the **History window** as the main window. Implement `applicationShouldHandleReopen` so clicking the dock icon re-shows History if it was closed.
- **Close the History window → the app KEEPS RUNNING** (the floating pill and menubar stay). Do NOT quit on last-window-close. `⌘Q` quits fully.
- Keep the menubar item as a secondary entry point (Open History, Settings, Quit). The floating pill stays visible whenever the app runs.
- Net: a normal app you can open and close, that also keeps the always-available pill alive in the background until you actually Quit.

## B. Pill redesign

### Idle (default) — TINY
- Much smaller than the current 120×26. Target roughly **60×20** (tune, but distinctly small/unobtrusive). Just the 4 faint dots, centered, in the translucent capsule. Click anywhere on it to start recording.

### Active (recording) — expands to a control
Matches the reference: the pill grows to show three regions, left→right:
- **✕ Cancel** button (left): a subtle dark circle with a white ✕. Action = **cancel**: stop and DISCARD the recording — no ASR, no cleanup, no inject, no history entry — return to tiny idle.
- **Live waveform** (center): the existing RMS level meter bars.
- **✓ Confirm** button (right): a prominent white circle with a dark checkmark. Action = **confirm**: the current stop-and-process path (stop → ASR → cleanup → paste → persist), then return to tiny idle.
- Size: wide enough for the two buttons + meter, e.g. **~150×32**. Smooth expand/contract animation between idle and active.

### Processing
- After ✓, show the existing processing sweep (in the expanded shape is fine), then collapse back to the tiny idle pill.

### Coordinator changes
- Add `cancel()`: discard the in-progress recording, tear down the meter, no ASR/inject/persist, phase → idle. (Today there's only start + stopAndProcess.)
- ✓ maps to the existing stop-and-process; the idle-pill click maps to start.

### Click handling (the risk area — same first-mouse lesson)
- The pill is in a non-activating panel; the hosting view already overrides `acceptsFirstMouse`. But there are now THREE hit targets (✕, center, ✓) instead of one whole-pill gesture.
- Prefer SwiftUI `Button`s for ✕ and ✓ — with `acceptsFirstMouse` true on the hosting view they should receive first-mouse clicks; **verify a real click on each button registers** (not just a synthetic CGEvent — that was the false-pass trap last time).
- If SwiftUI buttons don't reliably get first-mouse in the non-activating panel, fall back to location-based hit-testing inside the click gesture (left circle = cancel, right circle = confirm, else ignore). Whichever you choose, real clicks on ✕ and ✓ must work, and clicking must NOT steal focus from the target app (re-verify focus is not stolen).

## Non-regression
- The full dictation loop, meter, history, context-cleanup, and settings must all keep working.
- Focus-not-stolen behavior must survive the new buttons.

## Verify / guardrails
- Build clean via `scripts/build.sh`. Screenshot the tiny idle pill and the expanded ✕/waveform/✓ active pill.
- Verify the cancel path discards (no new history entry) automatically if you can; the real button clicks + dock open/close are John's manual checklist.
- NO commit/push. Stay in `~/dev/wispr-local`. STOP and report if a piece can't be made to work.
- Report: build output, screenshots, what you verified, manual checklist, `git status --short`.
