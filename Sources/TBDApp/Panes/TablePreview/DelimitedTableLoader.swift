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
    /// Only a regular file is read. This runs `stat` on the path before
    /// anything opens it, so a file that is not regular is never opened.
    /// Opening a FIFO blocks until a writer appears, for the reason
    /// `TextSniff.fileReadsAsText` gives. An open that does not wait is no
    /// better: it releases a writer blocked opening the FIFO, such as a
    /// shell's `producer > out.csv`, and closing it again leaves that writer
    /// with no reader, so its next write fails with `SIGPIPE` or `EPIPE`.
    /// A regular file goes on to `loadOpening`, which checks the descriptor
    /// it opens as well.
    ///
    /// `stat` follows symlinks, so a link to a regular file counts. A FIFO,
    /// a directory, a socket, a missing path or a read error is
    /// `.unreadable`. When the file holds more than `byteLimit` bytes, the
    /// parser gets the first `byteLimit` and drops the row the cut may have
    /// split.
    nonisolated static func load(
        path: String,
        rowLimit: Int = DelimitedTextParser.defaultRowLimit,
        columnLimit: Int = DelimitedTextParser.defaultColumnLimit,
        byteLimit: Int = DelimitedTableLoader.byteLimit
    ) -> DelimitedTableLoad {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable }
        return loadOpening(path: path, rowLimit: rowLimit, columnLimit: columnLimit, byteLimit: byteLimit)
    }

    /// What `load` runs once `stat` has seen a regular file: open the path,
    /// read at most `byteLimit` bytes and parse them.
    ///
    /// The path may name another file by the time it is opened, so this
    /// alone must still refuse a file that is not regular. The open is
    /// `O_NONBLOCK`, so a FIFO swapped in after the `stat` opens at once
    /// instead of blocking, and `fstat` on the descriptor the open returned
    /// refuses it. The open follows symlinks, as `stat` does. A file that is
    /// not regular, a failed open or a read error is `.unreadable`.
    nonisolated static func loadOpening(
        path: String, rowLimit: Int, columnLimit: Int, byteLimit: Int
    ) -> DelimitedTableLoad {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        // The handle owns the descriptor from here, so every return below,
        // a refused file's included, closes it.
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // The path may name another file by now; the descriptor is what is read.
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
