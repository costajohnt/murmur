import Foundation

/// Verification harness for the Settings panel logic (docs/settings-panel.md).
/// Compiles the REAL production sources (OllamaClient, AppSettings, Log) and
/// verifies against live Ollama:
///   1. tone presets: faithful is byte-identical to the base prompt; polished
///      and casual both CONTAIN the full base prompt (guard intact) + a style
///      layer; all three distinct
///   2. resolveModel: no override → auto; installed override honored;
///      not-installed override falls back to auto
///   3. live clean() with polished/casual tone: dictated question still
///      formatted, not answered (guard survives every preset)
/// UserDefaults here is the harness process's own domain, so nothing leaks
/// into the real app's preferences.
///
/// Run: scripts/test-settings.sh
@main
struct SettingsTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, detail: String = "") {
        if condition {
            print("  PASS: \(name)")
        } else {
            failures += 1
            print("  FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() async {
        // ---- 1. Tone presets ----
        print("=== 1. Tone presets keep the don't-answer core ===")
        let base = OllamaClient.systemPrompt
        check("faithful == base prompt (byte-identical)",
              OllamaClient.systemPrompt(for: .faithful) == base)
        for tone in [TonePreset.polished, .casual] {
            let prompt = OllamaClient.systemPrompt(for: tone)
            check("\(tone.rawValue) contains full base prompt", prompt.hasPrefix(base))
            check("\(tone.rawValue) adds a style layer", prompt.count > base.count)
        }
        check("all tone prompts distinct",
              Set(TonePreset.allCases.map { OllamaClient.systemPrompt(for: $0) }).count == TonePreset.allCases.count)

        // ---- 2. resolveModel override behavior (live Ollama tags) ----
        print("\n=== 2. resolveModel override behavior ===")
        let defaults = UserDefaults.standard
        let client = OllamaClient()

        guard let installed = try? await client.installedModels(), !installed.isEmpty else {
            print("  FAIL: Ollama unreachable — cannot run resolveModel tests")
            failures += 1
            finish()
            return
        }
        print("  installed: \(installed)")

        defaults.removeObject(forKey: AppSettings.cleanupModelOverrideKey)
        let auto = await client.resolveModel()
        print("  no override → \(auto)")
        check("no override → auto behavior", installed.contains(auto))

        // Pick an installed model that auto would NOT pick, to prove the
        // override is honored.
        let overrideChoice = installed.first { $0 != auto } ?? installed[0]
        defaults.set(overrideChoice, forKey: AppSettings.cleanupModelOverrideKey)
        let resolvedOverride = await client.resolveModel()
        print("  override \(overrideChoice) → \(resolvedOverride)")
        check("installed override honored", resolvedOverride == overrideChoice)

        defaults.set("ghost-model:99b", forKey: AppSettings.cleanupModelOverrideKey)
        let resolvedStale = await client.resolveModel()
        print("  override ghost-model:99b → \(resolvedStale)")
        check("stale override falls back to auto", resolvedStale == auto)

        defaults.removeObject(forKey: AppSettings.cleanupModelOverrideKey)

        // ---- 3. Live no-answer guard per preset ----
        print("\n=== 3. Question stays a question in every preset (live) ===")
        for tone in TonePreset.allCases {
            do {
                let out = try await client.clean(
                    "um so whats the capital of france", model: auto, tone: tone)
                let lower = out.lowercased()
                print("  [\(tone.rawValue)] → \"\(out)\"")
                check("\(tone.rawValue): formatted, not answered",
                      lower.contains("capital of france") && !lower.contains("paris"),
                      detail: out)
            } catch {
                failures += 1
                print("  FAIL: \(tone.rawValue) clean() threw: \(error.localizedDescription)")
            }
        }

        // Generic messy transcript through polished + casual (tone smoke test).
        print("\n=== 4. Messy transcript per preset (live) ===")
        for tone in TonePreset.allCases {
            do {
                let out = try await client.clean(
                    "so um i think we should uh push the meeting to like three pm tomorrow",
                    model: auto, tone: tone)
                let lower = out.lowercased()
                print("  [\(tone.rawValue)] → \"\(out)\"")
                check("\(tone.rawValue): fillers removed, meaning kept",
                      !lower.contains("um") && lower.contains("meeting"),
                      detail: out)
            } catch {
                failures += 1
                print("  FAIL: \(tone.rawValue) clean() threw: \(error.localizedDescription)")
            }
        }

        finish()
    }

    static func finish() {
        print("\n==== \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ====")
        exit(failures == 0 ? 0 : 1)
    }
}
