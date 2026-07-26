import Foundation
import Testing
@testable import TBDApp

@Suite("Pinned dock reorder index maths")
struct PinnedDockReorderTests {
    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test("moving the last root to the front produces the expected order")
    func moveLastToFront() throws {
        let roots = ids(3)
        let result = try #require(PinnedDockReorder.reordered(
            roots: roots, fromOffsets: IndexSet(integer: 2), toOffset: 0))
        #expect(result == [roots[2], roots[0], roots[1]])
    }

    @Test("moving the first root to the end produces the expected order")
    func moveFirstToEnd() throws {
        let roots = ids(3)
        let result = try #require(PinnedDockReorder.reordered(
            roots: roots, fromOffsets: IndexSet(integer: 0), toOffset: 3))
        #expect(result == [roots[1], roots[2], roots[0]])
    }

    @Test("an out-of-range source index is rejected, not clamped")
    func staleSourceRejected() {
        let roots = ids(2)
        #expect(PinnedDockReorder.reordered(
            roots: roots, fromOffsets: IndexSet(integer: 5), toOffset: 0) == nil)
    }

    @Test("a destination beyond the count is rejected")
    func staleDestinationRejected() {
        let roots = ids(2)
        #expect(PinnedDockReorder.reordered(
            roots: roots, fromOffsets: IndexSet(integer: 0), toOffset: 99) == nil)
    }

    @Test("an empty root list is rejected rather than producing an empty write")
    func emptyRejected() {
        #expect(PinnedDockReorder.reordered(
            roots: [], fromOffsets: IndexSet(integer: 0), toOffset: 0) == nil)
    }
}
