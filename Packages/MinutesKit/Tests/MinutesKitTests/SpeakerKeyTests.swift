import Testing
@testable import MinutesKit

@Test func displayNames() {
    #expect(SpeakerKey.me.displayName == "Me")
    #expect(SpeakerKey.room(2).displayName == "Speaker 2")
    #expect(SpeakerKey.call(1).displayName == "Caller 1")
    #expect(SpeakerKey.unknown.displayName == "Unknown")
}
