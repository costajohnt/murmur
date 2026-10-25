# Murmur

Local, private macOS dictation app (Swift, macOS 14+, Apple Silicon). Transcribes
on-device via FluidAudio; optional cleanup through a local Ollama. See `README.md`
for features, install, permissions and model choices.

## Build / test
- Requires `xcodegen` (`brew install xcodegen`). `Murmur.xcodeproj/` is generated
  from `project.yml` and gitignored: edit `project.yml`, never the project file.
- `scripts/build.sh`: `xcodegen generate` + Debug build into `build/DerivedData`.
- `scripts/run.sh`: launch the built app. Debug log:
  `~/Library/Application Support/Murmur/debug.log`.
- `scripts/create-signing-cert.sh` once per machine, so `build.sh` signs with
  "Murmur Dev Signing" and Microphone/Accessibility grants survive rebuilds.
- Unit tests (what CI runs, after `xcodegen generate`):
  `xcodebuild -project Murmur.xcodeproj -scheme MurmurTests -configuration Debug test CODE_SIGNING_ALLOWED=NO`
- No Swift linter is configured.

## CI / release
- `.github/workflows/ci.yml` (macos-15, PRs and pushes to `main`): Debug build,
  `MurmurTests`, Release build, and on push `scripts/test-install.sh`.
- `.github/workflows/release.yml` runs on `v*` tags and signs with
  `scripts/sign-release.sh` (self-signed, not notarized). The signing key lives
  only in release CI.
- Version is set in `project.yml` (`CFBundleShortVersionString`, `CFBundleVersion`),
  not `Sources/Info.plist`, which xcodegen regenerates.

## Gotchas
- FluidAudio is pinned by commit in `project.yml`, not by tag, because it ships in
  the signed app. `Package.resolved` is gitignored.
- Other sessions keep worktrees under `~/dev/murmur-wt/` and `.claude/worktrees/`.
  Work in your own worktree, not the main checkout.
