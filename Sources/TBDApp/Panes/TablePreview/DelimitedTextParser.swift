import Foundation

/// A parsed CSV or TSV file. `titles` and every row are padded with "" to `columnCount`.
struct DelimitedTable: Equatable, Sendable {
    let titles: [String]
    let rows: [[String]]
    let columnCount: Int
    /// True when the row limit or the byte limit stopped the reading.
    let stoppedAtLimit: Bool
}

enum DelimitedParseResult: Equatable, Sendable {
    case table(DelimitedTable)
    case empty
    /// `line` counts from 1: the physical line where the quoted field starts.
    case unterminatedQuote(line: Int)
}

/// Turns the bytes of a CSV or TSV file into a `DelimitedTable`, under the
/// quoting rules of RFC 4180 for either delimiter:
///
/// - A field that starts with `"` runs to the closing quote. Inside it, the
///   delimiter and line breaks are part of the value and `""` is one `"`.
///   Bytes between the closing quote and the next delimiter or line break are
///   kept as written.
/// - A `"` anywhere else in a field is an ordinary character.
/// - A row ends at `\n`, `\r\n` or `\r` outside quotes. A line break at the
///   end of the input adds no row; an empty line before it is a row with one
///   empty field.
/// - A leading UTF-8 byte order mark is skipped. Bytes that are not valid
///   UTF-8 decode as U+FFFD.
///
/// The first row gives the titles. Pure: no file access, no actor isolation.
enum DelimitedTextParser {
    static let tableExtensions: Set<String> = ["csv", "tsv"]
    static let defaultRowLimit = 100_000

    /// `,` (0x2C) for csv, tab (0x09) for tsv, case-insensitive; nil otherwise.
    nonisolated static func delimiter(forPath path: String) -> UInt8? {
        switch (path as NSString).pathExtension.lowercased() {
        case "csv": return 0x2C
        case "tsv": return 0x09
        default: return nil
        }
    }

    /// Parses at most `rowLimit` data rows (the title row is not counted).
    ///
    /// `cutAtByteLimit` says the bytes stop where the reader's byte limit cut
    /// the file, so the last row may be partial: it is dropped, even when the
    /// cut lands inside a quoted field, and the table is marked as stopped.
    nonisolated static func parse(
        _ bytes: Data, delimiter: UInt8,
        rowLimit: Int = DelimitedTextParser.defaultRowLimit, cutAtByteLimit: Bool = false
    ) -> DelimitedParseResult {
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DelimitedParseResult in
            var scan = DelimitedByteScan(
                bytes: raw.bindMemory(to: UInt8.self),
                delimiter: delimiter,
                rowLimit: rowLimit,
                cutAtByteLimit: cutAtByteLimit
            )
            return scan.run()
        }
    }
}

/// The byte-level scan behind `DelimitedTextParser.parse`. Lives only inside
/// `Data.withUnsafeBytes`, so the buffer never outlives its storage.
private struct DelimitedByteScan {
    private static let quote: UInt8 = 0x22
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    let bytes: UnsafeBufferPointer<UInt8>
    let delimiter: UInt8
    let rowLimit: Int
    let cutAtByteLimit: Bool

    private var index = 0
    /// The physical line `index` is on, counting from 1. Line breaks inside a
    /// quoted field count, so an error can name the line an editor shows.
    private var line = 1
    private var header: [String]?
    private var dataRows: [[String]] = []
    private var fields: [String] = []
    /// Reused for every quoted field, which has to be unescaped byte by byte.
    private var quotedValue: [UInt8] = []

    init(bytes: UnsafeBufferPointer<UInt8>, delimiter: UInt8, rowLimit: Int, cutAtByteLimit: Bool) {
        self.bytes = bytes
        self.delimiter = delimiter
        self.rowLimit = rowLimit
        self.cutAtByteLimit = cutAtByteLimit
    }

    mutating func run() -> DelimitedParseResult {
        let count = bytes.count
        if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            index = 3
        }
        if index == count { return .empty }

