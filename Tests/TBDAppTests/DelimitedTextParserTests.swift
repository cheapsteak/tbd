import Foundation
import Testing
@testable import TBDApp

/// Tier 1: the parser is pure, so every test feeds it bytes.
@Suite("DelimitedTextParser")
struct DelimitedTextParserTests {
    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    private func parse(
        _ s: String, _ d: UInt8 = 0x2C, rowLimit: Int = 100_000,
        columnLimit: Int = DelimitedTextParser.defaultColumnLimit, cut: Bool = false
    ) -> DelimitedParseResult {
        DelimitedTextParser.parse(
            Data(s.utf8), delimiter: d, rowLimit: rowLimit, columnLimit: columnLimit, cutAtByteLimit: cut)
    }

    private func table(_ r: DelimitedParseResult) throws -> DelimitedTable {
        let found: DelimitedTable?
        if case .table(let t) = r { found = t } else { found = nil }
        return try #require(found, "expected a table, got \(r)")
    }

    @Test("comma rows: the first row is the titles")
    func plainCommaRows() throws {
        let t = try table(parse("a,b\n1,2\n3,4\n"))
        #expect(t.titles == ["a", "b"])
        #expect(t.rows == [["1", "2"], ["3", "4"]])
        #expect(t.columnCount == 2)
        #expect(t.stoppedAtLimit == false)
    }

    @Test("tab rows")
    func tabRows() throws {
        let t = try table(parse("a\tb\n1\t2", 0x09))
        #expect(t.titles == ["a", "b"])
        #expect(t.rows == [["1", "2"]])
    }

    @Test("a quoted field holds the delimiter, a line break and a doubled quote")
    func quotedFieldHoldsDelimiterBreakAndQuote() throws {
        let t = try table(parse("h\n\"x,y\n\"\"z\"\"\"\n"))
        #expect(t.titles == ["h"])
        #expect(t.rows == [["x,y\n\"z\""]])
    }

    @Test("CRLF ends a row and leaves no carriage return")
    func crlfRowEnds() throws {
        let t = try table(parse("a,b\r\n1,2\r\n"))
        #expect(t.titles == ["a", "b"])
        #expect(t.rows == [["1", "2"]])
        let values = t.titles + t.rows.flatMap { $0 }
        // By byte: "\r\n" is one Character, so a Character search misses it.
        let withCarriageReturn = values.filter { $0.utf8.contains(0x0D) }
        #expect(withCarriageReturn.isEmpty)
    }

    @Test("a lone CR ends a row, mixed with LF and CRLF")
    func loneCrAndMixedRowEnds() throws {
        let t = try table(parse("a\r1\n2\r\n3"))
        #expect(t.titles == ["a"])
        #expect(t.rows == [["1"], ["2"], ["3"]])
    }

    @Test("a line break at the end adds no row")
    func trailingNewlineAddsNoRow() throws {
        let t = try table(parse("a\n1\n"))
        #expect(t.rows.count == 1)
    }

    @Test("an empty line in the middle is a row with one empty field")
    func emptyMiddleLineIsOneEmptyField() throws {
        let t = try table(parse("a\n\n1"))
        #expect(t.rows == [[""], ["1"]])
    }

    @Test("a byte order mark is removed from the first title")
    func bomIsRemoved() throws {
        let bytes = Self.byteOrderMark + Data("id,name\n1,x".utf8)
        let t = try table(DelimitedTextParser.parse(bytes, delimiter: 0x2C))
        #expect(t.titles == ["id", "name"])
        #expect(t.rows == [["1", "x"]])
    }

    @Test("a quote inside an unquoted field is an ordinary character")
    func quoteInsideUnquotedFieldIsLiteral() throws {
        let t = try table(parse("a\n5\"9,x\n"))
        #expect(t.titles == ["a", ""])
        #expect(t.rows == [["5\"9", "x"]])
    }

    @Test("rows shorter and longer than the header keep their own length")
    func raggedRowsKeepTheirLength() throws {
        let t = try table(parse("a,b\n1\n1,2,3\n"))
        #expect(t.columnCount == 3)
        #expect(t.titles == ["a", "b", ""])
        #expect(t.rows == [["1"], ["1", "2", "3"]])
    }

    /// The row's fourth field is quoted, so both the quoted and the unquoted
    /// field paths skip a field past the limit.
    @Test("fields past the column limit are dropped and the table is marked")
    func columnLimitStops() throws {
        let t = try table(parse("a,b,c,d,e\n1,2,3,\"4,4\",5\n", columnLimit: 3))
        #expect(t.columnCount == 3)
        #expect(t.titles == ["a", "b", "c"])
        #expect(t.rows == [["1", "2", "3"]])
        #expect(t.stoppedAtColumnLimit == true)
        #expect(t.stoppedAtLimit == false)
    }

    @Test("rows exactly as wide as the column limit are not marked")
    func withinColumnLimitIsNotStopped() throws {
        let t = try table(parse("a,b,c\n1,2,3\n", columnLimit: 3))
        #expect(t.columnCount == 3)
        #expect(t.rows == [["1", "2", "3"]])
        #expect(t.stoppedAtColumnLimit == false)
    }

