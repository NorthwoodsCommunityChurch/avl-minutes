import Foundation
import Testing
@testable import MinutesKit

private let chicago = TimeZone(identifier: "America/Chicago")!
// Monday, October 5, 2026 2:00:00 PM CDT
private let start = Date(timeIntervalSince1970: 1_791_226_800)

private func line(_ ms: Int, _ speaker: SpeakerKey, _ text: String, _ source: Source = .room) -> TranscriptLine {
    TranscriptLine(startMs: ms, endMs: ms + 1000, source: source, speaker: speaker, text: text)
}

@Test func linesStaySortedWhenStreamsArriveOutOfOrder() {
    var doc = TranscriptDocument(title: "T", startedAt: start, sources: [.room, .call])
    doc.append(line(5000, .me, "second"))
    doc.append(line(9000, .me, "third"))
    doc.append(line(1000, .call(1), "first", .call))
    doc.append(line(5000, .call(1), "second-b", .call))   // tie keeps arrival order
    #expect(doc.lines.map(\.text) == ["first", "second", "second-b", "third"])
}

@Test func htmlEscapesAndFormats() {
    var doc = TranscriptDocument(title: "Budget <draft> & plan", startedAt: start, sources: [.room])
    doc.append(line(3_723_000, .room(2), "use <b>bold</b> & \"quotes\""))
    doc.endedAt = start.addingTimeInterval(47 * 60)
    let html = doc.html(timeZone: chicago, now: start)
    #expect(html.contains("<h1>Budget &lt;draft&gt; &amp; plan</h1>"))
    #expect(html.contains("Monday, October 5, 2026 · 2:00 PM · 47 min · Room"))
    #expect(html.contains("<b>[01:02:03] Speaker 2:</b> use &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quotes&quot;"))
    #expect(html.contains("Audio was not recorded."))
}

@Test func headerShowsInProgressUntilEnded() {
    let doc = TranscriptDocument(title: "T", startedAt: start, sources: [.room, .call])
    let html = doc.html(timeZone: chicago, now: start.addingTimeInterval(600))
    #expect(html.contains("2:00 PM · in progress · Room and call"))
}

@Test func shortMeetingRoundsUpToOneMinute() {
    var doc = TranscriptDocument(title: "T", startedAt: start, sources: [.call])
    doc.endedAt = start.addingTimeInterval(20)
    #expect(doc.html(timeZone: chicago, now: start).contains("· 1 min · Call"))
}

@Test func plainTextMatchesLines() {
    var doc = TranscriptDocument(title: "Sync", startedAt: start, sources: [.room])
    doc.append(line(7000, .me, "Hello & welcome"))
    doc.endedAt = start.addingTimeInterval(120)
    let text = doc.plainText(timeZone: chicago, now: start)
    #expect(text.hasPrefix("Sync\nMonday, October 5, 2026 · 2:00 PM · 2 min · Room\n"))
    #expect(text.hasSuffix("[00:00:07] Me: Hello & welcome"))
}

@Test func defaultTitleUsesShortDate() {
    #expect(TranscriptDocument.defaultTitle(for: start, timeZone: chicago) == "Meeting — Mon Oct 5, 2:00 PM")
}
