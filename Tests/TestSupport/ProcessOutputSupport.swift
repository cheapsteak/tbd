import Darwin
import Dispatch
import Foundation

// Running a child process from a test without blocking a cooperative thread.
//
// `Process.waitUntilExit()` and `FileHandle.readDataToEndOfFile()` both park
// the calling thread until the child is done. In a synchronous test body that
// thread is one of Swift's cooperative pool, which is only as wide as the
// machine has cores — three on CI's `macos-26-arm64` runner. Every suspended
// task in the process draws on that pool, so a handful of such holds landing
// together is the wedge `Tests/CLAUDE.md` documents under "Thread-blocking
// gates run off the cooperative pool": the pass goes silent, dies on the
// step's `timeout-minutes` with zero failing tests, and no per-test
// `.timeLimit` fires, because a blocked thread is where cooperative
// cancellation cannot reach. Two runs died that way (34174344530 and
// 34176996067) with three such holds live at once.
//
// ``collectOutput(of:)`` is the seam that keeps those holds off the pool: the
// waiting is a continuation, and the only threads that block are libdispatch's
// own.

/// What a finished child process produced.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Runs `process` to completion and returns its exit status and both output
/// streams, without blocking the thread that called it.
///
/// The caller configures `executableURL`, `arguments`, `environment` and
/// anything else it needs, and does **not** call `run()`: this helper installs
/// its own pipes on `standardOutput` and `standardError` (replacing whatever
/// was set), arms the termination handler, and starts the child itself.
///
/// Three properties are load-bearing rather than incidental:
///
/// - **The termination handler is armed before `run()`.** A short-lived child
///   can exit before `run()` returns, and a handler installed afterwards would
///   never fire — the wait would then be bounded by nothing at all.
/// - **Both pipes are drained concurrently, on libdispatch threads.** A single
///   reader deadlocks on a child that fills the other pipe's buffer, and a
///   reader on a cooperative thread is the hold this helper exists to remove.
/// - **The continuation is resumed exactly once**, when the exit status and
///   both end-of-file reads have all landed — or immediately, with the error,
///   if `run()` throws.
///
/// - Throws: whatever `Process.run()` throws (a missing or non-executable
///   binary, most often).
public func collectOutput(of process: Process) async throws -> ProcessOutput {
    let collector = ProcessOutputCollector(process: process)
    return try await collector.run()
}

/// The state one `collectOutput(of:)` call needs, in one place so nothing
/// non-`Sendable` has to cross a closure boundary.
///
/// `@unchecked Sendable` because every stored property is either immutable or
/// guarded by `lock`; the `Process` and `Pipe` it owns are touched from the
/// dispatch queues below and from the termination handler, which is exactly
/// what the lock serializes.
private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    private var continuation: CheckedContinuation<ProcessOutput, any Error>?
    private var status: Int32?
    private var stdout: Data?
    private var stderr: Data?

    init(process: Process) {
        self.process = process
    }

    func run() async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation)
        }
    }

    private func start(_ continuation: CheckedContinuation<ProcessOutput, any Error>) {
        lock.withLock { self.continuation = continuation }
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Armed before `run()`: see the doc comment. `[weak self]` rather than a
        // strong capture because the handler is stored on the process, which
        // this object owns — a strong capture would be a retain cycle that only
        // a child that actually exits could break.
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            self?.deliver { $0.status = code }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            let waiting: CheckedContinuation<ProcessOutput, any Error>? = lock.withLock {
                let pending = self.continuation
                self.continuation = nil
                return pending
            }
            waiting?.resume(throwing: error)
            return
        }
        // Read to end-of-file on libdispatch threads. Both closures capture
        // only `self`, so no non-`Sendable` value crosses the boundary.
        DispatchQueue.global().async { [self] in
            let data = Self.readToEnd(descriptor: outPipe.fileHandleForReading.fileDescriptor)
            deliver { $0.stdout = data }
        }
        DispatchQueue.global().async { [self] in
            let data = Self.readToEnd(descriptor: errPipe.fileHandleForReading.fileDescriptor)
            deliver { $0.stderr = data }
        }
    }

    /// Records one of the three parts and resumes the waiter once all three are
    /// in. The resume happens outside the lock, because a continuation resumes
    /// into arbitrary caller code.
    private func deliver(_ record: (ProcessOutputCollector) -> Void) {
        let ready: (CheckedContinuation<ProcessOutput, any Error>, ProcessOutput)? = lock.withLock {
            record(self)
            guard let exitStatus = self.status, let out = self.stdout, let err = self.stderr,
                let waiting = self.continuation
            else { return nil }
            self.continuation = nil
            return (waiting, ProcessOutput(status: exitStatus, stdout: out, stderr: err))
        }
        guard let ready else { return }
        ready.0.resume(returning: ready.1)
    }

    /// `read(2)` in a loop rather than `readDataToEndOfFile()`, so the only
    /// thing crossing into the dispatch closure is a descriptor number. `EINTR`
    /// is retried; any other error ends the read with what was collected, which
    /// is what the caller's assertions want to see anyway.
    private static func readToEnd(descriptor: Int32) -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, raw.count)
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return collected
            } else if errno != EINTR {
                return collected
            }
        }
    }
}
