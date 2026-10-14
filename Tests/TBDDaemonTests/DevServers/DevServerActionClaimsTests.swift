import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 1: in-process actor state only.
@Suite("Dev server action claims")
struct DevServerActionClaimsTests {
    @Test func concurrentClaimsForOneServerAdmitExactlyOne() async {
        let claims = DevServerActionClaims()
        let worktree = UUID()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask { await claims.claim(["web"], in: worktree, for: .start).claimed == ["web"] }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
    }

    @Test func aBusyServerNamesTheActionHoldingIt() async {
        let claims = DevServerActionClaims()
        let worktree = UUID()
        _ = await claims.claim(["web"], in: worktree, for: .stop)
        let second = await claims.claim(["web", "api"], in: worktree, for: .start)
        #expect(second.claimed == ["api"])
        #expect(second.busy == ["web": .stop])
    }

    @Test func otherServersAndOtherWorktreesDoNotContend() async {
        let claims = DevServerActionClaims()
        let worktree = UUID()
        _ = await claims.claim(["web"], in: worktree, for: .start)
        #expect(await claims.claim(["api"], in: worktree, for: .start).claimed == ["api"])
        #expect(await claims.claim(["web"], in: UUID(), for: .start).claimed == ["web"])
    }

    @Test func releaseFreesTheServer() async {
        let claims = DevServerActionClaims()
        let worktree = UUID()
        _ = await claims.claim(["web"], in: worktree, for: .start)
        await claims.release(["web"], in: worktree)
        #expect(await claims.claim(["web"], in: worktree, for: .stop).claimed == ["web"])
    }

    @Test func aNameGivenTwiceIsClaimedOnceAndIsNotBusyWithItself() async {
        let claims = DevServerActionClaims()
        let result = await claims.claim(["web", "web"], in: UUID(), for: .start)
        #expect(result.claimed == ["web"])
        #expect(result.busy.isEmpty)
    }
}
