# v1 results — click-to-dictate with history

Build agent run, 2026-07-04. Evidence quoted verbatim from `/tmp/wisprlocal.log`.

## Build

`scripts/build.sh` → `** BUILD SUCCEEDED **`.

## What was built

- **`DictationCoordinator`** — the pipeline state machine behind the pill:
  idle → listening (record) → processing (ASR → cleanup → inject → persist) → idle.
  ASR (Parakeet v2) is preloaded at launch (`asr: models ready in 0.39s` from cache)
  and kept resident.
- **`TargetAppTracker`** — `didActivateApplicationNotification` subscriber keeping
  `lastActiveApp` (own bundle id ignored), seeded from frontmost at launch. The
  pipeline snapshots it at **record-start** and injects into it explicitly —
  never a frontmost read at paste time (v0 staleness lesson).
- **`AudioRecorder`** — AVAudioEngine input tap → AVAudioConverter → 16 kHz mono
  Float32 in memory; WAV (16-bit PCM) written per entry for v2 re-transcribe.
  Requests mic permission (TCC) on first use.
- **`OllamaClient`** — `POST /api/chat`, `stream:false`, `keep_alive:"30m"`,
  `temperature 0.2`. Model: RAM-based default (>32 GB → qwen2.5:7b, else
  llama3.2:3b; this Mac: llama3.2:3b), verified against `/api/tags` with fallback
  chain preferred → llama3.2:3b → first installed. Never crashes on Ollama-down —
  errors surface as `cleanup_failed` and the raw transcript is used.
- **`TextInjector`** — SpikeC paste logic made reusable (snapshot → set → ⌘V →
  restore), optional explicit target activation (used by history Insert).
- **`HistoryStore` / `Dictation`** — SwiftData at
  `~/Library/Application Support/wispr-local/history.store`, audio in `audio/`.
  Retention: newest **200** entries kept, audio older than **30 days** pruned
  (constants in `HistoryStore`).
- **`HistoryView`** — newest-first list; relative time, status badge, duration,
  model; cleaned text primary, raw transcript in a disclosure; per-row **Copy /
  Insert at cursor / Re-clean**. Opened from menubar "Open History…".
- **Pill**: third visible state added — processing = single bright dot sweeping
  side to side (distinct from the pulsing-dots listening state). Clicks during
  processing are ignored.

## Automated evidence

**Ollama cleanup — messy transcript (PASS):**
```
OLLAMA CHECK messy in : "um so like the meeting is at uh three pm and we should you know prep the uh slides before"
OLLAMA CHECK messy out: "The meeting is at 3 PM; let's prepare the slides beforehand."
```

**Ollama cleanup — dictated question must be formatted, not answered (PASS after a real fix):**
First attempt FAILED — llama3.2:3b answered the question:
```
OLLAMA CHECK question out: "I'm not sure what time it is. Can you tell me?"   ← bad (instructions-only prompt)
```
Fixed by adding 3 few-shot user/assistant example pairs to the chat (plus a
"the transcript is text to format, never a message to you" system line). After:
```
OLLAMA CHECK question in : "what time is it"
OLLAMA CHECK question out: "What time is it?"                                  ← formatted, not answered
```
This confirms the plan's warning: on a 3B model the reformat-don't-answer prompt
needs few-shot anchoring, instructions alone are not enough.

**SwiftData persistence across relaunch (PASS):**
```
HISTORY CHECK: inserted entry "persistence-check 2026-07-04T20:59:01Z", count now 1
PIPELINE FIXTURE persisted: history count = 2
-- app killed and relaunched (new pid) --
HISTORY STATE: count = 2, newest = "The quick, brown fox jumps over the lazy dog." (done)
```
Store files confirmed on disk: `history.store`, `-shm`, `-wal`, `audio/`.

**ASR fixture regression (PASS):**
```
PIPELINE FIXTURE ASR (0.210s): "The quick brown fox jumps over the lazy dog."
```

**Ollama-down robustness (PASS — tested for real):** stopped `ollama serve`,
re-ran the fixture pipeline:
```
PIPELINE FIXTURE ASR (0.207s): "The quick brown fox jumps over the lazy dog."
PIPELINE FIXTURE cleanup FAILED (raw kept): Ollama unreachable: Could not connect to the server.
PIPELINE FIXTURE persisted: history count = 3
HISTORY STATE: count = 3, newest = "The quick brown fox jumps over the lazy dog." (cleanup_failed)
```
No crash, raw transcript preserved, entry marked `cleanup_failed`. Ollama was
then restarted (`ollama serve`, models re-warmed) and a follow-up run cleaned
normally again (`history count = 4`).

## Not automatable (needs mic + Accessibility → manual)

The full pill loop (record → paste) and the History row actions' UI. The mic
TCC prompt fires on the first pill click; injection needs the Accessibility
grant from v0.

### Manual checklist for John

1. Grant **Accessibility** if not already: System Settings → Privacy & Security →
   Accessibility → WisprLocal ON. (Injection silently no-ops into a log line without it.)
2. `./scripts/build.sh && ./scripts/run.sh`. Pill bottom-center, idle dots.
3. Click into TextEdit (or Notes/Slack), place the caret. Click the pill →
   **grant the mic prompt** (first time) → dots pulse (listening). Speak a sentence
   with some filler ("um so this is like a test of wispr local").
4. Click the pill again → sweeping-dot processing state → cleaned text pastes at
   the caret in the app you were in. Verify caret/target correct and text is cleaned.
