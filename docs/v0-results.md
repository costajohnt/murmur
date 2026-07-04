# v0 spike results

Build agent run, 2026-07-04. All evidence lines quoted verbatim from `/tmp/wisprlocal.log`
(the app logs there in addition to stdout, since stdout is lost when launched via `open`).

## Build

`scripts/build.sh` (xcodegen generate + xcodebuild Debug) → `** BUILD SUCCEEDED **`.
App: `build/DerivedData/Build/Products/Debug/WisprLocal.app`.

Signing: `Apple Development` (manual), team `554J63A469`.
**Gotcha found:** the team ID is the certificate's OU (`554J63A469`), not the
`([redacted])` suffix in the cert CN — using the latter as `DEVELOPMENT_TEAM`
fails with `No signing certificate "Mac Development" found`. Documented in
`project.yml`.

Verified on the built app:

```
Identifier=com.costajohnt.wisprlocal
TeamIdentifier=554J63A469
(no com.apple.security.app-sandbox entitlement — App Sandbox OFF, as specced)
```

`Info.plist` contains `LSUIElement = true` and `NSMicrophoneUsageDescription`.

## Spike B — non-activating floating pill (PASS, automated)

Panel config per spec: `[.nonactivatingPanel, .borderless]`, `.statusBar` level,
`isFloatingPanel`, `hidesOnDeactivate = false`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`,
`canBecomeKey = false`, `canBecomeMain = false`. Pill sits bottom-center; its button
action logs `NSWorkspace.shared.frontmostApplication` at click time.

Automated test: TextEdit forced frontmost via System Events, then a **real CGEvent
mouse click** posted at the pill's screen coordinates. Repeated 4×:

```
before-click frontmost: com.apple.TextEdit
[2026-07-04T20:22:38Z] SPIKE B CLICK: frontmostApplication = com.apple.TextEdit (TextEdit)
[2026-07-04T20:22:52Z] SPIKE B CLICK: frontmostApplication = com.apple.TextEdit (TextEdit)
[2026-07-04T20:22:54Z] SPIKE B CLICK: frontmostApplication = com.apple.TextEdit (TextEdit)
[2026-07-04T20:22:56Z] SPIKE B CLICK: frontmostApplication = com.apple.TextEdit (TextEdit)
```

The click lands on the pill (the log line proves the button action fired) and the
frontmost app at click time stays TextEdit — WisprLocal never appears as frontmost.

One caveat observed while testing: `NSWorkspace.frontmostApplication` inside an idle
background app can be **stale at event-delivery time** (an early click reported the
previously-frontmost app until the run loop caught up). Not a focus-stealing issue —
but for v1, track `NSWorkspace.didActivateApplicationNotification` to know the
injection target instead of trusting a point-in-time read.

### acceptsFirstMouse fix (post-review)

John's real clicks did nothing even though the CGEvent-driven test fired. Root cause:
the panel never becomes key, so every human click is a **"first mouse"** event, and
AppKit drops it unless the hit view returns `acceptsFirstMouse == true`. Fixes applied:

- `PillHostingView` (an `NSHostingView` subclass) overrides
  `acceptsFirstMouse(for:) -> true` and is the panel's content view.
- The click is handled by an **AppKit `NSClickGestureRecognizer`** on the hosting
  view — the SwiftUI content is purely visual, so no SwiftUI `Button` competes for
  first-mouse. Single code path, no double-fire.
- Clicking now toggles an obvious visual state (see redesign below) instead of only
  writing to the log.

Re-verified after the fix (CGEvent clicks with TextEdit frontmost — the synthetic
path; the human first-click is on the manual checklist):

```
[2026-07-04T20:37:29Z] SPIKE B CLICK: frontmostApplication = com.apple.TextEdit (TextEdit) — pill state: listening
[2026-07-04T20:37:31Z] SPIKE B CLICK: frontmostApplication = com.apple.TextEdit (TextEdit) — pill state: idle
```

### Pill redesign (Wispr Flow lozenge)

- 120 × 26 capsule (`PillMetrics`), bottom-center, no icon, no text.
- Real behind-window blur: `NSVisualEffectView` (`.hudWindow`, `.behindWindow`,
  `.active`) clipped to the capsule, dark tint over it (lighter while listening),
  hairline white border.
- Idle: 4 equal faint dots. Listening (after a click): dots brighten to near-white
  and pulse in a staggered bounce; click again to return to idle.
- SwiftUI gotcha hit and fixed: `repeatForever` animations don't tear down when the
  driving value flips — dots froze mid-pulse back in idle. Idle and listening are
  now **separate view identities** (`StaticDots` / `PulsingDots`), so the animation
  is destroyed on toggle. Verified with before/during/after screenshots.

## Spike C — paste-inject (BLOCKED on TCC grant → manual)

Implemented per spec: clipboard snapshot (all items × all types) → set string →
CGEvent ⌘V (keycode 9 + `.maskCommand`, posted to `cghidEventTap`) → restore
clipboard after 1 s. Menu item arms a 3 s delay so you can focus the target app.

The code gates on `AXIsProcessTrusted()` and correctly refused without the grant:

```
[2026-07-04T20:23:44Z] SPIKE C FAILED: Accessibility permission not granted. Grant in System Settings > Privacy & Security > Accessibility, then retry.
```

Accessibility cannot be granted programmatically (TCC/SIP), so the actual paste is a
manual test (checklist below). The failed attempt also called
`AXIsProcessTrustedWithOptions(prompt)`, which registers WisprLocal in the
Accessibility pane. Clipboard sentinel was untouched by the refused attempt
(`CLIPBOARD-SENTINEL-BEFORE` still on the clipboard afterward) — the guard runs
before any pasteboard mutation.

## Spike A — FluidAudio ASR (PASS, automated)

Fixture: `Tests/fixtures/fixture.wav`, generated with
`say -o /tmp/fx.aiff "the quick brown fox jumps over the lazy dog"` +
`ffmpeg -y -i /tmp/fx.aiff -ar 16000 -ac 1 fixture.wav` (16 kHz mono Int16, 2.79 s),
bundled into the app as a resource. Model: Parakeet TDT 0.6b **v2** (English-only,
better recall per FluidAudio docs), `AsrModels.downloadAndLoad(version: .v2)`.

**Run 1 (cold — network download, expected):**

```
[2026-07-04T20:23:03Z] SPIKE A: loading Parakeet TDT v2 (English) — first run downloads the CoreML model from HuggingFace
[2026-07-04T20:26:16Z] SPIKE A: models loaded in 192.52s        ← ~460 MB download + CoreML/ANE compile
[2026-07-04T20:26:16Z] SPIKE A TRANSCRIPT (0.212s): "The quick brown fox jumps over the lazy dog."
[2026-07-04T20:26:16Z] SPIKE A: confidence = 0.988
```

**Run 2 (fresh app process, models from local cache — no download):**

```
[2026-07-04T20:26:33Z] WisprLocal launched (pid 52571)
[2026-07-04T20:26:37Z] SPIKE A: models loaded in 0.34s
[2026-07-04T20:26:37Z] SPIKE A TRANSCRIPT (0.171s): "The quick brown fox jumps over the lazy dog."
[2026-07-04T20:26:37Z] SPIKE A: confidence = 0.988
```

Transcript is exactly correct (incl. capitalization + period). ASR wall-clock ~0.17–0.21 s
for 2.79 s of audio. A 0.34 s model load makes a 460 MB fetch impossible, so run 2 was
local-only; the belt-and-suspenders Wi-Fi-off check is on the manual list. Models cache
at `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2/`.

API note: FluidAudio v0.15.4's actual signature is
`transcribe(_ url:, decoderState: inout TdtDecoderState)` — the README's
`transcribe(samples, source: .system)` from older docs does not compile against 0.15.4.

## TCC permissions checklist

| Grant | Needed by | How |
|---|---|---|
| Microphone | v1 capture (not v0 — fixture only) | auto-prompts on first mic use |
| Accessibility | Spike C / injection | System Settings → Privacy & Security → Accessibility → enable WisprLocal (it's registered after the first Spike C attempt) |
| Input Monitoring | optional hotkey only | not needed for button-only path |

## Manual test checklist for John

1. `./scripts/build.sh && ./scripts/run.sh` (menubar waveform icon appears; pill shows bottom-center).
2. **Spike B (caret check):** open TextEdit, type a few words, click the pill mid-sentence, keep typing without re-clicking TextEdit. The dots must light up and pulse on the FIRST click (this is the acceptsFirstMouse fix — no visual change means the click was dropped), characters must keep landing in TextEdit, and the caret must never leave it. `tail -f /tmp/wisprlocal.log` should show `SPIKE B CLICK: frontmostApplication = com.apple.TextEdit`. Click again: dots dim back to idle.
3. **Grant Accessibility:** System Settings → Privacy & Security → Accessibility → toggle WisprLocal on. (If it's not listed, trigger Spike C once from the menubar first.)
4. **Spike C (paste):** copy something distinctive (e.g. "MARKER123"). Menubar → "Spike C: inject…", then click into a TextEdit document within 3 s. Verify: (a) `hello from wispr-local` appears at the cursor; (b) after ~1 s, ⌘V manually pastes `MARKER123` again (clipboard restored).
5. **Spike A (offline check):** menubar → "Spike A: transcribe fixture" once, let it finish; then turn Wi-Fi off and run it again — should transcribe with no network (models cached in `~/Library/Application Support/FluidAudio/Models`).

## Deviations from spec

- Fixture is `Tests/fixtures/fixture.wav` (spec sketch said `hello.wav`); generated deterministically via `say` + `ffmpeg` (16 kHz mono, "the quick brown fox jumps over the lazy dog"), per the task instructions.
- `.gitignore` got `!Tests/fixtures/*.wav` so the fixture survives the blanket `*.wav` ignore.
- Added headless test hooks (DistributedNotificationCenter observers for `com.costajohnt.wisprlocal.spikeA` / `.spikeC` / `.pillFrame`) so spikes can be triggered and evidenced without GUI scripting. Dev-only convenience; strip in v1 if unwanted.
- `SWIFT_VERSION` is 5.0 language mode (Swift 6 strict concurrency would add noise to spike code; revisit for v1).
- App target language: FluidAudio v0.15.4 pinned (`exactVersion`), latest release at build time.
