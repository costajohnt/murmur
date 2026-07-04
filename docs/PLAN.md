# wispr-local — build plan for a local Wispr Flow clone

**Target machines (must run well on both):**
- **Apple M4, 24 GB RAM** (this Mac) — the *constraining* target; ASR + LLM must coexist in tight memory.
- **Apple M5 Max, 64 GB RAM** (MBP) — roomy; can run a larger cleanup model for better quality.

macOS 26.5, Swift 6.3 / Xcode present, Ollama 0.21.0 installed.
**Goal:** system-wide voice dictation. Global hotkey in any app → local ASR → local LLM cleanup (Ollama) → text inserted at cursor. Fully offline, no cloud.
**Build:** implementation on Fable 5, committed to a **private** GitHub repo `costajohnt/wispr-local`.

---

## 1. What Wispr Flow actually is (and how we necessarily diverge)

Verified from Wispr's own engineering post, its infra vendor (Baseten), and Wikipedia:

- Wispr Flow is a **two-stage pipeline**: ASR (speech→text) then a **fine-tuned Meta Llama LLM** that does token-level punctuation, filler removal, formatting, and per-user style adaptation.
- Its latency budget is **<200 ms ASR + <200 ms LLM, <700 ms end-to-end**, hit by running **server-side in the cloud** (TensorRT-LLM). Only "personalization data" stays on device. It has **no offline mode**.
- Activation is **press-hotkey-then-speak**. Reported ASR error rate ~10%.

**The one unavoidable divergence:** Wispr is fast *because* it's cloud. A fully-local clone trades that cloud latency budget for privacy and offline operation. We will not match <700 ms on first speech, but on an M4 with the ASR on the Neural Engine and a warm 3B model on the GPU, a press-to-talk clone feels responsive. This is a deliberate, understood trade, not a defect.

*Sources: wisprflow.ai/post/technical-challenges, baseten.co/resources/customers/wispr-flow, en.wikipedia.org/wiki/Wispr_Flow*

---

## 2. The architecture decision: native Swift, ANE for ASR, GPU for the LLM

The load-bearing constraint is **24 GB shared between ASR and the LLM**. The research produced a seeming contradiction that actually decides the whole stack:

| Path | Runs on | Memory | Verdict |
|---|---|---|---|
| `parakeet-mlx` (Parakeet via MLX) | **GPU** | ~2 GB, up to ~22 GB w/ overhead on M4 Max | ❌ fights Ollama for the GPU |
| **FluidAudio (Parakeet via CoreML)** | **Apple Neural Engine** | **~66 MB** | ✅ leaves the GPU 100% free for Ollama |
| whisper.cpp (Metal) | GPU | ~1.6 GB | competes with Ollama on GPU |
| mlx-whisper | GPU | ~1 GB | competes with Ollama on GPU |

**Because the ANE and GPU are separate silicon**, putting ASR on the ANE (FluidAudio) and the LLM on the GPU (Ollama) lets both stay resident with almost no contention. That is the single most important finding for a 24 GB box. FluidAudio is a **Swift package (Apache-2.0)**, which makes a **native Swift menubar app** the natural architecture — one language for capture, ASR, injection, and Ollama HTTP.

Speed on M4-class hardware (single-utterance benchmark): FluidAudio/Parakeet **~0.19 s**, mlx-whisper ~1.0 s, whisper.cpp+CoreML ~1.2 s, WhisperKit ~2.2 s, faster-whisper ~7 s.

> Caveat carried from research: these are **speed-only** micro-benchmarks on **M4 Pro** (base M4 will be somewhat slower but still far above real-time), comparing **different model families** — they say nothing about *accuracy*. Parakeet's streaming model is **English-only**. If multilingual dictation matters, we keep whisper.cpp as a pluggable fallback backend. **Accuracy on your voice is a v1 acceptance test, not an assumption.**

*Sources: github.com/FluidInference/FluidAudio, github.com/anvanvan/mac-whisper-speedtest, macparakeet.com, whispernotes.app*

### Chosen stack

```
┌─ TRIGGER (primary) Floating pill button, bottom-center, always-on-top,
│                     NON-activating (never steals focus) — click to start/stop
│   TRIGGER (2ndary)  Optional global hotkey (hold fn)
│
├─ 1. CAPTURE   AVAudioEngine → 16 kHz mono PCM buffer  (audio retained for regenerate)
│
├─ 2. ASR       FluidAudio (Parakeet TDT, CoreML, ANE)  ~66 MB, English
│                 → raw transcript
│
├─ 3. CLEANUP   HTTP POST localhost:11434/api/chat (Ollama)
│                 model: llama3.2:3b (or qwen2.5:3b), keep_alive:"30m", stream:true
│                 system prompt = "reformat, don't answer"
│                 → cleaned text
│
├─ 4. INJECT    pasteboard-then-paste: save clipboard → set → CGEvent ⌘V → restore
│                 (AX API kAXSelectedTextAttribute as fallback)
│
└─ 5. PERSIST   append {timestamp, audio.wav, rawTranscript, cleanedText, status}
                  → history store → shown in History window
```

