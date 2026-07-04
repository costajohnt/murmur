import Foundation

/// Verification harness for the near-silence transcript guard. Compiles the
/// REAL TranscriptGuard and checks the discard/keep boundary: stray single
/// characters and punctuation-only output are discarded; legit short words
/// and normal sentences pass.
///
/// Run: scripts/test-guard.sh
@main
struct GuardTest {
    static func main() {
        var failures = 0
        let discard = ["S", "s", ".", "", " ", "…", "- -", "??", "\n.\n", "7"]
        //             ^ single chars + punctuation-only (incl. 2+ char punct runs)
        let keep = ["no", "ok", "yes", "hi", "OK.", "42", "I do",
                    "What is the capital of France?",
                    "lets deploy to prox mocks over tail scale"]

        for raw in discard where TranscriptGuard.isMeaningful(raw) {
            failures += 1
            print("  FAIL: expected DISCARD for \"\(raw)\"")
        }
        for raw in keep where !TranscriptGuard.isMeaningful(raw) {
            failures += 1
            print("  FAIL: expected KEEP for \"\(raw)\"")
        }

        if failures == 0 {
            print("  PASS: all \(discard.count) discard cases discarded")
            print("  PASS: all \(keep.count) keep cases kept (incl. short words no/ok/yes)")
        }
        print("==== \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ====")
        exit(failures == 0 ? 0 : 1)
    }
}
