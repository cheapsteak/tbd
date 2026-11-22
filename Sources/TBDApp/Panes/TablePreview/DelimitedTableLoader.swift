import Foundation

enum DelimitedTableLoad: Equatable, Sendable {
    case loaded(DelimitedParseResult)
    case unreadable
}

/// Reads a CSV or TSV file for the table preview and hands its bytes to
/// `DelimitedTextParser`.
enum DelimitedTableLoader {
    /// Reading stops here, so a file of very long rows cannot fill memory
    /// before it reaches the row limit.
    static let byteLimit = 50 * 1024 * 1024

    /// Off-main. Delimiter from `DelimitedTextParser.delimiter(forPath:)`, comma if nil.
    ///
    /// Only a regular file is read (`stat` follows symlinks, so a link to one
    /// counts), for the reason `TextSniff.fileReadsAsText` gives: opening a
    /// FIFO blocks until a writer appears. A FIFO, a directory, a socket, a
    /// missing path or a read error is `.unreadable`. When the file holds more
    /// than `byteLimit` bytes, the parser gets the first `byteLimit` and drops
    /// the row the cut may have split.
    nonisolated static func load(
        path: String,
        rowLimit: Int = DelimitedTextParser.defaultRowLimit,
        columnLimit: Int = DelimitedTextParser.defaultColumnLimit,
        byteLimit: Int = DelimitedTableLoader.byteLimit
    ) -> DelimitedTableLoad {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        // `read(upToCount:)` throws on a read error, where `readData` raises an
        // Objective-C exception Swift cannot catch. It returns nil at end of
        // file, so an empty file reads as no bytes. One byte past the limit
        // says whether the file goes on.
        let data: Data
        do {
            data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        } catch {
            return .unreadable
        }
        let delimiter = DelimitedTextParser.delimiter(forPath: path) ?? 0x2C
        if data.count > byteLimit {
            return .loaded(DelimitedTextParser.parse(
                data.prefix(byteLimit), delimiter: delimiter,
                rowLimit: rowLimit, columnLimit: columnLimit, cutAtByteLimit: true
            ))
        }
        return .loaded(DelimitedTextParser.parse(
            data, delimiter: delimiter, rowLimit: rowLimit, columnLimit: columnLimit
        ))
    }
}