**Permissions required (TCC):** Microphone, Accessibility (injection + global tap), Input Monitoring (hotkey). All three prompt on first use; we detect and guide.

---

## 2.5 Wispr features you specifically want (first-class, not extras)

These are the reasons you like Wispr, so they're core requirements, not v2 nice-to-haves.

### A. Floating on-screen button (primary trigger — you prefer this over a hotkey)
- A small **pill button anchored bottom-center of the screen**, always visible, always on top.
- Built as a borderless **`NSPanel`** with `styleMask: [.nonactivatingPanel]`, `level = .floating` (or `.statusBar`), `canBecomeKey = false`, `collectionBehavior` including `.canJoinAllSpaces` so it follows you across Spaces/full-screen apps.
- **Critical:** because it's non-activating, clicking it **does not steal focus** from the app you're dictating into — so the paste-injection still lands in the right place. This is *the* correctness constraint for a click-trigger, and it's exactly why a naive floating window breaks injection.
- States shown on the button: idle → listening (waveform/pulse) → transcribing → done. Click to start, click to stop (or hold, configurable).
- Hotkey stays as an optional secondary trigger for people who want it.

### B. Desktop history window
- A real SwiftUI window (opened from the menubar or the pill) listing every dictation, newest first: timestamp, cleaned text (primary), raw transcript (secondary/expandable), and status (✅ done / ⚠️ failed / retryable).
- **Persistence:** local store of `{id, createdAt, audioPath.wav, rawTranscript, cleanedText, model, status}`. Recommended: **SwiftData** (native, macOS 14+, zero deps) or GRDB/SQLite if we want portability. Audio clips live in Application Support with a **retention cap** (e.g. keep last N or last 30 days, auto-prune) since saving audio for regenerate costs disk.

### C. Regenerate failed transcriptions
- Two regenerate levels, both from a history row:
  - **Re-transcribe** (fixes a bad/failed ASR): needs the **saved audio** → re-run FluidAudio. This is why we persist the WAV.
  - **Re-clean** (fixes bad formatting): needs only the **raw transcript** → re-run Ollama, optionally with a different model/tone.
- Failed injections are also retryable (the text was fine, the paste missed).

### D. Copy / paste any past message
- Any history row: **Copy** (to clipboard) and **Insert at cursor** (re-run the injection into the frontmost app). Covers the "sometimes copy doesn't land, grab it from the app instead" case you called out.

---

## 3. Ollama cleanup stage

Verified against Ollama's official `docs/api.md`:

- Endpoint: `POST http://localhost:11434/api/chat` (or `/api/generate`), JSON body `{model, messages, stream, keep_alive, options}`.
- **`keep_alive`** controls residency: default `5m`, `0` unloads immediately, `"30m"`/`-1` keeps warm. We set it long so the model stays hot → no cold-start on each dictation.
- `stream:true` streams tokens (lets us inject progressively later).
- Model pick is **per-machine**, driven by a config default the app auto-selects on RAM:
  - **M4 / 24 GB:** **`llama3.2:3b`** (~2 GB) default, `qwen2.5:3b` / `gemma3:4b` alternates. Keep ≤4B so the warm model plus everything else fits comfortably.
  - **M5 Max / 64 GB:** step up to **`qwen2.5:7b`** or **`llama3.1:8b`** for noticeably better cleanup, still trivially resident. Same code path, bigger model, `keep_alive` long.
- Because ASR sits on the ANE (~66 MB), the GPU budget is essentially all-LLM on both machines; the 64 GB box just lets the LLM be larger.

**Critical prompt-design gotcha:** the model must **reformat, not respond**. A cleanup prompt like *"You are a transcript formatter. Fix punctuation, capitalization, and remove filler words (um, uh, like). Do not answer questions, add content, or converse. Output only the corrected text."* Otherwise it'll try to *answer* dictated questions. This is the #1 failure mode of naive Ollama-cleanup builds and gets an explicit test.

*Sources: github.com/ollama/ollama/blob/main/docs/api.md, github.com/luisalima/local-whisper, mljourney.com (keep_alive)*

---

## 4. Text injection

Two proven mechanisms (both used by reference apps):

1. **Pasteboard-then-paste (primary, most robust):** snapshot the current clipboard, write cleaned text, synthesize **⌘V** via `CGEvent`, restore the clipboard. Works in nearly every app.
2. **`CGEvent.keyboardSetUnicodeString` (fallback):** types exact Unicode independent of layout — but **some frameworks (Qt) re-translate from keycode and drop it**, so it's not universal. Hence paste is primary.
3. **AX API** (`AXUIElementCreateSystemWide` → `kAXFocusedUIElement` → set `kAXSelectedTextAttribute`) as a secondary fallback for AX-friendly fields.

