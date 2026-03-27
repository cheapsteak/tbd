import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Test func testNameFormat() {
    let name = NameGenerator.generate()
    let parts = name.split(separator: "-")
    // Format: YYYYMMDD-adjective-animal
    #expect(parts.count == 3)
    #expect(parts[0].count == 8) // YYYYMMDD
    #expect(Int(parts[0]) != nil) // numeric date
}

@Test func testDatePrefix() {
    let name = NameGenerator.generate()
    let dateStr = String(name.prefix(8))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    #expect(formatter.date(from: dateStr) != nil)
}

@Test func testDatePrefixMatchesToday() {
    let name = NameGenerator.generate()
    let dateStr = String(name.prefix(8))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    let today = formatter.string(from: Date())
    #expect(dateStr == today)
}

@Test func testWordListsArePopulated() {
    #expect(NameGenerator.adjectives.count > 300)
    #expect(NameGenerator.animals.count > 300)
}

@Test func testAllWordsAreLowercase() {
    for word in NameGenerator.adjectives {
        #expect(word == word.lowercased(), "Adjective '\(word)' should be lowercase")
    }
    for word in NameGenerator.animals {
        #expect(word == word.lowercased(), "Animal '\(word)' should be lowercase")
    }
}

@Test func testNoHyphensInWords() {
    for word in NameGenerator.adjectives {
        #expect(!word.contains("-"), "Adjective '\(word)' should not contain hyphens")
    }
    for word in NameGenerator.animals {
        #expect(!word.contains("-"), "Animal '\(word)' should not contain hyphens")
    }
}

@Test func testCustomDate() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    let date = formatter.date(from: "20260321")!
    let name = NameGenerator.generate(date: date)
    #expect(name.hasPrefix("20260321-"))
}
