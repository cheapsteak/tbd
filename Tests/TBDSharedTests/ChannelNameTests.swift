import Foundation
import Testing
@testable import TBDShared

@Suite struct ChannelNameTests {

    @Test func acceptsSimpleAscii() throws {
        let normalized = try validateChannelName("help")
        #expect(normalized == "help")
    }

    @Test func lowercases() throws {
        let normalized = try validateChannelName("API-Questions")
        #expect(normalized == "api-questions")
    }

    @Test func acceptsEmoji() throws {
        let normalized = try validateChannelName("🔥")
        #expect(normalized == "🔥")
    }

    @Test func acceptsNonLatin() throws {
        let normalized = try validateChannelName("日本語")
        #expect(normalized == "日本語")
    }

    @Test func nfcNormalizes() throws {
        // "é" composed (U+00E9) vs decomposed ("e" + U+0301)
        let composed = try validateChannelName("caf\u{00E9}")
        let decomposed = try validateChannelName("cafe\u{0301}")
        #expect(composed == decomposed)
    }

    @Test(arguments: [
        "", " ", "  ", "name ", " name", ".", "..", "_archive",
        "a/b", "a\\b", "a\u{0000}b", "a\u{0001}b", "a\u{007F}b",
        "a\nb", "a\tb",
    ])
    func rejects(_ input: String) {
        #expect(throws: ChannelNameError.self) {
            try validateChannelName(input)
        }
    }

    @Test func rejectsTooLongInGraphemes() {
        let s = String(repeating: "a", count: 65)
        #expect(throws: ChannelNameError.self) {
            try validateChannelName(s)
        }
    }

    @Test func acceptsAtGraphemeLimit() throws {
        let s = String(repeating: "a", count: 64)
        let normalized = try validateChannelName(s)
        #expect(normalized.count == 64)
    }

    @Test func acceptsAtByteLimit() throws {
        let s = String(repeating: "🔥", count: 50)  // 50 × 4 bytes = 200
        let normalized = try validateChannelName(s)
        #expect(normalized.utf8.count == 200)
    }

    @Test func rejectsTooLongInBytes() {
        // 50 emoji × ~4 bytes = 200 bytes; 51 emoji = 204 bytes → reject
        let s = String(repeating: "🔥", count: 51)
        #expect(throws: ChannelNameError.self) {
            try validateChannelName(s)
        }
    }
}
