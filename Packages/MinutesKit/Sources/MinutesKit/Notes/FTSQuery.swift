import Foundation

/// Turns free text into a safe FTS5 query. Words are OR-ed (ranking rewards notes
/// matching more of them); input wrapped in double quotes becomes a phrase.
/// Every token is quoted, so FTS operators and punctuation can never cause errors.
public enum FTSQuery {
    public static func make(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPhrase = trimmed.count >= 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
        let tokens = trimmed
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        if isPhrase { return "\"" + tokens.joined(separator: " ") + "\"" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
