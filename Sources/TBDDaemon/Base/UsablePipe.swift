import Darwin
import Foundation

/// Whether `fd` is an open descriptor that refers to a pipe.
func isPipeDescriptor(_ fd: Int32) -> Bool {
    var info = stat()
    guard fstat(fd, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFIFO
}

/// Whether both ends of `pipe` are real, distinct pipe descriptors.
///
/// When pipe(2) fails — in practice only when the descriptor table is full —
/// Foundation's `Pipe()` does not throw: it returns an object whose handles
/// report descriptor 0. Spawning with it makes `run()` fail with a misleading
/// EBADF, and draining, marking or closing it would operate on whatever
/// descriptor 0 really is. Requiring two distinct FIFOs rejects that object
/// even when the process's own descriptor 0 happens to be a pipe.
func isUsablePipe(_ pipe: Pipe) -> Bool {
    let readFD = pipe.fileHandleForReading.fileDescriptor
    let writeFD = pipe.fileHandleForWriting.fileDescriptor
    return readFD != writeFD && isPipeDescriptor(readFD) && isPipeDescriptor(writeFD)
}
