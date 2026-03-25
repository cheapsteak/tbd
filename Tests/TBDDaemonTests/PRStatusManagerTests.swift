import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRStatusManager Tests")
struct PRStatusManagerTests {

    // MARK: - State mapping

    @Test("maps OPEN + CLEAN to .mergeable")
    func mapsMergeableState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "CLEAN")
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED to .open")
    func mapsOpenBlocked() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "BLOCKED")
        #expect(status == .open)
    }

    @Test("maps OPEN + DIRTY to .open")
    func mapsOpenDirty() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "DIRTY")
        #expect(status == .open)
    }

    @Test("maps MERGED to .merged")
    func mapsMerged() {
        let status = PRStatusManager.mapState(ghState: "MERGED", mergeStateStatus: "UNKNOWN")
        #expect(status == .merged)
    }

    @Test("maps CLOSED to .closed")
    func mapsClosed() {
        let status = PRStatusManager.mapState(ghState: "CLOSED", mergeStateStatus: "BLOCKED")
        #expect(status == .closed)
    }

    @Test("maps OPEN + CHANGES_REQUESTED to .changesRequested")
    func mapsChangesRequested() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "BLOCKED", reviewDecision: "CHANGES_REQUESTED")
        #expect(status == .changesRequested)
    }

    @Test("maps OPEN + CLEAN + CHANGES_REQUESTED to .changesRequested (review wins)")
    func mapsChangesRequestedOverClean() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "CLEAN", reviewDecision: "CHANGES_REQUESTED")
        #expect(status == .changesRequested)
    }

    // MARK: - JSON parsing

    @Test("parseGraphQLResponse extracts matching branches")
    func parsesResponse() throws {
        let json = """
        {
          "data": {
            "viewer": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 42,
                    "url": "https://github.com/owner/repo/pull/42",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "tbd/cool-feature",
                    "createdAt": "2026-03-24T10:00:00Z"
                  },
                  {
                    "number": 7,
                    "url": "https://github.com/owner/repo/pull/7",
                    "state": "MERGED",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": null,
                    "headRefName": "tbd/old-feature",
                    "createdAt": "2026-03-20T10:00:00Z"
                  },
                  {
                    "number": 99,
                    "url": "https://github.com/owner/repo/pull/99",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "feature/not-tbd",
                    "createdAt": "2026-03-24T12:00:00Z"
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let nodes = try PRStatusManager.parsePRNodes(from: json)
        // Only tbd/ branches
        #expect(nodes.count == 2)
        #expect(nodes[0].headRefName == "tbd/cool-feature")
        #expect(nodes[0].state == "OPEN")
        #expect(nodes[0].mergeStateStatus == "CLEAN")
        #expect(nodes[1].headRefName == "tbd/old-feature")
    }

    @Test("allStatuses reflects cache after manual seed")
    func cacheRoundTrip() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 1, url: "https://github.com/o/r/pull/1", state: .mergeable)
        await manager.seedForTesting(worktreeID: id, status: status)
        let all = await manager.allStatuses()
        #expect(all[id] == status)
    }

    @Test("invalidate removes entry from cache")
    func invalidate() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 2, url: "https://github.com/o/r/pull/2", state: .open)
        await manager.seedForTesting(worktreeID: id, status: status)
        await manager.invalidate(worktreeID: id)
        let all = await manager.allStatuses()
        #expect(all[id] == nil)
    }
}
