import Foundation

/// Cuts a 16 kHz stream into short utterances by energy against an adaptive
/// noise floor. Only utterances wake-phrase length come out: long speech
/// (a meeting, music) is dropped without a transcription. Pure, so it is
/// tested with synthetic audio.
struct UtteranceSegmenter {
    static let sampleRate = AudioRecorder.sampleRate
    /// A chunk is speech when this far above the noise floor...
    static let speechMarginDb: Float = 12
    /// ...and above this absolute level, so a dead-quiet room's floor
    /// doesn't make breathing count.
    static let minSpeechDb: Float = -55
    /// Silence that ends an utterance.
    static let endSilence: TimeInterval = 0.5
    /// Audio kept from before speech onset, so the first syllable isn't cut.
    static let preRoll: TimeInterval = 0.3
    static let minUtterance: TimeInterval = 0.25
    static let maxUtterance: TimeInterval = 3.0

    private(set) var noiseFloorDb: Float = -60
    private var preRollBuffer: [Float] = []
    private var utterance: [Float] = []
    private var inSpeech = false
    private var speechSamples = 0
    private var silenceSamples = 0
    /// Speech ran past `maxUtterance`: ignore it until the next silence.
    private var overLong = false

    /// Feeds one chunk; returns a finished utterance when this chunk ended
    /// one that qualifies. It carries its `endSilence` tail, so it is always
    /// past Parakeet's 0.3 s minimum.
    mutating func feed(_ chunk: [Float]) -> [Float]? {
        guard !chunk.isEmpty else { return nil }
        let db = Self.rmsDb(chunk)
        let isSpeech = db > max(noiseFloorDb + Self.speechMarginDb, Self.minSpeechDb)

        if !inSpeech {
            if isSpeech {
                inSpeech = true
                overLong = false
                utterance = preRollBuffer + chunk
                speechSamples = chunk.count
                silenceSamples = 0
                preRollBuffer.removeAll()
            } else {
                // Track the floor only between utterances, slowly.
                noiseFloorDb += 0.05 * (db - noiseFloorDb)
                preRollBuffer.append(contentsOf: chunk)
                let keep = Int(Self.preRoll * Self.sampleRate)
                if preRollBuffer.count > keep {
                    preRollBuffer.removeFirst(preRollBuffer.count - keep)
                }
            }
            return nil
        }

        if !overLong { utterance.append(contentsOf: chunk) }
        if overLong {
            // Sustained sound (fan, music, a room louder than the starting
            // floor): let the floor climb to it, or the segmenter would stay
            // "in speech" and deaf until the room went quiet.
            noiseFloorDb += 0.05 * (db - noiseFloorDb)
        }
        if isSpeech {
            speechSamples += chunk.count + silenceSamples
            silenceSamples = 0
            if Double(speechSamples) > Self.maxUtterance * Self.sampleRate {
                overLong = true
                utterance.removeAll()
            }
            return nil
        }
        silenceSamples += chunk.count
        guard Double(silenceSamples) >= Self.endSilence * Self.sampleRate else { return nil }

        inSpeech = false
        let finished = utterance
        utterance.removeAll()
        guard !overLong, Double(speechSamples) >= Self.minUtterance * Self.sampleRate else { return nil }
        return finished
    }

    static func rmsDb(_ chunk: [Float]) -> Float {
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        return 20 * log10(max((sum / Float(chunk.count)).squareRoot(), 1e-7))
    }
}
