import Foundation

/// One finished line of a transcript, in meeting time.
public struct TranscriptLine: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let source: Source
    public let speaker: SpeakerKey
    public let text: String

    public init(startMs: Int, endMs: Int, source: Source, speaker: SpeakerKey, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.source = source
        self.speaker = speaker
        self.text = text
    }
}

/// A meeting transcript held in memory and rendered into an Apple Notes body.
public struct TranscriptDocument: Sendable {
    public var title: String
    public let startedAt: Date
    public var endedAt: Date?
    public var sources: Set<Source>
    public private(set) var lines: [TranscriptLine] = []

    public init(title: String, startedAt: Date, sources: Set<Source>) {
        self.title = title
        self.startedAt = startedAt
        self.sources = sources
    }

    /// Inserts in start-time order. Equal start times keep arrival order.
    public mutating func append(_ line: TranscriptLine) {
        var index = lines.endIndex
        while index > lines.startIndex, lines[index - 1].startMs > line.startMs {
            index -= 1
        }
        lines.insert(line, at: index)
    }

    public func html(timeZone: TimeZone, now: Date) -> String {
        var parts = [
            "<div><h1>\(Self.escapeHTML(title))</h1></div>",
            "<div>\(Self.escapeHTML(header(timeZone: timeZone)))</div>",
            "<div>Transcribed by Minutes. Audio was not recorded.</div>",
            "<div><br></div>",
        ]
        for line in lines {
            let label = "[\(Self.timestamp(ms: line.startMs))] \(line.speaker.displayName):"
            parts.append("<div><b>\(Self.escapeHTML(label))</b> \(Self.escapeHTML(line.text))</div>")
        }
        return parts.joined(separator: "\n")
    }

    public func plainText(timeZone: TimeZone, now: Date) -> String {
        var parts = [title, header(timeZone: timeZone), "Transcribed by Minutes. Audio was not recorded.", ""]
        for line in lines {
            parts.append("[\(Self.timestamp(ms: line.startMs))] \(line.speaker.displayName): \(line.text)")
        }
        return parts.joined(separator: "\n")
    }

    private func header(timeZone: TimeZone) -> String {
        let day = Self.formatter("EEEE, MMMM d, yyyy", timeZone).string(from: startedAt)
        let time = Self.formatter("h:mm a", timeZone).string(from: startedAt)
        let length: String
        if let endedAt {
            let minutes = max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded(.up)))
            length = "\(minutes) min"
        } else {
            length = "in progress"
        }
        return [day, time, length, sourcesText].joined(separator: " · ")
    }

    private var sourcesText: String {
        switch (sources.contains(.room), sources.contains(.call)) {
        case (true, true): "Room and call"
        case (true, false): "Room"
        case (false, true): "Call"
        case (false, false): "No audio sources"
        }
    }

    public static func defaultTitle(for date: Date, timeZone: TimeZone) -> String {
        "Meeting — " + formatter("EEE MMM d, h:mm a", timeZone).string(from: date)
    }

    public static func timestamp(ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    public static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
