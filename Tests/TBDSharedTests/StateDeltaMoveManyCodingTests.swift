import Foundation
import Testing
@testable import TBDShared

/// Wire shape of `worktree.moveMany` and the `.worktreeSiblingsReordered`
/// delta it broadcasts.
@Suite struct StateDeltaMoveManyCodingTests {
    private let first = UUID()
    private let second = UUID()
    private let parent = UUID()

    @Test func siblingsReorderedDeltaRoundTrips() throws {
        let original = WorktreeSiblingsReorderedDelta(moveID: UUID(), entries: [
            WorktreeOrderEntry(worktreeID: first, parentWorktreeID: parent, sortOrder: 0),
            WorktreeOrderEntry(worktreeID: second, parentWorktreeID: parent, sortOrder: 1),
        ])
        let data = try JSONEncoder().encode(StateDelta.worktreeSiblingsReordered(original))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .worktreeSiblingsReordered(let delta) = decoded else {
            Issue.record("expected worktreeSiblingsReordered, got \(decoded)")
            return
        }
        #expect(delta == original)
    }

    /// A top-level group has nil parents, and a broadcast without a `moveID`
    /// still decodes.
    @Test func siblingsReorderedDeltaRoundTripsNils() throws {
        let original = WorktreeSiblingsReorderedDelta(moveID: nil, entries: [
            WorktreeOrderEntry(worktreeID: first, parentWorktreeID: nil, sortOrder: 0),
        ])
        let data = try JSONEncoder().encode(StateDelta.worktreeSiblingsReordered(original))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .worktreeSiblingsReordered(let delta) = decoded else {
            Issue.record("expected worktreeSiblingsReordered, got \(decoded)")
            return
        }
        #expect(delta == original)
    }

    /// Pins the case name on the wire, since an app decodes by that key.
    @Test func decodesTheDocumentedWireShape() throws {
        let json = """
            {"worktreeSiblingsReordered": {"_0": {
              "moveID": "\(second.uuidString)",
              "entries": [{"worktreeID": "\(first.uuidString)", "sortOrder": 3}]
            }}}
            """
        let decoded = try JSONDecoder().decode(StateDelta.self, from: Data(json.utf8))
        guard case .worktreeSiblingsReordered(let delta) = decoded else {
            Issue.record("expected worktreeSiblingsReordered, got \(decoded)")
            return
        }
        #expect(delta == WorktreeSiblingsReorderedDelta(moveID: second, entries: [
            WorktreeOrderEntry(worktreeID: first, parentWorktreeID: nil, sortOrder: 3),
        ]))
    }

    /// What an app built before this case does with it: the decode throws, and
    /// the subscription loop in `DaemonClient` drops a line it cannot decode
    /// and keeps reading. Shown here with a case name this build does not know,
    /// standing in for the new case on an older build.
    @Test func unknownDeltaCaseIsDroppedByOlderDecoder() throws {
        let decoder = JSONDecoder()
        let json = #"{"someFutureDelta": {"_0": {"moveID": null, "entries": []}}}"#
        #expect(throws: (any Error).self) {
            try decoder.decode(StateDelta.self, from: Data(json.utf8))
        }
        // The same decoder, as the loop reuses one, still reads the next line.
        let next = try JSONEncoder().encode(StateDelta.devServersChanged)
        let decoded = try decoder.decode(StateDelta.self, from: next)
        guard case .devServersChanged = decoded else {
            Issue.record("expected devServersChanged, got \(decoded)")
            return
        }
    }

    @Test func moveManyParamsRoundTrip() throws {
        let original = WorktreeMoveManyParams(
            moveID: UUID(), worktreeIDs: [second, first], newParentID: nil, beforeWorktreeID: first)
        let decoded = try JSONDecoder().decode(
            WorktreeMoveManyParams.self, from: try JSONEncoder().encode(original))
        #expect(decoded.moveID == original.moveID)
        #expect(decoded.worktreeIDs == [second, first])
        #expect(decoded.newParentID == nil)
        #expect(decoded.beforeWorktreeID == first)
    }

    @Test func methodNameIsStable() {
        #expect(RPCMethod.worktreeMoveMany == "worktree.moveMany")
    }
}
