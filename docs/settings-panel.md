# Settings panel

Add a native macOS Settings window, opened from the menubar ("Settings…", ⌘,). Four sections. **Design principle: zero-config defaults.** Every setting has a sensible default so the user never has to open this; the panel is for people who want to override. Match the app's clean aesthetic; standard macOS `Form`/`Settings` look; light + dark.

Persistence via `@AppStorage`/UserDefaults in a small `AppSettings` type. Wire each setting into the live pipeline (don't just store it).

## 1. Cleanup model (the explicitly requested feature)
- Dropdown of the cleanup LLM. First option: **"Auto (recommended)"** = the existing RAM-based resolve (llama3.2:3b ≤32 GB, qwen2.5:7b >32 GB, with the current fallback chain). Remaining options: every model currently installed in Ollama, fetched via `OllamaClient.installedModels()` (`/api/tags`).
- Persist the choice as `cleanupModelOverride: String?` (nil = Auto). Wire into `OllamaClient.resolveModel()`: if an override is set AND installed, use it; else fall back to the existing auto logic.
- Handle edge cases: Ollama unreachable → show a muted "Ollama not running" note and keep whatever's stored; a "Refresh" affordance to re-query tags; if a stored override is no longer installed, show a subtle warning and behave as Auto.

## 2. Cleanup tone preset
- A small set of presets that swap the cleanup **system prompt** (the base "reformat, don't answer" core + few-shot pairs MUST stay in every preset — presets only adjust the formatting style layer):
  - **Faithful** (default): fix punctuation/capitalization, remove fillers, otherwise leave wording alone.
  - **Polished**: also tighten grammar and make it read cleanly/professionally, without changing meaning.
  - **Casual**: keep the relaxed spoken tone, just clean it up.
- Persist as `tonePreset`. `OllamaClient` selects the base system prompt by preset. Do NOT let a preset weaken the don't-answer / don't-invent guard.

## 3. Global hotkey (optional, OFF by default — John prefers the pill)
- A toggle "Enable global hotkey" (default off) + a shortcut recorder. When enabled, the hotkey toggles dictation exactly like a pill click (start/stop). When off, no global monitor is installed and no Input Monitoring permission is requested.
- Keep it simple and robust: a modifier+key recorder is ideal; if a full recorder is too much, a small fixed set (e.g. "double-tap Right ⌘", "⌥Space") behind the toggle is acceptable — note which you chose. Persist enabled + binding.
- Document that enabling it may prompt for Input Monitoring.

## 4. Launch at login
- Toggle using `SMAppService.mainApp` (register/unregister, macOS 13+). Reflect the actual current registration state on open. Default off. Persist/derive from the service state.

## Wiring & guardrails
- The pill remains the primary trigger regardless of settings.
- Do not regress: Auto model + Faithful tone + hotkey off + launch-at-login off must reproduce today's exact behavior.
- Build clean via `scripts/build.sh`. Where you can, verify automatically (e.g. resolveModel honors an override that's installed; falls back when it isn't; tone preset changes the system prompt string; SMAppService toggle flips registration state). Screenshot the Settings window (light + dark if quick). GUI interactions the human must check go in a manual checklist.
- NO commit/push. Stay in `~/dev/wispr-local`. STOP and report if a section can't be made to work rather than faking it.
- Report: build output, what you verified automatically, screenshots, manual checklist, `git status --short`.
