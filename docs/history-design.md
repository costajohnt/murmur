# History window redesign — Wispr Flow transcript style

Redesign `HistoryView` to match Wispr Flow's transcript-history screen (John shared a reference screenshot). **Scope: the transcript history only.** No left nav sidebar. No stats/word-count card (John only cares about the transcripts — leave a clean hook to add stats later, but don't build them now). Keep the existing `HistoryStore` model and the Copy / Insert / Re-clean actions; this is a re-skin + search + delete, not a data-model change.

## Overall layout
- A single **centered scrolling column** of transcript entries, comfortable max width (~740–780 pt), on a light, airy background. Generous vertical rhythm.
- Respect system appearance: design **light AND dark**. The reference is light (warm off-white ~ `#F7F6F3`, near-black text); provide a tasteful dark equivalent (deep neutral bg, off-white text). Don't hardcode one.
- Top of the list: a slim header row with a **search field** (magnifier icon, placeholder "Search transcripts"), right-aligned like the reference. Live-filters entries by matching cleaned or raw text (case-insensitive).
- Optional minimal title (e.g. "History") — keep it understated or omit. Do NOT add "Welcome back" / streaks / word counts.

## Date grouping
- Group entries by calendar day, newest day first, newest entry first within a day.
- Each group starts with a **date header**: uppercase, letter-spaced, small, muted gray — e.g. `JULY 4, 2026`. Use "Today" / "Yesterday" for the two most recent days, else the full date.

## Entry row
Mirror the reference row:
- **Left:** timestamp, fixed ~72 pt column, muted gray, e.g. `2:13 pm`.
- **Body:** the cleaned transcript text. Readable size (~15–16 pt), near-black/off-white, comfortable line spacing. **Render light markdown:** preserve paragraph breaks and render lines beginning with `-`, `*`, or `•` as a bulleted list (the reference shows bulleted transcripts). No heavy markdown engine needed — a simple line-by-line renderer is fine.
- **Trailing actions**, revealed on row hover (fade in), vertically aligned to the top of the body:
  - **Copy** icon → cleaned text to clipboard (brief "copied" affordance is nice).
  - **More (···) menu** → **Insert at cursor** (TextInjector into the tracked target app), **Re-clean** (re-run Ollama on stored raw, update in place), **Delete** (remove the entry AND its audio file on disk; confirm inline or just do it).
- **Status:** for `cleanupFailed` / `asrFailed`, show a small, subtle badge/dot near the timestamp (muted amber/red) so failures are visible without shouting. `done` shows nothing.
- Thin hairline **divider** between rows (not around each row — flat, like the reference, not cards).

## Behavior
- Live search filter; empty result → subtle "No matches."
- Empty history → friendly empty state: "No transcripts yet — click the pill and start talking."
- Re-clean should show a brief in-row processing indicator and then update the text.
- Delete removes the row with a light animation and deletes the backing WAV.

## Fidelity notes
- Match the *flat, editorial* feel: lots of whitespace, thin dividers, muted metadata, one strong text column. Avoid card chrome, shadows, or heavy borders.
- System font (SF Pro) is fine for the body. A serif (`.system(design: .serif)`) for the date headers or a title is optional if it improves fidelity — your call, keep it tasteful.
- The window should open at a sensible size (~820×720) and be resizable.

## Guardrails
- Keep `HistoryStore` / `Dictation` model and actions intact; add `delete` if not present.
- Build clean via `scripts/build.sh`. Capture 1–2 screenshots (light, and dark if quick) of the redesigned window with the existing test entries so we can eyeball fidelity.
- NO commit/push. Stay in `~/dev/wispr-local`. Report build output, screenshots/verification, and `git status --short`.
