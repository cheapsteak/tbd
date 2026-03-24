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
                    "headRefName": "tbd/cool-feature"
                  },
                  {
                    "number": 7,
                    "url": "https://github.com/owner/repo/pull/7",
                    "state": "MERGED",
                    "mergeStateStatus": "UNKNOWN",
                    "headRefName": "tbd/old-feature"
                  },
                  {
                    "number": 99,
                    "url": "https://github.com/owner/repo/pull/99",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "headRefName": "feature/not-tbd"
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
