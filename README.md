# wispr-local

A local, offline clone of [Wispr Flow](https://wisprflow.ai) for macOS (Apple Silicon). System-wide voice dictation with no cloud: your voice never leaves the machine.

Click a floating on-screen button (or a hotkey), speak, and the cleaned-up text is inserted at your cursor in whatever app is focused. A history window keeps every dictation so you can copy, re-insert, or regenerate any of them.

## How it works

Four-stage local pipeline, each stage on the right piece of Apple Silicon:

1. **Capture** — `AVAudioEngine` records mic audio on trigger.
2. **Transcribe** — [FluidAudio](https://github.com/FluidInference/FluidAudio) runs NVIDIA Parakeet via CoreML on the **Apple Neural Engine** (~66 MB, leaves the GPU free).
3. **Clean up** — a small local LLM served by **Ollama** (on the GPU) fixes punctuation, removes filler words, and formats. It reformats; it never answers.
4. **Inject** — pasteboard-then-paste (`CGEvent` ⌘V) drops the text at the cursor.

Because ASR sits on the Neural Engine and the LLM on the GPU, both stay resident with no contention even on a 24 GB machine.

## Targets

- Apple **M4 / 24 GB** — tight-memory target; cleanup model `llama3.2:3b`.
- Apple **M5 Max / 64 GB** — cleanup model auto-steps up to `qwen2.5:7b`.

Requires macOS 14+ and a running Ollama (`ollama serve`).

## Status

Early build. See [`docs/PLAN.md`](docs/PLAN.md) for the full architecture and [`docs/v0-spikes.md`](docs/v0-spikes.md) for the current de-risking spikes.

## Prior art (read, not forked)

Handy (MIT), VoiceInk (GPL-3.0), local-whisper, OpenWhispr (MIT). Built fresh in Swift to keep the stack native, memory-frugal, and free of copyleft.
