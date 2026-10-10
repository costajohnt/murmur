import Foundation

/// The post-ASR decision logic of one dictation, with every side effect
/// (Ollama, brainstem, the status banner) injected as a closure so it can be
/// tested without a host app. It decides; `DictationCoordinator` acts on the
/// returned `Outcome` (paste, persist, pill state).
@MainActor
struct DictationPipeline {
    enum Delivery: Equatable {
        /// Sent to the vault; nothing to paste.
        case captured
        /// Paste `text` into the snapshotted target.
        case paste
        /// The target app quit before paste; don't inject, still persist.
        case targetGone
    }

    struct Outcome: Equatable {
        var text: String
        var status: DictationStatus
        var model: String
        var delivery: Delivery
        /// A warning was reported this run (cleanup unavailable, vault
        /// capture failed). A successful paste must not clear it.
        var degraded: Bool

        /// Only a fully clean run may clear a prior warning.
        var clearsWarning: Bool { status == .done && !degraded }
    }

    struct Cleanup: Equatable {
        var text: String
        var status: DictationStatus
        var model: String
        /// Ollama failed outright (banner-worthy), as opposed to rejecting
        /// its own output as not-a-reformat (quiet fallback).
        var unavailable: Bool
    }

    var mode: CleanupMode
    var resolveModel: () async -> String
    var clean: (_ text: String, _ model: String) async throws -> String
    /// nil = vault capture is off (no brainstem URL configured).
    var capture: ((String) async throws -> Void)?
    var report: (String) -> Void

    /// nil means discard: no meaningful speech, so nothing is cleaned,
    /// injected or persisted. `targetGone` is checked after cleanup and
    /// capture, since the target can quit while those run.
    func run(raw: String, targetGone: () -> Bool) async -> Outcome? {
        // Near-silence guard: a trivially short transcript is mic noise, and
        // the cleanup model invents content for it (observed: ASR "S" →
        // "Sorry, I didn't catch that...").
        guard TranscriptGuard.isMeaningful(raw) else {
            #if DEBUG
            Log.log("pipeline: no meaningful speech (raw=\"\(raw)\"), discarded")
            #else
            Log.log("pipeline: no meaningful speech (\(raw.count) chars), discarded")
            #endif
            return nil
        }

        // Vault-capture routing is decided on the RAW transcript, before
        // cleanup: cleanup can rewrite or drop the "note to self" trigger
        // (observed live). Only the stripped remainder is cleaned, so the
        // model never sees the trigger phrase.
        let remainder = capture == nil ? nil : BrainstemClient.noteToSelfRemainder(in: raw)
        let result = await cleanup(remainder ?? raw, notedRemainder: remainder != nil)
        if result.unavailable {
            report("Text cleanup unavailable (Ollama). Inserted the raw transcript.")
        }
        var outcome = Outcome(
            text: result.text, status: result.status, model: result.model,
            delivery: .paste, degraded: result.unavailable)

        if remainder != nil, let capture {
            do {
                try await capture(result.text)
                Log.log("pipeline vault-capture OK: \(result.text.count) chars")
                outcome.delivery = .captured
                return outcome
            } catch {
                // Restore the literal prefix rather than paying for a second
                // cleanup pass over the full raw transcript, and paste.
                Log.log("pipeline vault-capture FAILED (falling back to paste): \(error.localizedDescription)")
                report("Vault capture failed. Pasted the transcript instead.")
                outcome.text = "note to self: " + result.text
                outcome.degraded = true
            }
        }
        if targetGone() {
            outcome.delivery = .targetGone
        }
        return outcome
    }

    /// The cleanup decision matrix: off/light/full × success/failure. `.off`
    /// skips the LLM: text verbatim, persisted with the "raw" model sentinel
    /// (NOT "", which means cleanup was attempted and failed). On failure the
    /// input text is returned so the caller still has something to paste.
    func cleanup(_ text: String, notedRemainder: Bool = false) async -> Cleanup {
        guard mode != .off else {
            Log.log("pipeline cleanup: mode=off, injecting \(notedRemainder ? "note-to-self remainder" : "raw transcript") verbatim")
            return Cleanup(text: text.trimmingCharacters(in: .whitespacesAndNewlines), status: .done, model: "raw", unavailable: false)
        }
        let model = await resolveModel()
        do {
            let cleanStart = Date()
            let cleaned = try await clean(text, model)
            #if DEBUG
            Log.log(String(format: "pipeline cleanup (%@, mode=%@, %.2fs): \"%@\"", model, mode.rawValue, Date().timeIntervalSince(cleanStart), cleaned))
            #else
            Log.log(String(format: "pipeline cleanup (%@, mode=%@, %.2fs): %d chars", model, mode.rawValue, Date().timeIntervalSince(cleanStart), cleaned.count))
            #endif
            return Cleanup(text: cleaned, status: .done, model: model, unavailable: false)
        } catch OllamaClient.OllamaError.notAReformat {
            // Ollama works; the model answered or rewrote instead of
            // formatting. The input is the right text, so no banner.
            Log.log("pipeline cleanup REJECTED (output was not a reformat of the input), keeping the input")
            return Cleanup(text: text, status: .cleanupFailed, model: model, unavailable: false)
        } catch {
            Log.log("pipeline cleanup FAILED (keeping the input): \(error.localizedDescription)")
            return Cleanup(text: text, status: .cleanupFailed, model: "", unavailable: true)
        }
    }
}
