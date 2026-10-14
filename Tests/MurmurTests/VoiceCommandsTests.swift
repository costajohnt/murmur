import XCTest

final class VoiceCommandsTests: XCTestCase {
    func testStripsTrailingSendWord() {
        XCTAssertEqual(VoiceCommands.stripSendWord(from: "Run the tests, send.", sendWord: "send"), "Run the tests")
        XCTAssertEqual(VoiceCommands.stripSendWord(from: "list files Send", sendWord: "send"), "list files")
        XCTAssertEqual(VoiceCommands.stripSendWord(from: "Ship it. Send it!", sendWord: "Send it"), "Ship it.")
    }

    func testSendWordAloneLeavesEmptyRemainder() {
        XCTAssertEqual(VoiceCommands.stripSendWord(from: "Send.", sendWord: "send"), "")
    }

    func testNoMatchUnlessItIsTheLastWord() {
        XCTAssertNil(VoiceCommands.stripSendWord(from: "send the report today", sendWord: "send"))
        XCTAssertNil(VoiceCommands.stripSendWord(from: "please resend", sendWord: "send"))
        XCTAssertNil(VoiceCommands.stripSendWord(from: "anything", sendWord: "  "))
    }

    func testWakePhraseMatchesAcrossPunctuationAndSlips() {
        XCTAssertTrue(VoiceCommands.containsWakePhrase("Hey, Murmur.", phrase: "hey murmur"))
        XCTAssertTrue(VoiceCommands.containsWakePhrase("hey murmer", phrase: "hey murmur"))
        XCTAssertTrue(VoiceCommands.containsWakePhrase("Hey mur mur", phrase: "hey murmur"))
        XCTAssertTrue(VoiceCommands.containsWakePhrase("okay so hey murmur", phrase: "hey murmur"))
    }

    func testWakePhraseRejectsOtherSpeech() {
        XCTAssertFalse(VoiceCommands.containsWakePhrase("hey mother", phrase: "hey murmur"))
        XCTAssertFalse(VoiceCommands.containsWakePhrase("murmur", phrase: "hey murmur"))
        XCTAssertFalse(VoiceCommands.containsWakePhrase("", phrase: "hey murmur"))
        XCTAssertFalse(VoiceCommands.containsWakePhrase("hey murmur", phrase: ""))
    }
}

final class UtteranceSegmenterTests: XCTestCase {
    private let chunk = 512 // ~32 ms at 16 kHz, like the real tap

    private func feed(_ s: inout UtteranceSegmenter, amplitude: Float, seconds: Double) -> [[Float]] {
        var out: [[Float]] = []
        for _ in 0..<Int(seconds * 16_000 / Double(chunk)) {
            if let u = s.feed(Array(repeating: amplitude, count: chunk)) { out.append(u) }
        }
        return out
    }

    func testShortPhraseBetweenSilencesIsEmitted() {
        var s = UtteranceSegmenter()
        XCTAssertTrue(feed(&s, amplitude: 0.0005, seconds: 1).isEmpty) // room tone
        XCTAssertTrue(feed(&s, amplitude: 0.1, seconds: 0.6).isEmpty)
        let out = feed(&s, amplitude: 0.0005, seconds: 0.7)
        XCTAssertEqual(out.count, 1)
        // Pre-roll + speech + the silence tail that ended it.
        XCTAssertGreaterThanOrEqual(out.first?.count ?? 0, Int(16_000 * 1.1))
    }

    func testLongSpeechIsDropped() {
        var s = UtteranceSegmenter()
        _ = feed(&s, amplitude: 0.0005, seconds: 1)
        XCTAssertTrue(feed(&s, amplitude: 0.1, seconds: 5).isEmpty)
        XCTAssertTrue(feed(&s, amplitude: 0.0005, seconds: 1).isEmpty)
        // And it recovers for the next short phrase.
        _ = feed(&s, amplitude: 0.1, seconds: 0.6)
        XCTAssertEqual(feed(&s, amplitude: 0.0005, seconds: 0.7).count, 1)
    }

    func testSustainedLoudRoomBecomesTheFloor() {
        var s = UtteranceSegmenter()
        // ~-44 dBFS steady noise from the first chunk, above the initial floor.
        XCTAssertTrue(feed(&s, amplitude: 0.006, seconds: 6).isEmpty)
        // A louder short phrase over that noise still comes out.
        _ = feed(&s, amplitude: 0.1, seconds: 0.6)
        XCTAssertEqual(feed(&s, amplitude: 0.006, seconds: 0.7).count, 1)
    }

    func testPauseDetectorFiresOncePerPause() {
        var d = PauseDetector()
        func run(_ amplitude: Float, _ seconds: Double) -> Int {
            (0..<Int(seconds * 16_000 / 512)).filter { _ in d.feed(Array(repeating: amplitude, count: 512)) }.count
        }
        XCTAssertEqual(run(0.0005, 1), 0, "no speech yet, no pause")
        XCTAssertEqual(run(0.1, 1), 0)
        XCTAssertEqual(run(0.0005, 2), 1, "one pause, fired once")
        XCTAssertEqual(run(0.1, 0.5), 0)
        XCTAssertEqual(run(0.0005, 1), 1)
    }

    func testBlipIsDropped() {
        var s = UtteranceSegmenter()
        _ = feed(&s, amplitude: 0.0005, seconds: 1)
        _ = feed(&s, amplitude: 0.1, seconds: 0.1)
        XCTAssertTrue(feed(&s, amplitude: 0.0005, seconds: 1).isEmpty)
    }
}
