import Foundation
import Testing
@testable import MinutesKit

@Test func voicePrintAveragesAndNormalizes() throws {
    let print = try #require(VoicePrint.make(from: [[2, 0], [0, 2]]))
    #expect(abs(print.vector[0] - 0.7071) < 0.001 && abs(print.vector[1] - 0.7071) < 0.001)
    #expect(abs(print.similarity(to: [5, 5]) - 1) < 0.001)
    #expect(abs(print.similarity(to: [1, -1])) < 0.001)
    #expect(print.similarity(to: [1, 2, 3]) == 0)       // wrong length
    #expect(VoicePrint.make(from: []) == nil)
    #expect(VoicePrint.make(from: [[0, 0]]) == nil)
    #expect(VoicePrint.make(from: [[1, 0], [1]]) == nil)
}

@Test func voicePrintRoundTripsThroughDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("vp.json")
    let print = VoicePrint(vector: [0.6, 0.8], createdAt: Date(timeIntervalSince1970: 1000))
    try print.save(to: url)
    #expect(try VoicePrint.load(from: url) == print)
    #expect(try VoicePrint.load(from: url.appendingPathExtension("missing")) == nil)
}

@Test func roomResolverUsesSimilarityThenSlotVote() {
    var r = SpeakerResolver(source: .room, threshold: 0.5)
    #expect(r.resolve(slot: 2, similarity: 0.8) == .me)
    #expect(r.resolve(slot: 2, similarity: nil) == .me)          // short line inherits slot vote
    #expect(r.resolve(slot: 0, similarity: 0.1) == .room(1))
    #expect(r.resolve(slot: 3, similarity: nil) == .room(2))
    #expect(r.resolve(slot: 0, similarity: nil) == .room(1))     // numbering is stable
    #expect(r.resolve(slot: nil, similarity: 0.9) == .unknown)
}

@Test func roomResolverWithoutVoicePrintNumbersEverySlot() {
    var r = SpeakerResolver(source: .room)
    #expect(r.resolve(slot: 1, similarity: nil) == .room(1))
    #expect(r.resolve(slot: 0, similarity: nil) == .room(2))
}

@Test func callResolverIgnoresVoicePrint() {
    var r = SpeakerResolver(source: .call)
    #expect(r.resolve(slot: 3, similarity: 0.99) == .call(1))
    #expect(r.resolve(slot: 0, similarity: nil) == .call(2))
}

@Test func ringReturnsRecentAudioOnly() {
    var ring = VoiceRing(sampleRate: 10, seconds: 1)          // capacity 10 samples
    ring.append((0..<8).map(Float.init))
    #expect(ring.samples(from: 0.2, to: 0.5) == [2, 3, 4])
    #expect(ring.samples(from: 0.5, to: 0.9) == nil)          // sample 8 not written yet
    ring.append((8..<15).map(Float.init))                      // wraps; samples 0-4 overwritten
    #expect(ring.samples(from: 0.3, to: 0.6) == nil)
    #expect(ring.samples(from: 0.5, to: 1.5) == (5..<15).map(Float.init))
    ring.append((15..<40).map(Float.init))                     // bigger than capacity
    #expect(ring.totalWritten == 40)
    #expect(ring.samples(from: 3.0, to: 4.0) == (30..<40).map(Float.init))
}

@Test func ringWipeZeroesMemory() {
    var ring = VoiceRing(sampleRate: 10, seconds: 1)
    ring.append([1, 2, 3])
    ring.wipe()
    #expect(ring.isWiped)
    #expect(ring.samples(from: 0, to: 0.3) == nil)
}
