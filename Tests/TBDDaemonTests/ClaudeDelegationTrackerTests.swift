import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct ClaudeDelegationTrackerTests {
    private func write(_ body: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-delegation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("transcript.jsonl").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func record(pending: Int?) -> String {
        let field = pending.map { #""pendingBackgroundAgentCount":\#($0),"# } ?? ""
        return #"{"type":"system","subtype":"turn_duration",\#(field)"durationMs":1}"#
    }

    @Test func anUnmarkedTerminalIsNeverRead() async throws {
        let tracker = ClaudeDelegationTracker()
        let path = try write(record(pending: 2) + "\n")
        let id = UUID()
        // No mark: the file says 2, but nothing asked for a sample.
        let result = await tracker.sample(
            targets: [ClaudeDelegationTarget(terminalID: id, transcriptPath: path)])
        #expect(result[id] == nil)
    }

    @Test func aMarkedTerminalIsSampledAndTheClaimPersists() async throws {
        let tracker = ClaudeDelegationTracker()
        let path = try write(record(pending: 2) + "\n")
        let id = UUID()
        await tracker.mark(terminalID: id)
        let targets = [ClaudeDelegationTarget(terminalID: id, transcriptPath: path)]
        #expect(await tracker.sample(targets: targets)[id] == 2)
        // The mark is consumed, but the claim stands until the next turn end.
        #expect(await tracker.sample(targets: targets)[id] == 2)
    }

    @Test func aLaterTurnWithoutPendingAgentsRetractsTheClaim() async throws {
        let tracker = ClaudeDelegationTracker()
        let path = try write(record(pending: 1) + "\n")
        let id = UUID()
        let targets = [ClaudeDelegationTarget(terminalID: id, transcriptPath: path)]
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(targets: targets)[id] == 1)

        try (record(pending: 1) + "\n" + record(pending: nil) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(targets: targets)[id] == nil)
    }

    @Test func aTranscriptPathChangeDiscardsTheCachedClaim() async throws {
        let tracker = ClaudeDelegationTracker()
        let old = try write(record(pending: 3) + "\n")
        let new = try write(record(pending: nil) + "\n")
        let id = UUID()
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(
            targets: [ClaudeDelegationTarget(terminalID: id, transcriptPath: old)])[id] == 3)
        // A /clear or compaction retargets the terminal. The old file's count
        // must not speak for the new one, even with no fresh mark.
        #expect(await tracker.sample(
            targets: [ClaudeDelegationTarget(terminalID: id, transcriptPath: new)])[id] == nil)
    }

    @Test func clearDropsALiveClaim() async throws {
        let tracker = ClaudeDelegationTracker()
        let path = try write(record(pending: 1) + "\n")
        let id = UUID()
        let targets = [ClaudeDelegationTarget(terminalID: id, transcriptPath: path)]
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(targets: targets)[id] == 1)
        await tracker.clear(terminalID: id)
        #expect(await tracker.sample(targets: targets)[id] == nil)
    }

    @Test func anUnreadableOrAbsentPathMakesNoClaim() async throws {
        let tracker = ClaudeDelegationTracker()
        let id = UUID()
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(targets: [
            ClaudeDelegationTarget(terminalID: id, transcriptPath: nil)])[id] == nil)
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(targets: [
            ClaudeDelegationTarget(terminalID: id, transcriptPath: "/nonexistent/x.jsonl")
        ])[id] == nil)
    }

    @Test func retainPrunesTerminalsThatAreGone() async throws {
        let tracker = ClaudeDelegationTracker()
        let path = try write(record(pending: 1) + "\n")
        let id = UUID()
        let targets = [ClaudeDelegationTarget(terminalID: id, transcriptPath: path)]
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(targets: targets)[id] == 1)
        await tracker.retain(terminalIDs: [])
        #expect(await tracker.sample(targets: targets)[id] == nil)
    }

    /// Only the tail is read, so a claim survives an arbitrarily large file.
    @Test func onlyTheTailIsReadForALargeTranscript() async throws {
        let filler = String(repeating:
            #"{"type":"assistant","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}"# + "\n",
            count: 4000)
        let path = try write(filler + record(pending: 5) + "\n")
        let id = UUID()
        let tracker = ClaudeDelegationTracker()
        await tracker.mark(terminalID: id)
        #expect(await tracker.sample(
            targets: [ClaudeDelegationTarget(terminalID: id, transcriptPath: path)])[id] == 5)
    }
}
