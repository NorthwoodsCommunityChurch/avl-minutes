import Testing
@testable import MinutesKit

@Test func wordsAreQuotedAndOred() {
    #expect(FTSQuery.make(from: "lobby screens") == "\"lobby\" OR \"screens\"")
}

@Test func quotedInputIsAPhrase() {
    #expect(FTSQuery.make(from: "\"lobby screens\"") == "\"lobby screens\"")
}

@Test func punctuationAndOperatorsAreNeutralized() {
    #expect(FTSQuery.make(from: "what's AND *budget\"") == "\"what\" OR \"s\" OR \"AND\" OR \"budget\"")
    #expect(FTSQuery.make(from: "  ?! ") == nil)
}
