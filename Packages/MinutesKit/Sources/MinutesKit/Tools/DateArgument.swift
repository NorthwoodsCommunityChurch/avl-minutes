import Foundation

/// Parses tool date arguments: "YYYY-MM-DD" (local day) or full ISO 8601.
public enum DateArgument {
    public static func parseSince(_ text: String, timeZone: TimeZone) -> Date? {
        parse(text, timeZone: timeZone)?.date
    }

    /// A plain date means "through the end of that day".
    public static func parseUntil(_ text: String, timeZone: TimeZone) -> Date? {
        guard let parsed = parse(text, timeZone: timeZone) else { return nil }
        guard parsed.isDayOnly else { return parsed.date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: 1, to: parsed.date)
    }

    private static func parse(_ text: String, timeZone: TimeZone) -> (date: Date, isDayOnly: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        if trimmed.count == 10, let d = day.date(from: trimmed) { return (d, true) }
        if let d = ISO8601DateFormatter().date(from: trimmed) { return (d, false) }
        return nil
    }
}
