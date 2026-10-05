/// Rolling window of finalized per-frame speaker probabilities from the diarizer.
/// Frame f covers stream time [f * frameDuration, (f + 1) * frameDuration).
public struct SpeakerActivity: Sendable {
    public let frameDuration: Double
    public let slotCount: Int
    public let maxFrames: Int
    public private(set) var firstFrame = 0
    private var probabilities: [Float] = []

    public init(frameDuration: Double, slotCount: Int, maxSeconds: Double = 120) {
        precondition(frameDuration > 0 && slotCount > 0)
        self.frameDuration = frameDuration
        self.slotCount = slotCount
        self.maxFrames = max(1, Int((maxSeconds / frameDuration).rounded(.up)))
    }

    public var frameCount: Int { probabilities.count / slotCount }
    public var endFrame: Int { firstFrame + frameCount }
    public var coveredUntil: Double { Double(endFrame) * frameDuration }

    /// Adds finalized frames starting at global frame `startFrame`. Gaps are padded
    /// with silence; frames already present are kept (finalized data never changes).
    public mutating func append(startFrame: Int, predictions: [Float]) {
        guard !predictions.isEmpty, predictions.count % slotCount == 0 else { return }
        var newFrames = predictions[...]
        if probabilities.isEmpty {
            firstFrame = startFrame
        } else if startFrame > endFrame {
            probabilities += [Float](repeating: 0, count: (startFrame - endFrame) * slotCount)
        } else if startFrame < endFrame {
            let overlap = (endFrame - startFrame) * slotCount
            guard overlap < newFrames.count else { return }
            newFrames = newFrames.dropFirst(overlap)
        }
        probabilities += newFrames
        let excess = frameCount - maxFrames
        if excess > 0 {
            probabilities.removeFirst(excess * slotCount)
            firstFrame += excess
        }
    }

    /// The slot with the highest mean probability over [start, end), if that mean
    /// reaches `minimum`. Nil when the range is silent or outside the window.
    public func dominantSlot(from start: Double, to end: Double, minimum: Float = 0.3) -> Int? {
        let startFrameRaw = Int((start / frameDuration).rounded(.down))
        let lo = max(startFrameRaw, firstFrame)
        let hi = min(max(Int((end / frameDuration).rounded(.up)), startFrameRaw + 1), endFrame)
        guard lo < hi else { return nil }
        var sums = [Float](repeating: 0, count: slotCount)
        for frame in lo..<hi {
            let base = (frame - firstFrame) * slotCount
            for slot in 0..<slotCount { sums[slot] += probabilities[base + slot] }
        }
        var best = 0
        for slot in 1..<slotCount where sums[slot] > sums[best] { best = slot }
        return sums[best] / Float(hi - lo) >= minimum ? best : nil
    }
}
