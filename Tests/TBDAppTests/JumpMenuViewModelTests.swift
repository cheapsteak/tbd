import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

@MainActor
@Suite("JumpMenuViewModel Tests")
struct JumpMenuViewModelTests {

    // MARK: - Helpers

    func snap(_ id: UUID, name: String = "wt", repo: String = "tbd") -> JumpMenuWorktreeSnapshot {
        JumpMenuWorktreeSnapshot(id: id, displayName: name, repoName: repo)
    }

    // MARK: - Tests

    @Test func emptyState() {
        let vm = JumpMenuViewModel(worktrees: [], unread: [:], recentIDs: [])
        #expect(vm.rows.isEmpty)
        #expect(vm.selectedRow == nil)
    }

    @Test func unreadsOnly_sortedByRecency() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let now = Date()
        let vm = JumpMenuViewModel(
            worktrees: [snap(a, name: "A"), snap(b, name: "B"), snap(c, name: "C")],
            unread: [
                a: UnreadSummary(type: .responseComplete, mostRecentAt: now.addingTimeInterval(-300)),
                b: UnreadSummary(type: .error, mostRecentAt: now),
                c: UnreadSummary(type: .taskComplete, mostRecentAt: now.addingTimeInterval(-60)),
            ],
            recentIDs: []
        )
        let rows = vm.rows
        #expect(rows.count == 3)
        #expect(rows[0].id == b)   // most recent
        #expect(rows[1].id == c)
        #expect(rows[2].id == a)
        #expect(rows.allSatisfy { $0.section == .unread })
    }

    @Test func recentsOnly_sortedByLRUOrder() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [snap(a, name: "A"), snap(b, name: "B"), snap(c, name: "C")],
            unread: [:],
            recentIDs: [b, a, c]
        )
        let rows = vm.rows
        #expect(rows.count == 3)
        #expect(rows[0].id == b)
        #expect(rows[1].id == a)
        #expect(rows[2].id == c)
        #expect(rows.allSatisfy { $0.section == .recent })
    }

    @Test func mixed_unreadsThenRecents_noDuplicates() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let now = Date()
        let vm = JumpMenuViewModel(
            worktrees: [snap(a, name: "A"), snap(b, name: "B"), snap(c, name: "C")],
            unread: [a: UnreadSummary(type: .error, mostRecentAt: now)],
            recentIDs: [a, b, c]   // a is already unread; should be filtered out of recents
        )
        let rows = vm.rows
        #expect(rows.count == 3)
        #expect(rows[0].id == a)
        #expect(rows[0].section == .unread)
        #expect(rows[1].id == b)
        #expect(rows[1].section == .recent)
        #expect(rows[2].id == c)
        #expect(rows[2].section == .recent)
    }

    @Test func capAt20_unreadsFillFirst() {
        let snaps = (0..<25).map { _ in UUID() }
        var unread: [UUID: UnreadSummary] = [:]
        let now = Date()
        for (i, id) in snaps.enumerated() {
            unread[id] = UnreadSummary(type: .responseComplete, mostRecentAt: now.addingTimeInterval(-Double(i)))
        }
        let vm = JumpMenuViewModel(
            worktrees: snaps.map { snap($0) },
            unread: unread,
            recentIDs: snaps   // would push past the cap if not properly limited
        )
        #expect(vm.rows.count == 20)
        #expect(vm.rows.allSatisfy { $0.section == .unread })
    }

    @Test func fuzzyMatch_basicSubstring() {
        let a = UUID(); let b = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(a, name: "hot-otter", repo: "tbd"),
                snap(b, name: "cold-bear", repo: "tbd"),
            ],
            unread: [:],
            recentIDs: []
        )
        vm.query = "otter"
        #expect(vm.rows.count == 1)
        #expect(vm.rows.first?.id == a)
        #expect(vm.rows.first?.section == .match)
    }

    @Test func fuzzyMatch_matchesRepoName() {
        let a = UUID(); let b = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(a, name: "alpha", repo: "longeye-app"),
                snap(b, name: "beta", repo: "tbd"),
            ],
            unread: [:],
            recentIDs: []
        )
        vm.query = "longeye"
        #expect(vm.rows.count == 1)
        #expect(vm.rows.first?.id == a)
    }

    @Test func fuzzyMatch_sortedByUnreadPriority() {
        // Multiple worktrees match the query; the one with the highest
        // unread severity should land at index 0, regardless of dict
        // iteration order.
        let plain = UUID()
        let info = UUID()
        let urgent = UUID()
        let now = Date()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(plain, name: "match-plain"),
                snap(info, name: "match-info"),
                snap(urgent, name: "match-urgent"),
            ],
            unread: [
                info: UnreadSummary(type: .taskComplete, mostRecentAt: now),
                urgent: UnreadSummary(type: .error, mostRecentAt: now),
            ],
            recentIDs: []
        )
        vm.query = "match"
        let rows = vm.rows
        #expect(rows.count == 3)
        #expect(rows[0].id == urgent)   // .error severity 4
        #expect(rows[1].id == info)     // .taskComplete severity 2
        #expect(rows[2].id == plain)    // no unread
    }

    @Test func fuzzyMatch_noMatch() {
        let a = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [snap(a, name: "hot-otter")],
            unread: [:],
            recentIDs: []
        )
        vm.query = "zzz"
        #expect(vm.rows.isEmpty)
        #expect(vm.selectedRow == nil)
    }

    @Test func match_recentOutranksNonRecentByName() {
        // A recently-used match must rank above a non-recent one even when
        // it sorts later alphabetically.
        let recent = UUID(); let nonRecent = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(recent, name: "zzz-standup"),
                snap(nonRecent, name: "aaa-standup"),
            ],
            unread: [:],
            recentIDs: [recent]   // only `recent` was visited
        )
        vm.query = "standup"
        let rows = vm.rows
        #expect(rows.count == 2)
        #expect(rows[0].id == recent)      // recency beats alphabetical
        #expect(rows[1].id == nonRecent)
    }

    @Test func match_unreadOutranksMoreRecentRead() {
        // An unread worktree stays on top even when a read worktree was
        // used more recently.
        let read = UUID(); let unreadWT = UUID()
        let now = Date()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(read, name: "standup-read"),
                snap(unreadWT, name: "standup-unread"),
            ],
            unread: [unreadWT: UnreadSummary(type: .error, mostRecentAt: now)],
            recentIDs: [read]   // `read` is the most recently used
        )
        vm.query = "standup"
        let rows = vm.rows
        #expect(rows.count == 2)
        #expect(rows[0].id == unreadWT)   // unread tier wins over recency
        #expect(rows[1].id == read)
    }

    @Test func match_recencyOrdersWithinUnreadTier() {
        // Two equal-severity unread matches order by recency.
        let older = UUID(); let newer = UUID()
        let now = Date()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(older, name: "standup-a"),
                snap(newer, name: "standup-b"),
            ],
            unread: [
                older: UnreadSummary(type: .error, mostRecentAt: now),
                newer: UnreadSummary(type: .error, mostRecentAt: now),
            ],
            recentIDs: [newer, older]   // `newer` is more recent
        )
        vm.query = "standup"
        let rows = vm.rows
        #expect(rows.count == 2)
        #expect(rows[0].id == newer)   // equal severity -> recency decides
        #expect(rows[1].id == older)
    }

    @Test func match_emojiPrefixSortsByWords() {
        // Non-recent matches fall back to alphabetical; a leading emoji
        // must not drive the order.
        let apple = UUID(); let zebra = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(zebra, name: "🔧 zebra standup"),
                snap(apple, name: "🦓 apple standup"),
            ],
            unread: [:],
            recentIDs: []   // neither recent -> alphabetical fallback
        )
        vm.query = "standup"
        let rows = vm.rows
        #expect(rows.count == 2)
        #expect(rows[0].id == apple)   // "apple..." < "zebra..." despite emoji
        #expect(rows[1].id == zebra)
    }

    @Test func match_nonRecentFallbackAlphabetical() {
        // With no recency data, matches order alphabetically by words.
        let a = UUID(); let b = UUID(); let c = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [
                snap(c, name: "charlie-standup"),
                snap(a, name: "alpha-standup"),
                snap(b, name: "bravo-standup"),
            ],
            unread: [:],
            recentIDs: []
        )
        vm.query = "standup"
        let rows = vm.rows
        #expect(rows.map(\.id) == [a, b, c])
    }

    @Test func deletionsAreFiltered() {
        let stale = UUID()    // not present in `worktrees`
        let live = UUID()
        let now = Date()
        let vm = JumpMenuViewModel(
            worktrees: [snap(live, name: "L")],
            unread: [stale: UnreadSummary(type: .error, mostRecentAt: now)],
            recentIDs: [stale, live]
        )
        let rows = vm.rows
        #expect(rows.count == 1)
        #expect(rows[0].id == live)
    }

    @Test func tiebreakerByUUIDLexicographic() {
        // Two notifications at the exact same instant — sort must be deterministic.
        let now = Date()
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let vm = JumpMenuViewModel(
            worktrees: [snap(a, name: "A"), snap(b, name: "B")],
            unread: [
                a: UnreadSummary(type: .error, mostRecentAt: now),
                b: UnreadSummary(type: .error, mostRecentAt: now),
            ],
            recentIDs: []
        )
        let rows = vm.rows
        #expect(rows.count == 2)
        #expect(rows[0].id == a)   // "0...A" < "0...B"
        #expect(rows[1].id == b)
    }

    @Test func selectionMovesAndClamps() {
        let a = UUID(); let b = UUID()
        let vm = JumpMenuViewModel(
            worktrees: [snap(a), snap(b)],
            unread: [:],
            recentIDs: [a, b]
        )
        #expect(vm.selectedRow?.id == a)
        vm.moveSelectionDown()
        #expect(vm.selectedRow?.id == b)
        vm.moveSelectionDown()       // clamps at last
        #expect(vm.selectedRow?.id == b)
        vm.moveSelectionUp()
        #expect(vm.selectedRow?.id == a)
        vm.moveSelectionUp()         // clamps at first
        #expect(vm.selectedRow?.id == a)
    }
}
