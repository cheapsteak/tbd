import Darwin
import Foundation
import Testing

@testable import TBDShared

/// The process-table walk and the holder-descent join `tbd peer list` builds
/// on. Every case runs on a literal table except the one that reads the real
/// kernel, which asks only about this test process itself.
@Suite("Holder descent")
struct HolderDescentIndexTests {
    private static let born = Date(timeIntervalSince1970: 1_800_000_000)

    private static func table(_ parents: [pid_t: pid_t]) -> ProcessTableSnapshot {
        ProcessTableSnapshot(entries: parents.mapValues {
            ProcessTableSnapshot.Entry(parent: $0, startedAt: born)
        })
    }

    private static func holderRow(
        transport: TerminalTransport = .holder, holderPID: Int32, childPID: Int32
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", createdAt: born,
            kind: .shell, transport: transport, holderPID: holderPID, childPID: childPID)
    }

    // MARK: - The walk

    @Test func ancestryRunsNearestFirstAndStopsBelowLaunchd() {
        let processes = Self.table([10: 1, 11: 10, 12: 11])
        #expect(processes.ancestry(of: 12) == [12, 11, 10])
    }

    @Test func ancestryOfAPidTheTableDoesNotHoldIsEmpty() {
        #expect(Self.table([10: 1]).ancestry(of: 99).isEmpty)
    }

    /// A chain that runs into a pid the table does not hold stops there: an
    /// ancestor the walk cannot see is one nothing is joined to.
    @Test func ancestryStopsAtAMissingParent() {
        #expect(Self.table([12: 11]).ancestry(of: 12) == [12])
    }

    /// A table read across a fork can briefly disagree with itself; the walk
    /// must still end.
    @Test func ancestryStopsAtACycle() {
        #expect(Self.table([10: 11, 11: 10]).ancestry(of: 10) == [10, 11])
    }

    @Test func ancestryIsBoundedInDepth() {
        var parents: [pid_t: pid_t] = [:]
        for pid in pid_t(100)..<pid_t(400) { parents[pid] = pid - 1 }
        #expect(Self.table(parents).ancestry(of: 399).count
            == ProcessTableSnapshot.maximumDepth)
    }

    /// The one read of the real kernel: this test process is in the table,
    /// under the parent the kernel reports, with a start time.
    @Test func aRealReadHoldsThisProcessUnderItsParent() throws {
        let processes = try #require(ProcessTableSnapshot.read())
        #expect(processes.parent(of: getpid()) == getppid())
        #expect(processes.startTime(of: getpid()) != nil)
        #expect(processes.ancestry(of: getpid()).first == getpid())
    }

    // MARK: - The join

    @Test func theJobItselfIsAtDepthZero() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        let index = HolderDescentIndex(
            terminals: [row], processes: Self.table([20: 1, 21: 20, 22: 21]))
        #expect(index.descent(of: 21) == .init(terminalID: row.id, depth: 0))
        #expect(index.descent(of: 22) == .init(terminalID: row.id, depth: 1))
        #expect(index.descent(of: 20) == nil, "the holder itself is not inside its tab")
    }

    /// A holder the table does not hold anchors nothing, even when the job
    /// still names it as its parent. A consistent table cannot say both, but
    /// the liveness rule stands on its own rather than leaning on the parent
    /// rule to imply it.
    @Test func aRowWhoseHolderTheTableDoesNotHoldNeverAnchors() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        let index = HolderDescentIndex(
            terminals: [row], processes: Self.table([21: 20, 22: 21]))
        #expect(index.descent(of: 22) == nil)
    }

    /// Only a holder-backed row anchors the walk; a tmux row's pids, if it
    /// ever carried any, name no tab job.
    @Test func aTmuxRowNeverAnchors() {
        let row = Self.holderRow(transport: .tmux, holderPID: 20, childPID: 21)
        let index = HolderDescentIndex(
            terminals: [row], processes: Self.table([20: 1, 21: 20, 22: 21]))
        #expect(index.descent(of: 22) == nil)
    }

    /// Two rows claiming one live job cannot both be right, and nothing here
    /// can say which is — so neither is believed.
    @Test func twoRowsNamingOneJobAnchorNothing() {
        let first = Self.holderRow(holderPID: 20, childPID: 21)
        let second = Self.holderRow(holderPID: 20, childPID: 21)
        let index = HolderDescentIndex(
            terminals: [first, second], processes: Self.table([20: 1, 21: 20, 22: 21]))
        #expect(index.descent(of: 22) == nil)
    }

    /// The row's anchor is its woken child's start time once it has one, not
    /// its creation: a tab woken an hour after it was made still anchors.
    @Test func aWokenRowAnchorsOnItsChildsStartTime() {
        var row = Self.holderRow(holderPID: 20, childPID: 21)
        let woke = Self.born.addingTimeInterval(3600)
        row.holderChildStartedAt = woke
        let processes = ProcessTableSnapshot(entries: [
            20: .init(parent: 1, startedAt: woke),
            21: .init(parent: 20, startedAt: woke),
            22: .init(parent: 21, startedAt: woke),
        ])
        #expect(HolderDescentIndex(terminals: [row], processes: processes)
            .descent(of: 22)?.terminalID == row.id)
    }
}
