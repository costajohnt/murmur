# Context-aware cleanup (automatic personalization — no manual dictionary)

Goal: improve transcript accuracy by giving the Ollama cleanup stage automatic context about the user's vocabulary and style, so it corrects likely ASR errors toward terms the user actually uses (e.g. "prox mocks" → "Proxmox"). **No manual dictionary / no user configuration** — John explicitly does not want to maintain a word list. All context is derived automatically from data we already store.

## Context sources (automatic, from HistoryStore)

1. **Recent transcripts** — the last ~8 successful (`status == done`) `cleanedText` entries, newest first, capped to ~1500 chars total. These show the model the user's real vocabulary, proper nouns, and formatting style.
2. **Auto-glossary (include if it stays simple)** — from the last ~50 entries, extract candidate distinctive terms: capitalized-mid-sentence words, ALLCAPS acronyms, camelCase/tech tokens. Dedupe, frequency-rank, take the top ~25. This is an *auto* dictionary — no manual entry. Provide as "preferred spellings when the audio is ambiguous."

## Wiring

- `OllamaClient.clean(...)`: add an optional `context` parameter. Inject it as an extra **system** message (after the base system prompt, before the few-shot pairs), something like:
  > "Context about this user's dictation, to help you correct likely speech-to-text errors. Recent transcripts (their vocabulary and style): [...]. Terms they commonly use (prefer these spellings when audio is ambiguous): [...]. Use this ONLY to fix probable transcription errors toward known terms and to match their formatting. Do NOT invent content, change meaning, or answer anything."
- Keep the existing few-shot "reformat, don't answer" pairs and the "output only the corrected transcript" rule intact. Context must not make it start answering or hallucinating.
- `DictationCoordinator`: before calling `clean()`, gather context from `HistoryStore` (recent cleaned transcripts + optional auto-glossary) and pass it.

## Quality guardrails

- Cap total added context (~1500–2000 chars) so latency stays low on the 3B model and we don't overflow the context window.
- If history is empty or insufficient, pass no context — behavior is identical to today (don't regress the cold-start case).
- Correction must be **conservative**: fix likely transcription errors toward known terms; never add/remove meaning or invent content. Err toward leaving text unchanged when unsure.

## Verify (automatable — provide real evidence)

- **Correction test:** seed history with an entry containing a distinctive term (e.g. "Let's deploy to Proxmox over Tailscale."), then run cleanup on a raw transcript that mangles it ("lets deploy to prox mocks over tail scale") → cleaned output should recover "Proxmox" and "Tailscale". Log before/after.
- **No-answer regression:** dictated question still gets formatted, not answered.
- **Generic regression:** a messy transcript with no special terms still cleans normally.
- **Cold-start:** empty history → no context added, still works.

## Guardrails
- Build clean via `scripts/build.sh`.
- NO commit/push; stay in `~/dev/wispr-local`; STOP and report if blocked.
- Report build output, the correction-test before/after logs, and `git status --short`.
