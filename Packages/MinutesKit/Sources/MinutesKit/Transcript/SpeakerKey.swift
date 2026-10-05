/// Which audio stream a transcript line came from.
public enum Source: String, Sendable, CaseIterable {
    case room
    case call
}

/// A speaker's identity within one meeting.
public enum SpeakerKey: Hashable, Sendable {
    case me
    case room(Int)
    case call(Int)
    case unknown

    public var displayName: String {
        switch self {
        case .me: "Me"
        case .room(let n): "Speaker \(n)"
        case .call(let n): "Caller \(n)"
        case .unknown: "Unknown"
        }
    }
}
