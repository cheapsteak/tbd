import Testing
@testable import TBDShared

@Test func testEmojiDataNotEmpty() {
    #expect(EmojiData.all.count > 100)
}

@Test func testNoDuplicateNames() {
    var seen = Set<String>()
    for entry in EmojiData.all {
        #expect(!entry.name.isEmpty, "Entry with emoji \(entry.emoji) has empty name")
        #expect(!entry.emoji.isEmpty, "Entry with name \(entry.name) has empty emoji")
        #expect(!seen.contains(entry.name), "Duplicate emoji name: \(entry.name)")
        seen.insert(entry.name)
    }
}

@Test func testSearchByPrefix() {
    let results = EmojiData.search("rocket")
    #expect(results.count >= 1)
    #expect(results[0].emoji == "🚀")
    #expect(results[0].name == "rocket")
}

@Test func testSearchByPartialPrefix() {
    let results = EmojiData.search("roc")
    #expect(results.count >= 1)
    #expect(results.contains(where: { $0.name == "rocket" }))
}

@Test func testSearchByKeyword() {
    let results = EmojiData.search("happy")
    #expect(results.count >= 1)
}

@Test func testSearchEmptyQuery() {
    let results = EmojiData.search("")
    #expect(results.isEmpty)
}

@Test func testSearchRespectsLimit() {
    let results = EmojiData.search("s", limit: 3)
    #expect(results.count <= 3)
}

@Test func testSearchCaseInsensitive() {
    let results = EmojiData.search("Rocket")
    #expect(results.contains(where: { $0.name == "rocket" }))
}