*Sources: developer.apple.com CGEvent docs, github.com/cjpais/Handy, github.com/OpenWhispr/openwhispr, levelup.gitconnected.com Swift-insert-text*

---

## 5. Build-from-scratch vs fork

Research surfaced four viable fork bases. Assessment for **your** constraints (native, private repo, Ollama cleanup, clean ownership):

| Repo | Lang | License | Ollama? | Injection? | Fit |
|---|---|---|---|---|---|
| **VoiceInk** | Swift (native) | **GPL-3.0** | no | yes | copyleft — awkward for a private/clean-owned repo |
| Handy | Rust/Tauri | MIT | no (add it) | yes | clean but Rust, no cleanup stage |
| **local-whisper** | shell/Hammerspoon | — | **yes (gemma3:4b)** | yes (paste) | closest pipeline but Hammerspoon-hacky |
| OpenWhispr | Electron/TS | MIT | no | yes | heavy runtime for a menubar util |

**Recommendation: build fresh, native Swift, borrowing patterns from these (they're the reference implementations, all reading-permitted).** Rationale: FluidAudio is Swift and Apache-2.0, native gives the best memory/latency profile, avoids GPL entanglement in a private repo, and a from-scratch menubar app is genuinely small (the reference apps show the whole pattern). We read Handy/local-whisper/VoiceInk for their injection and Ollama-wiring specifics; we don't fork.

---

## 6. Phased implementation (what Fable 5 builds)

**v0 — scaffold + spikes (de-risk the three unknowns first)**
- Swift Package / Xcode menubar app skeleton (`MenuBarExtra`, no dock icon).
- Spike A: FluidAudio transcribes a WAV file end-to-end (proves ANE ASR + SPM/license integration).
- Spike B: **non-activating floating pill** renders bottom-center, is clickable, and does **not** steal focus (prove injection still targets the previously-focused app after a click).
- Spike C: paste-inject a fixed string into the frontmost app (proves TCC + CGEvent).
- Ollama: `ollama serve` + `ollama pull llama3.2:3b`, curl `/api/chat` round-trip.

**v1 — the milestone: click-to-dictate with history**
- **Floating button** (primary trigger): click → record → click → transcribe → cleanup → paste at cursor. State animation on the pill.
- Pipeline: AVAudioEngine → FluidAudio → Ollama cleanup → paste-inject, with clipboard-restore and error surfacing.
- **History window (basic):** persisted list of dictations (SwiftData), each with cleaned text + raw + status; **Copy** and **Insert at cursor** per row.
- **Regenerate (basic):** re-clean from stored raw transcript.
- Acceptance test: dictate 3 real paragraphs into Notes/Slack/browser; confirm the pill doesn't steal focus; measure accuracy + latency; verify the "reformat-not-answer" prompt holds when you dictate a question; confirm history rows copy correctly.

**v2 — full history + Wispr-feel polish**
- **Re-transcribe** from saved audio (full regenerate); audio retention/prune policy.
- History search, delete, expandable raw/clean diff view.
- Streaming ASR (FluidAudio `SlidingWindowAsrManager` + EOU model) for real-time partial text.
- Settings UI: RAM-based model auto-pick + override, cleanup-tone presets, custom vocabulary, optional hotkey rebind, pill position/size.
- Optional AX-injection path; launch-at-login; onboarding for the 3 TCC permissions.

---

## 7. Open decisions for you

1. **Repo name:** `wispr-local` (proposed) — confirm or pick another.
2. **Default cleanup model:** auto-select by RAM — `llama3.2:3b` on the M4, `qwen2.5:7b`/`llama3.1:8b` on the M5 Max. Confirm the two defaults, or pick one model to use everywhere. We can pull candidates and A/B during v1.
3. **Trigger:** floating pill button is primary (per your preference); **click-to-start/click-to-stop** (recommended) vs press-and-hold. Keep an optional hotkey too?
4. **v1 scope confirm:** click-to-dictate + basic history (copy + re-clean) first; full re-transcribe-from-audio, search, and streaming in v2.
5. **History persistence:** SwiftData (native, zero-dep — recommended) vs SQLite/GRDB.

---

## Sources (all verified, 25/25 claims confirmed, 0 refuted)

- Wispr stack: wisprflow.ai/post/technical-challenges · baseten.co/resources/customers/wispr-flow · en.wikipedia.org/wiki/Wispr_Flow
- ASR: github.com/FluidInference/FluidAudio · github.com/anvanvan/mac-whisper-speedtest · macparakeet.com · whispernotes.app · notes.billmill.org (mlx vs whisper.cpp)
- Injection/hotkey: developer.apple.com CGEvent keyboardSetUnicodeString · github.com/cjpais/Handy · github.com/OpenWhispr/openwhispr · levelup.gitconnected.com
- Ollama: github.com/ollama/ollama/blob/main/docs/api.md · github.com/luisalima/local-whisper · mljourney.com
