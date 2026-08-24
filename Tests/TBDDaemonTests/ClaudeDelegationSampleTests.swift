import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct ClaudeDelegationSampleTests {
    /// A real `turn_duration` record carrying a pending count.
    static let pending = #"{"parentUuid":"222fdc13-cfb9-4c0d-9cc4-4952202f8fce","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":133243,"messageCount":132,"pendingBackgroundAgentCount":1,"timestamp":"2026-08-22T23:43:17.655Z","uuid":"11111111-1111-1111-1111-111111111111","isMeta":false,"userType":"external","entrypoint":"cli","cwd":"/tmp/tbd-test/worktree","sessionId":"00000000-0000-0000-0000-000000000001","version":"2.1.239","gitBranch":"feature-branch"}"#

    /// The same record shape with the field OMITTED — how Claude Code spells zero.
    static let absent = #"{"parentUuid":"632a67a1-63dc-4c07-be99-1b8f1fb39f5f","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":146367,"messageCount":74,"timestamp":"2026-08-22T22:53:13.020Z","uuid":"11111111-1111-1111-1111-111111111111","isMeta":false,"userType":"external","entrypoint":"cli","cwd":"/tmp/tbd-test/worktree","sessionId":"00000000-0000-0000-0000-000000000001","version":"2.1.239","gitBranch":"feature-branch"}"#

    /// An ordinary assistant line, present so the scanner must skip non-matches.
    static let noise = #"{"type":"assistant","isSidechain":false,"uuid":"22222222-2222-2222-2222-222222222222","timestamp":"2026-08-22T23:43:10.000Z"}"#

    private func tail(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    @Test func readsThePendingCountFromTheNewestRecord() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.noise, Self.pending])) == 1)
    }

    @Test func anOmittedFieldMakesNoClaim() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.noise, Self.absent])) == nil)
    }

    /// The whole point of the level rail: the NEWEST record wins, so a later
    /// turn that reports no pending agents retracts an earlier claim.
    @Test func theNewestRecordWinsOverAnOlderOne() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.pending, Self.absent])) == nil)
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.absent, Self.pending])) == 1)
    }

    @Test func aTailWithNoTurnDurationMakesNoClaim() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.noise, Self.noise])) == nil)
    }

    /// A 64 KiB window starts mid-record. The leading fragment must be dropped,
    /// not parsed — a half record is not evidence.
    @Test func aTruncatedLeadingRecordIsDiscarded() {
        let truncated = String(Self.pending.dropFirst(40))
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([truncated, Self.absent])) == nil)
        // And the fragment must not be mistaken for a claim on its own.
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([truncated])) == nil)
    }

    @Test func emptyAndGarbageTailsMakeNoClaim() {
        #expect(ClaudeDelegationSample.pendingCount(inTail: Data()) == nil)
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: Data("not json at all\n".utf8)) == nil)
    }

    @Test func aZeroCountMakesNoClaim() {
        let zero = Self.pending.replacingOccurrences(
            of: #""pendingBackgroundAgentCount":1"#,
            with: #""pendingBackgroundAgentCount":0"#)
        #expect(ClaudeDelegationSample.pendingCount(inTail: tail([zero])) == nil)
    }

    @Test func anOversizedRecordIsSkippedRatherThanParsed() {
        let huge = #"{"subtype":"turn_duration","pad":"@","pendingBackgroundAgentCount":9}"#
            .replacingOccurrences(of: "@", with: String(repeating: "x", count: 1 << 20))
        #expect(ClaudeDelegationSample.pendingCount(inTail: tail([huge])) == nil)
    }
}

@Suite struct ClaudeDelegationPublicationTests {
    /// The rail publishes through the SAME response-derived field Codex uses,
    /// so no column and no migration are involved.
    @Test func aClaimMapsToWorkingAndNoClaimMapsToNil() {
        #expect(RPCRouter.delegationPresentation(pendingCount: 2) == .working)
        #expect(RPCRouter.delegationPresentation(pendingCount: 1) == .working)
        #expect(RPCRouter.delegationPresentation(pendingCount: nil) == nil)
    }
}