        var stoppedAtRowLimit = false
        scanning: while true {
            // One field starts at `index`; `index == count` here only right
            // after a delimiter, where the field is empty.
            if index < count, bytes[index] == Self.quote {
                let quoteLine = line
                if !scanQuotedField() {
                    // The input ended inside the quotes. After a cut that is
                    // the cut itself, and the partial row is dropped below.
                    guard cutAtByteLimit else { return .unterminatedQuote(line: quoteLine) }
                    break scanning
                }
            } else {
                let start = index
                advanceToFieldEnd()
                fields.append(decode(start..<index))
            }

            if index == count { break scanning }
            if bytes[index] == delimiter {
                index += 1
                continue scanning
            }
            // A line break ends the row.
            if bytes[index] == Self.carriageReturn, index + 1 < count, bytes[index + 1] == Self.lineFeed {
                index += 2
            } else {
                index += 1
            }
            line += 1
            finishRow()
            if header != nil, dataRows.count >= rowLimit {
                stoppedAtRowLimit = true
                break scanning
            }
            if index == count { break scanning }
        }

        let stoppedAtLimit: Bool
        if stoppedAtRowLimit {
            // Every kept row ended at a line break, so none is partial.
            stoppedAtLimit = cutAtByteLimit || remainderHasContent()
        } else {
            if cutAtByteLimit {
                // The last row may be cut short: drop the unfinished row, or,
                // when the bytes end at a line break, the last finished one.
                if fields.isEmpty {
                    if dataRows.isEmpty { header = nil } else { dataRows.removeLast() }
                }
            } else if !fields.isEmpty {
                finishRow()
            }
            stoppedAtLimit = cutAtByteLimit
        }

        guard var titles = header else {
            // Only a cut can drop every row.
            return cutAtByteLimit
                ? .table(DelimitedTable(titles: [], rows: [], columnCount: 0, stoppedAtLimit: true))
                : .empty
        }
        var columnCount = titles.count
        for row in dataRows where row.count > columnCount {
            columnCount = row.count
        }
        if titles.count < columnCount {
            titles.append(contentsOf: repeatElement("", count: columnCount - titles.count))
        }
        for rowIndex in dataRows.indices where dataRows[rowIndex].count < columnCount {
            dataRows[rowIndex].append(contentsOf: repeatElement("", count: columnCount - dataRows[rowIndex].count))
        }
        return .table(DelimitedTable(
            titles: titles, rows: dataRows, columnCount: columnCount, stoppedAtLimit: stoppedAtLimit
        ))
    }

    /// Scans the quoted field opening at `index` and appends its value to
    /// `fields`. Returns false when the input ends before the closing quote;
    /// the partial value is appended then too.
    private mutating func scanQuotedField() -> Bool {
        let count = bytes.count
        quotedValue.removeAll(keepingCapacity: true)
        index += 1
        var closed = false
        while index < count {
            let byte = bytes[index]
            if byte == Self.quote {
                if index + 1 < count, bytes[index + 1] == Self.quote {
                    quotedValue.append(Self.quote)
                    index += 2
                    continue
                }
                index += 1
                closed = true
                break
            }
            if byte == Self.lineFeed {
                line += 1
            } else if byte == Self.carriageReturn, !(index + 1 < count && bytes[index + 1] == Self.lineFeed) {
                line += 1
            }
            quotedValue.append(byte)
            index += 1
        }
        if closed {
            // Anything between the closing quote and the field's end is kept.
            while index < count, !isFieldEnd(bytes[index]) {
                quotedValue.append(bytes[index])
                index += 1
            }
        }
        // Lossy on purpose: invalid UTF-8 shows as U+FFFD and the rest of the
        // file still shows.
        // swiftlint:disable:next optional_data_string_conversion
        fields.append(String(decoding: quotedValue, as: UTF8.self))
        return closed
    }

    private mutating func advanceToFieldEnd() {
        let count = bytes.count
        while index < count, !isFieldEnd(bytes[index]) {
            index += 1
        }
    }

    private func isFieldEnd(_ byte: UInt8) -> Bool {
        byte == delimiter || byte == Self.lineFeed || byte == Self.carriageReturn
    }

    private func decode(_ range: Range<Int>) -> String {
        if range.isEmpty { return "" }
        // Lossy on purpose, as in `scanQuotedField`.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    private mutating func finishRow() {
        if header == nil {
            header = fields
        } else {
            dataRows.append(fields)
        }
        fields = []
    }

    /// Whether any byte other than a line break follows `index`.
    private func remainderHasContent() -> Bool {
        var position = index
        while position < bytes.count {
            let byte = bytes[position]
            if byte != Self.lineFeed && byte != Self.carriageReturn { return true }
            position += 1
        }
        return false
    }
}
