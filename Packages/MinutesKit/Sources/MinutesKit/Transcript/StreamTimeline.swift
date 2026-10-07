import Foundation

/// Maps a capture stream's own clock (how many samples it has delivered) to meeting
/// time. Speech and speaker models time everything by samples, so when capture stalls
/// or restarts (a mic device change, a call-tap rebuild), sample time falls behind the
/// wall clock. Each such gap starts a new segment, so lines after a gap keep their real
/// meeting time and stay in order with the other stream.
public struct StreamTimeline: Sendable {
    /// Arriving this much later than the samples account for counts as a gap.
    public static let gapThreshold: TimeInterval = 0.5

    public let sampleRate: Double
    private var segments: [Segment] = []
    private var framesSoFar = 0

    private struct Segment: Sendable {
        let streamStart: Double
        let meetingStart: Double
    }

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public var segmentCount: Int { segments.count }

    /// Records a buffer of `frames` samples that arrived at `meetingTime` (seconds since
    /// the meeting started; the buffer's end).
    public mutating func record(frames: Int, arrivedAt meetingTime: TimeInterval) {
        let streamStart = Double(framesSoFar) / sampleRate
        let bufferStart = meetingTime - Double(frames) / sampleRate
        if let last = segments.last {
            let expected = last.meetingStart + (streamStart - last.streamStart)
            if bufferStart - expected > Self.gapThreshold {
                segments.append(Segment(streamStart: streamStart, meetingStart: bufferStart))
            }
        } else {
            segments.append(Segment(streamStart: streamStart, meetingStart: max(0, bufferStart)))
        }
        framesSoFar += frames
    }

    /// Meeting time for a position on the stream's sample clock.
    public func meetingSeconds(forStreamSeconds seconds: Double) -> Double {
        guard let segment = segments.last(where: { $0.streamStart <= seconds }) ?? segments.first else {
            return seconds
        }
        return segment.meetingStart + (seconds - segment.streamStart)
    }
}
