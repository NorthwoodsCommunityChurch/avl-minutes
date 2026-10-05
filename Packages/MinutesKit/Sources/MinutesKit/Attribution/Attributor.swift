import Foundation

/// One recognized word (or token) with its stream time in seconds.
/// `text` carries its own leading space, exactly as the recognizer produced it.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Consecutive words attributed to one diarizer slot (nil = unknown).
public struct SlotLine: Sendable, Equatable {
    public let slot: Int?
    public let start: Double
    public let end: Double
    public let text: String

    public init(slot: Int?, start: Double, end: Double, text: String) {
        self.slot = slot
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Attributor {
    /// Each word takes its dominant slot; undecided words take the previous word's
    /// slot, or (at the start) the first decided slot. Same-slot runs become lines.
    public static func lines(for words: [TimedWord], activity: SpeakerActivity, minimum: Float = 0.3) -> [SlotLine] {
        guard !words.isEmpty else { return [] }
        let direct = words.map { activity.dominantSlot(from: $0.start, to: $0.end, minimum: minimum) }
        var slots = direct
        var previous: Int?
        for i in slots.indices {
            if let slot = slots[i] { previous = slot } else { slots[i] = previous }
        }
        if let firstKnown = direct.compactMap({ $0 }).first {
            for i in slots.indices {
                guard slots[i] == nil else { break }
                slots[i] = firstKnown
            }
        }

        var result: [SlotLine] = []
        var slot = slots[0]
        var start = words[0].start
        var end = words[0].end
        var text = words[0].text
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(SlotLine(slot: slot, start: start, end: end, text: trimmed)) }
        }
        for i in words.indices.dropFirst() {
            if slots[i] == slot {
                end = words[i].end
                text += words[i].text
            } else {
                flush()
                slot = slots[i]
                start = words[i].start
                end = words[i].end
                text = words[i].text
            }
        }
        flush()
        return result
    }
}

/// Holds recognized text until the diarizer has caught up with it.
public struct AttributionQueue: Sendable {
    private struct Pending: Sendable {
        let words: [TimedWord]
        let arrivedAt: Double
    }

    public let maxWait: Double
    private var pending: [Pending] = []

    public init(maxWait: Double = 5) { self.maxWait = maxWait }

    public var count: Int { pending.count }

    public mutating func enqueue(_ words: [TimedWord], arrivedAt: Double) {
        guard !words.isEmpty else { return }
        pending.append(Pending(words: words, arrivedAt: arrivedAt))
    }

    /// `now` is seconds of audio received on this stream. Releases items, in order,
    /// once diarization covers them, after `maxWait` seconds, or when flushing.
    public mutating func drain(activity: SpeakerActivity, now: Double, flush: Bool = false) -> [SlotLine] {
        var out: [SlotLine] = []
        while let first = pending.first {
            let end = first.words.map(\.end).max() ?? 0
            guard flush || activity.coveredUntil >= end || now - first.arrivedAt >= maxWait else { break }
            pending.removeFirst()
            out += Attributor.lines(for: first.words, activity: activity)
        }
        return out
    }
}
