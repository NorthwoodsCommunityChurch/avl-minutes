/// Turns diarizer slots into meeting labels for one stream.
/// Room: a line whose voice matches the voiceprint is "Me"; a slot whose matched
/// lines average above the threshold lends "Me" to its unmatched lines.
/// Others are numbered in order of first appearance. Call: always Caller n.
public struct SpeakerResolver: Sendable {
    private struct Vote: Sendable {
        var sum: Float = 0
        var count = 0
        var mean: Float { count == 0 ? 0 : sum / Float(count) }
    }

    public let source: Source
    public let threshold: Float
    private var votes: [Int: Vote] = [:]
    private var numbers: [Int: Int] = [:]
    private var nextNumber = 1

    public init(source: Source, threshold: Float = 0.5) {
        self.source = source
        self.threshold = threshold
    }

    /// `similarity` is nil when no voice comparison was possible for this line.
    public mutating func resolve(slot: Int?, similarity: Float?) -> SpeakerKey {
        guard let slot else { return .unknown }
        switch source {
        case .call:
            return .call(number(for: slot))
        case .room:
            if let similarity {
                votes[slot, default: Vote()].sum += similarity
                votes[slot, default: Vote()].count += 1
                return similarity >= threshold ? .me : .room(number(for: slot))
            }
            if let vote = votes[slot], vote.count > 0, vote.mean >= threshold { return .me }
            return .room(number(for: slot))
        }
    }

    private mutating func number(for slot: Int) -> Int {
        if let n = numbers[slot] { return n }
        let n = nextNumber
        numbers[slot] = n
        nextNumber += 1
        return n
    }
}
