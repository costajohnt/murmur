# Public-release prep

Prepare the app for a public open-source release. Two buckets: **rename off "Wispr" → "Murmur"** and **fix the CRITICAL findings** in `docs/release-audit.md`, plus license/README. Scope is C1–C5 (blockers) only; I1/I2 (onboarding, error surfacing) are a separate fast-follow — do NOT build them here.

## 1. Rename WisprLocal / wispr-local → Murmur

Product name **Murmur**, bundle id **com.costajohnt.murmur**. Rename everywhere it's user-facing or an identifier. Keep the local directory path as-is (`~/dev/wispr-local`) — only the product/identifiers change; the repo gets renamed separately by me.

- `project.yml`: `name: WisprLocal` → `Murmur`; target name → `Murmur`; `PRODUCT_BUNDLE_IDENTIFIER` → `com.costajohnt.murmur`; `bundleIdPrefix` stays `com.costajohnt`. Update the scheme name if pinned.
- `scripts/build.sh` / `scripts/run.sh`: update `-scheme WisprLocal` → `-scheme Murmur` and the built `.app` path (`WisprLocal.app` → `Murmur.app`).
- `.gitignore`: `WisprLocal.xcodeproj/` → `Murmur.xcodeproj/`.
- `Sources/Info.plist`: `CFBundleName`/`CFBundleDisplayName` → Murmur; `NSMicrophoneUsageDescription` → "Murmur transcribes your speech locally."
- `Sources/WisprLocal/*`: rename the `@main struct WisprLocalApp` → `MurmurApp`; `MenuBarExtra("WisprLocal", …)` → `"Murmur"`; window titles "wispr-local History" → "Murmur — History", "wispr-local Settings" → "Murmur — Settings". (You may keep the *directory* `Sources/WisprLocal/` and file names to avoid churn — the product name is what ships. Your call; if you rename the dir, update project.yml `sources` path.)
- Test-hook notification names + EventHotKeyID signature: cosmetic; since test hooks become DEBUG-only (below), you can leave the `com.costajohnt.wisprlocal.*` strings or rename to `.murmur.*` — your call, just keep them internally consistent.
- **Data directory + migration (important — John has real dictations):** history/audio currently live under `~/Library/Application Support/wispr-local/`. Switch the support dir to `Murmur`, but add a ONE-TIME migration in `HistoryStore`: on init, if the new `Murmur` dir doesn't exist AND the old `wispr-local` dir does, `moveItem` the old dir to the new path so existing history carries over. Log it.
- Note in your report (for John, don't fix): changing the **bundle id** means macOS treats it as a new app — he'll need to re-grant Microphone + Accessibility once, and the login-item registration resets. Expected for a rename.

## 2. CRITICAL security/privacy fixes (from release-audit.md)

### C1 + C3 — DEBUG-gate all dev scaffolding
Wrap in `#if DEBUG … #endif` so they compile OUT of release builds:
- The `AppDelegate.registerTestHooks()` method body (or the call site at `applicationDidFinishLaunching`), so NONE of the `DistributedNotificationCenter` observers are registered in release.
- The `V1TestHooks` enum and the `SpikeA`/`SpikeC` types (and any spike-only helpers).
- The Spike A/B/C `Button`s in the `MenuBarExtra` menu.
Release menu should be just: Open History…, Settings…, (divider), Quit. Verify a release build (`xcodebuild -configuration Release`) compiles with these gated out.

### C2 — stop leaking transcript content to /tmp
- Move the log OFF `/tmp`. In release, do NOT write dictated content anywhere.
- Simplest robust approach: `Log` writes to a file only in `#if DEBUG` (dev keeps a log under Application Support/Murmur/, NOT /tmp); in release, `Log.log` either no-ops the file write or routes to `os_log` WITHOUT transcript content.
- Additionally, DEBUG-gate the specific log lines that include transcript text (the `pipeline ASR (...): "<raw>"` and `pipeline cleanup (...): "<cleaned>"` lines in DictationCoordinator, and any context/preview logging). Release builds must never write the user's spoken words to disk.

## 3. License, attribution, README

- Add `LICENSE`: MIT, copyright 2026 John Costa.
- Add `NOTICE`: this product depends on FluidAudio (Apache-2.0, © FluidInference) and downloads the NVIDIA Parakeet TDT model (CC-BY-4.0) at runtime — include the required attributions.
- Update `README.md`: new name (Murmur), one-line description, the "fully local / private" promise, an explicit "**No model weights are bundled** — the ASR model is downloaded by FluidAudio on first run and the cleanup LLM is served by your local Ollama; each model carries its own license (Parakeet CC-BY-4.0; Llama 3.2 = Meta Community License; Qwen2.5-7B = Apache-2.0)." Build/run instructions (xcodegen + build.sh, needs Ollama running), and the required permissions (Microphone, Accessibility). Keep the existing "prior art" and "how it works" sections, renamed.

## Verify / guardrails
- `scripts/build.sh` (Debug) still builds AND a Release build compiles with scaffolding gated out (`xcodebuild -scheme Murmur -configuration Release build`). Confirm the release menu has no Spike items and that grepping the release binary/build shows the test-hook observers aren't registered (or just confirm they're inside `#if DEBUG`).
- The app still runs and the core dictation loop, pill, history, settings all work (Debug).
- Data migration: if `~/Library/Application Support/wispr-local/` exists, confirm it moves to `Murmur/` and history still loads.
- NO commit/push. Report build output (Debug + Release), what you gated, the LICENSE/NOTICE/README additions, migration behavior, and `git status --short`. STOP and report if anything can't be done cleanly.
