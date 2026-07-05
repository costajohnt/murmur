# Release-readiness audit (2026-07-04)

Read-only audit of the app ahead of a public open-source release. Prioritized; file:line references.

## CRITICAL — must fix before public release

### C1. Dev test hooks ship in release and are remotely triggerable by any local process
`WisprLocalApp.swift:159 registerTestHooks()` registers ~20 `DistributedNotificationCenter` observers, unconditionally, in every build. `DistributedNotificationCenter` is **system-wide IPC** — any process running as the same user can post these and trigger:
- `meterTest` → records the microphone for ~6 s (`WisprLocalApp.swift:387`)
- `spikeC` / injects text into the focused app (`SpikeC.run()`)
- `historyDeleteNewest` → deletes the newest history entry + its audio (`:206`)
- `pipelineFixture`, `guardTest`, `cancelTest`, `openSettings`, … run internal flows
This is a genuine privacy/integrity hole in a "fully private" app. **Fix:** wrap `registerTestHooks()`, `V1TestHooks`, and the Spike types in `#if DEBUG` so they are compiled out of release builds.

### C2. Dictated transcript content is logged to world-readable /tmp
`Log.swift` writes to `/tmp/wisprlocal.log`, and the pipeline logs transcript text verbatim: `DictationCoordinator` logs `pipeline ASR (...): "<raw>"` and `pipeline cleanup (...): "<cleaned>"`; context length, etc. `/tmp` is readable by other users/processes. For a privacy-first local dictation tool, **the user's spoken content is leaking to a shared, plaintext file.** **Fix:** never log transcript content in release; move the log out of `/tmp` (e.g. Application Support) and/or gate verbose logging behind `#if DEBUG`. At minimum stop logging raw/cleaned text.

### C3. Spike A/B/C dev commands are in the shipping menubar
`WisprLocalApp.swift:19-27` shows "Spike A: transcribe fixture", "Spike B: show floating pill", "Spike C: inject 'hello from wispr-local'". User-facing dev cruft (one injects text). **Fix:** remove or `#if DEBUG`-gate these menu items; the Spike types become debug-only.

### C4. No LICENSE / NOTICE
No `LICENSE` or `NOTICE` file. Required for an OSS release and for attribution: FluidAudio (Apache-2.0 → NOTICE), Parakeet model (CC-BY-4.0 → attribution). **Fix:** add MIT `LICENSE` + `NOTICE`. (Part of release prep.)

### C5. Trademark: still named "wispr-local"
Product name, bundle id `com.costajohnt.wisprlocal`, window titles ("wispr-local History/Settings"), menubar label all say "Wispr". Trademark exposure for a public release. **Fix:** rename to **Murmur** (chosen) across project.yml, Info.plist, bundle id, window titles, README, repo. (Part of release prep.)

## IMPORTANT — should fix

### I1. No permissions onboarding; Accessibility failure is silent
Mic prompts on first record (`AudioRecorder.start()`), but **Accessibility must be granted manually** — `TextInjector.inject` logs the failure to `/tmp` and calls the prompt API, but the user sees nothing in-app; the dictation just doesn't paste. First run with no Accessibility = "it silently doesn't work." **Fix:** a first-run/onboarding flow (or a visible in-app state) that checks `AXIsProcessTrusted()` and guides the user to grant Accessibility + Microphone.

### I2. Failures are logged, not surfaced
Ollama down, model missing, inject failed, mic denied → only `/tmp` log lines; the pill just returns to idle. The user can't tell dictation failed or why. **Fix:** surface failures (a pill error state, a menubar badge, or a brief notification), at least for the common cases (Ollama unreachable, Accessibility missing).

### I3. No app icon
Ships with the generic macOS app icon. **Fix (nice-to-have for polish):** add an `AppIcon` asset.

### I4. No SwiftData schema versioning / migration
`Dictation` `@Model` has no `VersionedSchema`/migration plan. A future model change risks failing to open the store → history loss. **Fix:** document/adopt a versioned schema before the model changes.

## MINOR / nice-to-have

- **M1.** `TextInjector` restores the clipboard after a fixed 1.0 s (`:12`); if the user copies during that window it's clobbered, and concurrent injections can race on the pasteboard.
- **M2.** If the target app quits between record-start and inject, `target.activate` no-ops and ⌘V lands in whatever's now frontmost (`TextInjector:29`).
- **M3.** `Dictation.audioPath` stores an absolute path; storing just the filename and rebuilding under the audio dir would be more robust.
- **M4.** Pill positions off `NSScreen.main` only (`PillPanel.positionBottomCenter`); multi-display / display-disconnect not handled.
- **M5.** Launch-at-login in a Debug build registers the DerivedData path; only correct once installed to /Applications (expected, note for release testing).
- **M6.** `prune()` runs a full fetch on every `add()` — fine at the 200 cap, not a scaling concern.

## What's solid (no action)
- Local-only: the only network calls are localhost Ollama + FluidAudio's one-time model download. No telemetry.
- ASR-on-ANE / LLM-on-GPU coexistence; near-silence guard; context-aware cleanup; clipboard snapshot/restore preserves all types; target-app tracking via activation notifications; Carbon hotkey needs no extra permission; retention/pruning is wired.
