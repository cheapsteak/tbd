import Testing
import Foundation
@testable import TBDShared

@Suite struct HibernateReasonCodableTests {
    @Test func allKnownCasesRoundTrip() throws {
        for reason: HibernateReason in [.auto, .manual, .recovery, .merged] {
            let data = try JSONEncoder().encode(reason)
            let back = try JSONDecoder().decode(HibernateReason.self, from: data)
            #expect(back == reason)
        }
    }

    @Test func mergedEncodesToMergedRawValue() throws {
        let data = try JSONEncoder().encode(HibernateReason.merged)
        let text = String(data: data, encoding: .utf8)
        #expect(text == "\"merged\"")
    }

    @Test func unknownRawValueDecodesToAutoWithoutThrowing() throws {
        // The lenient custom decoder must NOT throw on a value a newer daemon
        // might send — it falls back to `.auto`.
        let data = "\"future_reason\"".data(using: .utf8)!
        let reason = try JSONDecoder().decode(HibernateReason.self, from: data)
        #expect(reason == .auto)
    }

    @Test func terminalWithMergedReasonDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","worktreeID":"\(UUID().uuidString)",
         "tmuxWindowID":"@1","tmuxPaneID":"%1","createdAt":0,
         "activityState":"idle","keepWarm":false,
         "hibernatedAt":0,"hibernateReason":"merged"}
        """.data(using: .utf8)!
        let terminal = try JSONDecoder().decode(Terminal.self, from: json)
        #expect(terminal.hibernateReason == .merged)
    }

    @Test func terminalWithUnknownReasonDecodesToAutoWithoutThrowing() throws {
        // Regression guard for the whole feature: an UNKNOWN hibernateReason on
        // the wire must NOT fail the entire Terminal decode on an older binary.
        let json = """
        {"id":"\(UUID().uuidString)","worktreeID":"\(UUID().uuidString)",
         "tmuxWindowID":"@1","tmuxPaneID":"%1","createdAt":0,
         "activityState":"idle","keepWarm":false,
         "hibernatedAt":0,"hibernateReason":"future_reason"}
        """.data(using: .utf8)!
        let terminal = try JSONDecoder().decode(Terminal.self, from: json)
        #expect(terminal.hibernateReason == .auto)
    }

    @Test func terminalWithAbsentReasonDecodesToNil() throws {
        // `decodeIfPresent` short-circuits before the custom init when the key
        // is absent, so an absent key yields nil (NOT `.auto`).
        let json = """
        {"id":"\(UUID().uuidString)","worktreeID":"\(UUID().uuidString)",
         "tmuxWindowID":"@1","tmuxPaneID":"%1","createdAt":0,
         "activityState":"idle","keepWarm":false}
        """.data(using: .utf8)!
        let terminal = try JSONDecoder().decode(Terminal.self, from: json)
        #expect(terminal.hibernateReason == nil)
    }
}