    /// The only row past the limit is the one a cut drops, so no row the
    /// table holds lost a field.
    @Test("a row past the column limit that a cut drops does not mark the table")
    func droppedRowPastColumnLimitIsNotMarked() throws {
        let t = try table(parse("a\n1\n2,3\n", columnLimit: 1, cut: true))
        #expect(t.rows == [["1"]])
        #expect(t.stoppedAtLimit == true)
        #expect(t.stoppedAtColumnLimit == false)
    }

    @Test("a quote that never closes names the line it opens on")
    func unterminatedQuoteNamesItsLine() {
        #expect(parse("a\n1\n\"open\nmore\n") == .unterminatedQuote(line: 3))
    }

    @Test("the row limit stops the reading and marks the table")
    func rowLimitStops() throws {
        let t = try table(parse("h\n1\n2\n3\n4\n5\n", rowLimit: 3))
        #expect(t.rows.count == 3)
        #expect(t.rows == [["1"], ["2"], ["3"]])
        #expect(t.stoppedAtLimit == true)
    }

    /// Without a limit the empty line is a row, so with a limit of one row
    /// the table does not hold it.
    @Test("an empty line past the row limit stops the table")
    func trailingEmptyRowPastLimitIsStopped() throws {
        let whole = try table(parse("h\n1\n\n"))
        #expect(whole.rows == [["1"], [""]])

        let t = try table(parse("h\n1\n\n", rowLimit: 1))
        #expect(t.rows == [["1"]])
        #expect(t.stoppedAtLimit == true)
    }

    @Test("exactly the row limit plus a final line break is not stopped")
    func exactlyRowLimitIsNotStopped() throws {
        let t = try table(parse("h\n1\n2\n3\n", rowLimit: 3))
        #expect(t.rows.count == 3)
        #expect(t.stoppedAtLimit == false)
    }

    /// The task cancels itself before it parses, so the scan's first check,
    /// right after the title row, sees the cancellation on every run, and
    /// the scan returns `.empty` instead of reading 20,000 rows.
    @Test("a parse on a cancelled task stops early")
    func cancelledParseStopsEarly() async throws {
        let text = "a,b\n" + (1...20_000).map { "\($0),x\n" }.joined()
        let whole = try table(parse(text))
        #expect(whole.rows.count == 20_000)

        let bytes = Data(text.utf8)
        let result = await Task.detached { () -> DelimitedParseResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return DelimitedTextParser.parse(bytes, delimiter: 0x2C)
        }.value
        #expect(result == .empty)
    }

    /// The scan asks after the title row and then every
    /// `cancellationCheckInterval` data rows. Here the first answer is no,
    /// so the parse goes on, and a later answer, after 4,096 rows, is yes:
    /// the periodic check stops the scan, not only the one after the title
    /// row.
    @Test("a parse cancelled partway through stops early")
    func cancellationMidParseStopsEarly() throws {
        let rowCount = 10_000
        try #require(rowCount > 2 * DelimitedTextParser.cancellationCheckInterval)
        let text = "a,b\n" + (1...rowCount).map { "\($0),x\n" }.joined()
        let bytes = Data(text.utf8)

        var calls = 0
        let result = DelimitedTextParser.parse(bytes, delimiter: 0x2C) {
            calls += 1
            return calls > 1
        }
        #expect(result == .empty)
        #expect(calls > 1, "only the check after the title row ran")
    }

    @Test("input cut by the byte limit drops its last row")
    func cutDropsLastRow() throws {
        let t = try table(parse("a\n1\n2\n3", cut: true))
        #expect(t.titles == ["a"])
        #expect(t.rows == [["1"], ["2"]])
        #expect(t.stoppedAtLimit == true)
    }

    @Test("a cut inside a quoted field drops the partial row, not an error")
    func cutInsideQuoteDropsPartialRow() throws {
        let result = parse("a\n1\n\"par", cut: true)
        #expect(result != .unterminatedQuote(line: 3))
        let t = try table(result)
        #expect(t.titles == ["a"])
        #expect(t.rows == [["1"]])
        #expect(t.stoppedAtLimit == true)
    }

    @Test("empty input, and a byte order mark alone, are empty")
    func emptyInputIsEmpty() {
        #expect(parse("") == .empty)
        let bomOnly = DelimitedTextParser.parse(Self.byteOrderMark, delimiter: 0x2C)
        #expect(bomOnly == .empty)
    }

    @Test("a header with no rows")
    func headerOnly() throws {
        let t = try table(parse("a,b\n"))
        #expect(t.titles == ["a", "b"])
        #expect(t.rows.isEmpty)
        #expect(t.columnCount == 2)
        #expect(t.stoppedAtLimit == false)
    }

    @Test("invalid UTF-8 shows as the replacement character")
    func invalidUTF8IsReplacementCharacter() throws {
        let bytes = Data("a\n".utf8) + Data([0x31, 0xFF, 0x32])
        let t = try table(DelimitedTextParser.parse(bytes, delimiter: 0x2C))
        #expect(t.rows == [["1\u{FFFD}2"]])
    }

    @Test("the delimiter comes from the extension, in any case")
    func delimiterForPath() {
        #expect(DelimitedTextParser.delimiter(forPath: "/x/a.csv") == 0x2C)
        #expect(DelimitedTextParser.delimiter(forPath: "/x/A.TSV") == 0x09)
        #expect(DelimitedTextParser.delimiter(forPath: "/x/a.txt") == nil)
        #expect(DelimitedTextParser.delimiter(forPath: "/x/csv") == nil)
    }
}
