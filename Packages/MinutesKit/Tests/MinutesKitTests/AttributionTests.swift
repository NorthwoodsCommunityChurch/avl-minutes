import Testing
@testable import MinutesKit

/// Builds activity where each listed second is dominated by one slot (0.9) and others 0.05.
private func activity(_ secondsBySlot: [Int?], frame: Double = 0.5) -> SpeakerActivity {
    var a = SpeakerActivity(frameDuration: frame, slotCount: 4)
    var preds: [Float] = []
    for slot in secondsBySlot {
        for _ in 0..<Int(1 / frame) {
            for s in 0..<4 { preds.append(slot == s ? 0.9 : 0.05) }
        }
    }
    a.append(startFrame: 0, predictions: preds)
    return a
}

private func w(_ text: String, _ start: Double, _ end: Double) -> TimedWord { TimedWord(text: text, start: start, end: end) }

@Test func dominantSlotPicksHighestMean() {
    let a = activity([0, 0, 1, 1])
    #expect(a.dominantSlot(from: 0.2, to: 1.4) == 0)
    #expect(a.dominantSlot(from: 2.1, to: 2.3) == 1)
    #expect(a.coveredUntil == 4.0)
}

@Test func silenceAndUncoveredTimeGiveNil() {
    let a = activity([nil, 2])
    #expect(a.dominantSlot(from: 0.0, to: 0.9) == nil)   // all slots 0.05 < 0.3
    #expect(a.dominantSlot(from: 5.0, to: 6.0) == nil)   // not diarized yet
}

@Test func appendPadsGapsSkipsOverlapAndTrims() {
    var a = SpeakerActivity(frameDuration: 1, slotCount: 1, maxSeconds: 5)
    a.append(startFrame: 0, predictions: [0.9, 0.9])
    a.append(startFrame: 4, predictions: [0.8])            // gap of frames 2,3 padded with 0
    #expect(a.endFrame == 5)
    #expect(a.dominantSlot(from: 2, to: 3) == nil)
    a.append(startFrame: 3, predictions: [0.1, 0.1, 0.7])  // frames 3,4 overlap; only frame 5 added
    #expect(a.endFrame == 6)
    #expect(a.dominantSlot(from: 4, to: 5) == 0)           // kept 0.8, not overwritten by 0.1
    a.append(startFrame: 6, predictions: [0.9, 0.9, 0.9])
    #expect(a.firstFrame == 4)                             // trimmed to 5 frames
    #expect(a.dominantSlot(from: 0, to: 1) == nil)
}

@Test func speakerChangeMidSentenceSplitsLines() {
    let a = activity([0, 0, 1, 1])
    let words = [w("So", 0.1, 0.4), w(" we", 0.5, 0.8), w(" agree.", 1.0, 1.6), w(" Yes", 2.2, 2.6), w(" totally.", 2.7, 3.4)]
    let lines = Attributor.lines(for: words, activity: a)
    #expect(lines == [
        SlotLine(slot: 0, start: 0.1, end: 1.6, text: "So we agree."),
        SlotLine(slot: 1, start: 2.2, end: 3.4, text: "Yes totally."),
    ])
}

@Test func undecidedWordsFollowNeighbors() {
    let a = activity([nil, 1, nil])
    let words = [w("Um", 0.1, 0.3), w(" right", 1.1, 1.5), w(" okay", 2.2, 2.6)]
    #expect(Attributor.lines(for: words, activity: a) == [SlotLine(slot: 1, start: 0.1, end: 2.6, text: "Um right okay")])
}

@Test func noDiarizationGivesNilSlot() {
    let a = SpeakerActivity(frameDuration: 0.08, slotCount: 4)
    let lines = Attributor.lines(for: [w("Hello", 0, 0.5)], activity: a)
    #expect(lines == [SlotLine(slot: nil, start: 0, end: 0.5, text: "Hello")])
}

@Test func queueWaitsForCoverageThenTimesOut() {
    var queue = AttributionQueue(maxWait: 5)
    let a = activity([0, 0])                                  // covered until 2.0
    queue.enqueue([w("early", 0.5, 1.5)], arrivedAt: 2)
    queue.enqueue([w("late", 2.5, 3.5)], arrivedAt: 4)
    #expect(queue.drain(activity: a, now: 4).map(\.text) == ["early"])
    #expect(queue.drain(activity: a, now: 8.9).isEmpty)       // waited 4.9 s
    #expect(queue.drain(activity: a, now: 9).map(\.text) == ["late"])
    #expect(queue.count == 0)
}

@Test func flushDrainsEverything() {
    var queue = AttributionQueue()
    queue.enqueue([w("a", 10, 11)], arrivedAt: 11)
    queue.enqueue([], arrivedAt: 11)                          // ignored
    #expect(queue.drain(activity: activity([]), now: 11, flush: true).map(\.text) == ["a"])
}
