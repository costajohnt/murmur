# v0 — de-risking spikes

Goal of v0: prove the three riskiest unknowns compile, run, and behave correctly on this Mac **before** building the full v1 app. Each spike is small and independently verifiable. Build the shared app skeleton first, then the spikes on top of it.

## Project setup (shared)

- **Tooling:** XcodeGen (`project.yml` → `WisprLocal.xcodeproj`). The `.xcodeproj` is git-ignored and regenerated; `project.yml` is the source of truth.
- **Bundle id:** `com.costajohnt.wisprlocal` (stable — TCC permissions key off this + the signature).
- **Deployment target:** macOS 14.0 (SwiftData available).
- **Signing:** ad-hoc is fine for local dev, but prefer your installed **Apple Development** identity so TCC grants persist across rebuilds. `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "Apple Development"`.
- **App Sandbox: OFF.** Cross-app injection and global input require it disabled. Do not add the sandbox entitlement.
- **Info.plist keys:** `NSMicrophoneUsageDescription` ("wispr-local transcribes your speech locally."), `LSUIElement = true` (menubar/agent app, no dock icon).
- **Dependency:** FluidAudio via SwiftPM — `https://github.com/FluidInference/FluidAudio` (Apache-2.0). Pin to a released tag.
- **App shell:** SwiftUI `App` with a `MenuBarExtra`. Menubar menu has: "Open History" (stub window ok), "Quit". This is the host for all spikes.
- **Build/verify:** provide a `Makefile` or `scripts/build.sh` that runs `xcodegen generate` then `xcodebuild -scheme WisprLocal -configuration Debug build`, and a `scripts/run.sh` that launches the built `.app`. Every spike must build clean via this path.

## Spike A — FluidAudio transcribes a WAV on the ANE

**Prove:** FluidAudio integrates via SPM, downloads/loads the Parakeet CoreML model, and transcribes offline.

- Bundle a short spoken-word WAV test fixture (or record one) at `Tests/fixtures/hello.wav` (16 kHz mono).
- On a menubar menu item "Spike A: transcribe fixture", run FluidAudio over the fixture and `print` the transcript + wall-clock time.
- **Accept:** transcript is recognizably correct for the fixture, ASR runs with no network, elapsed time logged. Note the model download step (first run pulls the CoreML model — that's expected, log it).

## Spike B — non-activating floating pill does NOT steal focus

**This is the highest-risk spike. Prove it early.**

**Prove:** a floating always-on-top button can be clicked without stealing keyboard focus from the frontmost app.

- Create an `NSPanel` subclass: `styleMask = [.nonactivatingPanel, .borderless]`, `level = .statusBar`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, and override `canBecomeKey = false`, `canBecomeMain = false`.
- Position it bottom-center of the main screen. Put a button on it whose action calls `NSWorkspace.shared.frontmostApplication` and logs the bundle id **at click time**.
- **Accept (automatable):** click the pill while TextEdit is frontmost → the logged `frontmostApplication` is still **TextEdit**, not wispr-local. If it logs wispr-local, the panel is stealing focus and the config is wrong — iterate until it doesn't.
- **Accept (manual, for John):** type in TextEdit, click the pill, keep typing — the caret stays in TextEdit and characters keep landing there. Document this manual check.

## Spike C — paste-inject text at the cursor

**Prove:** text can be programmatically inserted into the frontmost app's focused field.

- Implement `injectText(_:)`: snapshot `NSPasteboard.general` contents → set the string → synthesize ⌘V via `CGEvent` (keyDown/keyUp for `v` with `.maskCommand`) → restore the previous pasteboard after a short delay.
- Wire it to a menubar item "Spike C: inject 'hello from wispr-local'".
- **Accept (automatable-ish):** with TextEdit frontmost, trigger it → the string appears in the document. Requires Accessibility permission (the app will prompt; document the grant step).
- **Accept (manual):** confirm the previous clipboard contents are restored afterward.

## TCC permissions checklist (document in output)

The app needs three grants; note which spike triggers each and how to grant:
- **Microphone** (Spike A capture, and v1) — prompts on first mic use.
- **Accessibility** (Spike C injection) — System Settings → Privacy & Security → Accessibility; must be added manually, no auto-prompt for CGEvent posting.
- **Input Monitoring** (only if the optional hotkey is added) — not needed for the button-only path.

## Guardrails for the build agent

- **Do NOT `git commit`, `git push`, or create any PR.** Leave all changes in the working tree for review.
- Keep the diff to `~/dev/wispr-local`. Do not touch anything outside it.
- If a spike can't be made to pass, STOP and report what failed and why — do not fake success or silently skip it.
- End with: build command output, which accept-criteria passed automatically, and a short manual-test checklist for the GUI-dependent ones.
