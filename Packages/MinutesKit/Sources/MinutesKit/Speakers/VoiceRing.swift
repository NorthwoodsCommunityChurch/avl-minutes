/// The last `seconds` of one stream's 16 kHz audio, in RAM only, so a finished
/// line can be compared with the voiceprint. Overwritten continuously; wiped on Stop.
public struct VoiceRing: Sendable {
    public let sampleRate: Double
    public let capacity: Int
    public private(set) var totalWritten = 0
    private var storage: [Float]

    public init(sampleRate: Double = 16_000, seconds: Double = 60) {
        self.sampleRate = sampleRate
        self.capacity = max(1, Int(sampleRate * seconds))
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Sample n of the stream lives at storage[n % capacity].
    public mutating func append(_ samples: [Float]) {
        var input = samples[...]
        if input.count > capacity {
            totalWritten += input.count - capacity
            input = input.suffix(capacity)
        }
        for sample in input {
            storage[totalWritten % capacity] = sample
            totalWritten += 1
        }
    }

    /// Audio for [start, end) seconds of stream time, or nil if any of it has been
    /// overwritten or not yet received.
    public func samples(from start: Double, to end: Double) -> [Float]? {
        let lo = Int((start * sampleRate).rounded(.down))
        let hi = Int((end * sampleRate).rounded(.up))
        guard lo >= 0, hi > lo, hi <= totalWritten, lo >= totalWritten - capacity else { return nil }
        return (lo..<hi).map { storage[$0 % capacity] }
    }

    /// Overwrites the buffer in place with zeros and resets the clock.
    public mutating func wipe() {
        storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        totalWritten = 0
    }

    var isWiped: Bool { totalWritten == 0 && storage.allSatisfy { $0 == 0 } }
}
