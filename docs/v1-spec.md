# v1 — click-to-dictate with basic history

Goal: turn the validated v0 pieces into a working dictation loop driven by the pill, plus a persisted history window. End state: click the pill → speak → click again → cleaned text is pasted at the cursor, and the dictation is saved to history where it can be copied, re-inserted, or re-cleaned.

Build on the v0 code already in the repo. Reuse: `PillPanel`/`PillState` (states already exist), the paste-injection logic from `SpikeC`, the FluidAudio path from `SpikeA`. Keep the spike menu items for debugging, but the pill is the primary trigger.

## Pipeline (wire behind the pill)

Pill click cycles: **idle → listening → (auto) processing → idle**.
- Click 1 (idle→listening): capture the **target app** (see below), start `AVAudioEngine` recording to a 16 kHz mono buffer, animate the listening dots.
- Click 2 (listening→processing): stop recording; show a processing state on the pill (distinct from listening — e.g. dots switch to a spinner/sweep); run the pipeline:
  1. **ASR** — FluidAudio (Parakeet TDT v2, the v0 path) transcribes the buffer → raw transcript.
  2. **Cleanup** — POST to Ollama and get cleaned text (see Ollama section).
  3. **Inject** — paste cleaned text into the **target app** (SpikeC logic: snapshot clipboard → set → ⌘V → restore).
  4. **Persist** — append a history entry.
- Return to idle.

### Target app capture (important correctness point)
Because the pill is non-activating, the frontmost app *usually* stays the user's app — but `NSWorkspace.frontmostApplication` can read stale in an idle background app (seen in v0). So: subscribe to `NSWorkspace.shared.notificationCenter` `didActivateApplicationNotification` and keep a `lastActiveApp` (ignoring our own bundle id). At record-start, snapshot that as the injection target and paste back into it explicitly (activate it if needed just before paste). Do not rely on reading frontmost at paste time.

## Ollama cleanup

- Client: `URLSession` POST to `http://localhost:11434/api/chat`, JSON `{model, messages, stream:false (v1), keep_alive:"30m", options:{temperature:0.2}}`. Non-streaming is fine for v1; structure it so streaming can be added later.
- Default model: `llama3.2:3b` (already pulled). Make the model a constant/config value. Auto-default by RAM: `>32 GB → qwen2.5:7b`, else `llama3.2:3b` — but if the resolved model isn't installed, fall back to whatever `llama3.2:3b`/first available and surface a clear message; never crash.
- **System prompt (reformat, do NOT answer):** something like: *"You are a dictation formatter. Given a raw speech-to-text transcript, return it cleaned up: fix capitalization and punctuation, remove filler words (um, uh, like, you know), fix obvious transcription errors, and apply sensible paragraph/line breaks. Do NOT answer questions, do NOT add or remove meaning, do NOT converse or add commentary. Output ONLY the corrected transcript text."* User message = the raw transcript.
- Robustness: if Ollama isn't reachable (connection refused) or the model is missing, fall back to injecting the **raw transcript** and mark the history entry `status: cleanup_failed` with the error. The user still gets their words. Surface a brief pill/menubar error indicator.

## History (SwiftData)

- Model `Dictation`: `id: UUID`, `createdAt: Date`, `audioPath: String?` (WAV saved to Application Support/wispr-local/audio/), `rawTranscript: String`, `cleanedText: String`, `model: String`, `status: enum {done, cleanup_failed, asr_failed}`, `durationMs: Int?`.
- Persist the recorded audio to a WAV file per entry (enables v2 re-transcribe). Add a simple retention cap: keep the most recent **200** entries / prune audio older than 30 days (constant, documented). Pruning can be naive.
- **History window** (open from menubar "Open History…", and optionally a right-click on the pill): a SwiftUI `Window`/`WindowGroup` listing entries newest-first. Each row shows: relative time, cleaned text (primary), status badge, and an expandable/secondary raw transcript. Per-row actions:
  - **Copy** — cleaned text to clipboard.
  - **Insert at cursor** — re-run injection into the current `lastActiveApp`.
  - **Re-clean** — re-run Ollama on the stored `rawTranscript` (optionally letting the model differ), update the entry in place.
  - (v2, not now: Re-transcribe from audio, search, delete.)

## Acceptance (what to verify)

Automatable (do these and report evidence):
- Build clean via `scripts/build.sh`.
- Ollama cleanup unit check: feed a known messy transcript (e.g. "um so like the meeting is at uh three pm") through the client → returns cleaned text without answering; feed a dictated question ("what time is it") → it does NOT answer, just formats. Log both.
- History persistence: create an entry programmatically, relaunch, confirm it loads from SwiftData.
- ASR still works on the fixture (regression).

Manual (write a checklist for John — needs mic + Accessibility grant):
- Full loop: click pill, speak a sentence, click again → cleaned text pastes into the focused app; caret/target correct; entry appears in History; Copy/Insert/Re-clean work.

## Guardrails (unchanged)
- Do NOT `git commit`, `git push`, or make PRs. Leave changes in the working tree.
- Stay inside `~/dev/wispr-local`. If something can't be made to work, STOP and report — don't fake or silently skip.
- Report build output, automatable evidence, a manual checklist, and `git status --short`.
