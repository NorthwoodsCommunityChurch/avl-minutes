import Foundation

/// Aaron's voice as 192 numbers (CAM++ embedding). Cannot be turned back into audio.
public struct VoicePrint: Sendable, Codable, Equatable {
    public let vector: [Float]
    public let createdAt: Date

    public init(vector: [Float], createdAt: Date) {
        self.vector = vector
        self.createdAt = createdAt
    }

    /// Mean of L2-normalized embeddings, normalized again. Nil if inputs are empty,
    /// mismatched in length, or all zero.
    public static func make(from embeddings: [[Float]], createdAt: Date = Date()) -> VoicePrint? {
        guard let dim = embeddings.first?.count, dim > 0, embeddings.allSatisfy({ $0.count == dim }) else { return nil }
        var mean = [Float](repeating: 0, count: dim)
        var used = 0
        for e in embeddings {
            let n = norm(e)
            guard n > 1e-6 else { continue }
            for i in 0..<dim { mean[i] += e[i] / n }
            used += 1
        }
        let n = norm(mean)
        guard used > 0, n > 1e-6 else { return nil }
        return VoicePrint(vector: mean.map { $0 / n }, createdAt: createdAt)
    }

    /// Cosine similarity, -1...1. Zero for mismatched or zero vectors.
    public func similarity(to embedding: [Float]) -> Float {
        guard embedding.count == vector.count else { return 0 }
        let n = Self.norm(embedding)
        guard n > 1e-6 else { return 0 }
        var dot: Float = 0
        for i in vector.indices { dot += vector[i] * embedding[i] }
        return dot / n
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> VoicePrint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(VoicePrint.self, from: Data(contentsOf: url))
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes", isDirectory: true)
            .appendingPathComponent("voiceprint.json")
    }

    static func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }
}
