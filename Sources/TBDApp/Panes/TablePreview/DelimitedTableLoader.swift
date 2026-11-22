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
    /// Only a regular file is read, for the reason `TextSniff.fileReadsAsText`
    /// gives: opening a FIFO blocks until a writer appears. So the path is
    /// opened `O_NONBLOCK`, which opens a FIFO at once instead of waiting,
    /// and the descriptor it opened is the one checked with `fstat`: a file
    /// swapped for a FIFO between a check of the path and the open cannot
    /// block the read. The open follows symlinks, so a link to a regular file
    /// counts. A FIFO, a directory, a socket, a missing path or a read error
    /// is `.unreadable`. When the file holds more than `byteLimit` bytes, the
    /// parser gets the first `byteLimit` and drops the row the cut may have
    /// split.
    nonisolated static func load(
        path: String,
        rowLimit: Int = DelimitedTextParser.defaultRowLimit,
        columnLimit: Int = DelimitedTextParser.defaultColumnLimit,
        byteLimit: Int = DelimitedTableLoader.byteLimit
    ) -> DelimitedTableLoad {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        // The handle owns the descriptor from here, so every return below,
        // a refused file's included, closes it.
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable }
        // A regular file ignores `O_NONBLOCK`; clearing it anyway makes the
        // read an ordinary blocking read whatever the file system.
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
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
        return .loaded(DelimitedTextParser.parse(
            data.prefix(byteLimit), delimiter: delimiter,
            rowLimit: rowLimit, columnLimit: columnLimit, cutAtByteLimit: data.count > byteLimit
        ))
    }
}
