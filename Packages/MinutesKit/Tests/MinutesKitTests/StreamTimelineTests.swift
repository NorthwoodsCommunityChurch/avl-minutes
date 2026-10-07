import Foundation
import Testing
@testable import MinutesKit

// Buffers are 0.1 s of 16 kHz audio (1,600 frames), stamped with the meeting time
// at which each one arrived (its end).

@Test func continuousAudioKeepsTheFirstBuffersAnchor() {
    var timeline = StreamTimeline(sampleRate: 16_000)
    for i in 0..<100 { timeline.record(frames: 1_600, arrivedAt: 2.0 + Double(i + 1) * 0.1) }
    #expect(abs(timeline.meetingSeconds(forStreamSeconds: 0) - 2.0) < 0.001)
    #expect(abs(timeline.meetingSeconds(forStreamSeconds: 9.5) - 11.5) < 0.001)
}

@Test func aGapInCaptureShiftsOnlyLaterLines() {
    var timeline = StreamTimeline(sampleRate: 16_000)
    for i in 0..<50 { timeline.record(frames: 1_600, arrivedAt: Double(i + 1) * 0.1) }   // 0–5 s
    // Capture stalls for 10 s (watchdog rebuild), then resumes at meeting time 15 s.
    for i in 0..<50 { timeline.record(frames: 1_600, arrivedAt: 15.0 + Double(i + 1) * 0.1) }
    #expect(abs(timeline.meetingSeconds(forStreamSeconds: 4.0) - 4.0) < 0.001)
    #expect(abs(timeline.meetingSeconds(forStreamSeconds: 5.5) - 15.5) < 0.001)
    #expect(abs(timeline.meetingSeconds(forStreamSeconds: 9.9) - 19.9) < 0.001)
}

@Test func deliveryJitterDoesNotStartASegment() {
    var timeline = StreamTimeline(sampleRate: 16_000)
    // Buffers arrive in uneven bursts but keep pace with real time overall.
    let arrivals = [0.1, 0.35, 0.35, 0.4, 0.6, 0.6, 0.9, 0.9]
    for t in arrivals { timeline.record(frames: 1_600, arrivedAt: t) }
    #expect(timeline.segmentCount == 1)
    #expect(abs(timeline.meetingSeconds(forStreamSeconds: 0.7) - 0.7) < 0.001)
}

@Test func emptyTimelineMapsToMeetingStart() {
    let timeline = StreamTimeline(sampleRate: 16_000)
    #expect(timeline.meetingSeconds(forStreamSeconds: 3) == 3)
}