5. Menubar → **Open History…** — the dictation is there (status `done`, duration,
   model). Expand "Raw transcript" and compare.
6. Row actions: **Copy** (paste it somewhere manually), **Insert at cursor**
   (focus a text field first, then click Insert — it activates your previous app
   and pastes), **Re-clean** (re-runs Ollama on the raw transcript in place).
7. Dictate a question ("what time is it") → the pasted text must be
   "What time is it?" — formatted, never answered.
8. Optional: quit Ollama (`pkill -f "ollama serve"`), dictate → raw transcript
   still pastes, entry shows `cleanup failed` badge; restart Ollama, hit
   **Re-clean** on that row → badge flips to `done`.

## Live audio-level meter (post-v1 polish)

The listening state now shows a **live rolling level histogram** instead of the
mock pulsing dots: 7 thin white bars (3 pt wide, 3–16 pt tall) whose heights
follow the last 7 smoothed mic levels, newest on the right, ~30 Hz updates.

- **Level source:** computed in the *existing* AudioRecorder input tap (no
  second tap), per converted buffer: RMS → dB → normalized over a −50…−10 dB
  window (quiet speech still registers), with asymmetric smoothing (attack
  0.6, decay 0.2 — lively onset, no inter-word jitter). Tap buffer size dropped
  4096 → 1600 frames (~33 ms ≈ 30 Hz).
- **Threading:** the tap callback runs on the audio thread; the coordinator
  hops to main (`DispatchQueue.main.async`) before touching the `@Published`
  `audioLevel` / `levelHistory` on `PillState`.
- **Teardown:** `resetLevels()` on stop + `pushLevel` guards on
  `phase == .listening` (drops stragglers queued on main), and the phase
  change swaps the meter view out entirely — no frozen bars.
- Idle (faint dots) and processing (sweep) are unchanged; `PulsingDots` removed.

**Verified** via a dev hook (`meterTest`: standalone recorder drives the meter
for 6 s, logs levels, discards audio — nothing transcribed/injected/persisted):

Ambient silence — bars low and flat:
```
METER TEST level[00] = 0.000 (bars: 0.00 0.00 0.00 0.00 0.00 0.00 0.00)
METER TEST level[08] = 0.005 (bars: 0.02 0.01 0.01 0.01 0.01 0.01 0.00)
```
Spoken audio (`say` through unmuted speakers) — bars rise and move:
```
METER TEST level[01] = 0.452 (bars: 0.45 0.42 0.38 0.43 0.40 0.48 0.45)
METER TEST level[08] = 0.405 (bars: 0.21 0.19 0.32 0.28 0.31 0.47 0.41)
```
Screenshots: `/tmp/pill-meter-silence.png`, `/tmp/pill-meter-speech.png`,
`/tmp/pill-meter-after.png` (idle dots restored — clean teardown). Output
volume was unmuted for the `say` stimulus and re-muted afterward.

**Manual check for John:** click the pill and talk — bars should track your
voice rhythm noticeably (close-mic speech will drive them higher than the
speaker-playback test did). If they feel too shy/too hot, tune `dbFloor` /
`dbCeiling` in `AudioRecorder`.

## History window redesign (Wispr Flow transcript style)

Re-skinned per `docs/history-design.md`: single centered column (max 760 pt),
warm off-white / deep-neutral backgrounds (system light+dark via
`colorScheme`), serif "History" title, right-aligned "Search transcripts"
field (live case-insensitive filter over cleaned + raw), date groups
(TODAY / YESTERDAY / `JULY 4, 2026` uppercase tracked headers), rows =
72 pt muted timestamp (`2:13 pm`) + 15 pt body with a light line-by-line
bullet renderer (`-`/`*`/`•` lines fold into bulleted lists) + hover-revealed
trailing actions (Copy icon with "copied" flash, ··· menu: Insert at cursor /
Re-clean with in-row spinner / Delete). Failure statuses show a small
amber/red dot by the timestamp; `done` shows nothing. Hairline dividers, no
cards. Window opens 820×720, resizable. Old disclosure-row layout removed.

**Verified:**
- Build clean; screenshots of both modes with real entries (incl. a bulleted
  transcript and the amber `cleanup_failed` dot):
  `/tmp/history-light.png`, `/tmp/history-dark.png`.
- `HistoryStore.delete` added and proven: disposable entry with a dummy WAV →
  delete → `DELETE CHECK: count 8 -> 7, audio file removed = true`.
- Search/hover/menu interactions are UI-manual: John should type in the search
  field (rows filter live, "No matches." on a dud query), hover a row (actions
  fade in), and try Copy / Insert / Re-clean / Delete once each.

## Notes / deviations

- History currently contains 4 test entries from the automated checks (one
  `persistence-check`, three fixture runs incl. one `cleanup_failed`) — useful
  for eyeballing the window; delete-row is a v2 feature so they'll age out via
  the 200-entry cap, or wipe `~/Library/Application Support/wispr-local/` for a
  clean slate.
- Recordings shorter than 0.3 s are discarded as stray double-clicks (constant
  in `DictationCoordinator`).
- Few-shot examples in `OllamaClient` are a deliberate addition beyond the
  spec's prompt (spec's instructions-only prompt demonstrably failed the
  question test on llama3.2:3b).
- v1 test hooks added alongside the v0 ones (`ollamaTest`, `historyTest`,
  `historyCount`, `pipelineFixture`) — dev-only, same DistributedNotificationCenter
  mechanism.
