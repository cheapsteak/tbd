import Foundation
import Testing

@testable import TBDCLI

@Suite("tableRow plain-text list formatting")
struct TableRowFormattingTests {
    @Test func padsColumnsToWidthWithTwoSpaceGaps() {
        let row = tableRow([("ID", 36), ("NAME", 24), ("STATUS", 8), ("BRANCH", 0)])
        #expect(row == "ID" + String(repeating: " ", count: 34)
            + "  NAME" + String(repeating: " ", count: 20)
            + "  STATUS" + String(repeating: " ", count: 2)
            + "  BRANCH")
    }

    @Test func doesNotTruncateValuesLongerThanColumnWidth() {
        let longName = String(repeating: "x", count: 40)
        let row = tableRow([(longName, 24), ("active", 8), ("main", 0)])
        #expect(row.hasPrefix(longName + "  "))
        #expect(row.contains(longName))
        #expect(row.hasSuffix("active    main"))
    }

    @Test func exactWidthValueGetsNoPadding() {
        let value = String(repeating: "a", count: 8)
        #expect(tableRow([(value, 8), ("end", 0)]) == value + "  end")
    }

    @Test func zeroWidthFinalColumnIsNotPadded() {
        #expect(tableRow([("only", 0)]) == "only")
    }

    /// Regression: `tbd worktree list` (plain text) crashed with SIGSEGV
    /// because `String(format: "%-36s", ...)` was fed Swift Strings —
    /// `%s` expects a C string pointer on Darwin. A UUID-shaped row must
    /// format cleanly and align to the same columns the old format
    /// string intended.
    @Test func uuidRowFormatsWithoutCrashingAndAligns() {
        let id = UUID().uuidString
        let row = tableRow([(id, 36), ("my-worktree", 24), ("active", 8), ("main", 0)])
        // UUID strings are exactly 36 chars, so NAME starts at offset 38.
        #expect(row.count == 36 + 2 + 24 + 2 + 8 + 2 + 4)
        let nameStart = row.index(row.startIndex, offsetBy: 38)
        #expect(row[nameStart...].hasPrefix("my-worktree"))
    }
}
