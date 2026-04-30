import XCTest
@testable import TBDDaemonLib
import TBDShared

final class WorktreeReviveReorderTests: XCTestCase {
    func testReorderFloatsPreferredSessionFirst() {
        let stored = ["a", "b", "c"]
        let preferred = "b"
        let result = reorderSessions(stored: stored, preferred: preferred)
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testNilPreferredKeepsOrder() {
        let stored = ["a", "b", "c"]
        let result = reorderSessions(stored: stored, preferred: String?.none)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testUnknownPreferredKeepsOrder() {
        let stored = ["a", "b", "c"]
        let result = reorderSessions(stored: stored, preferred: "z")
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testNilStoredStaysNil() {
        let result = reorderSessions(stored: [String]?.none, preferred: "anything")
        XCTAssertNil(result)
    }
}
