import Foundation
import Testing

@testable import TBDDaemonLib

/// Shared helpers for the control-mode test suites (attach orchestration,
/// replay fence, pane repair, input router/health, resize coordinator). All
/// of them fake tmux the same way: a real `TmuxControlCommandClient` whose
/// `writeLine` records stream writes synchronously, with reply blocks fed by
/// hand through `client.handle(...)` — the correlator is exercised, only its
/// stdout is faked.

/// Generous positive-wait poll deadline that only elapses on failure; sized
/// for loaded parallel CI (PR #379: cooperative-pool starvation stretched
/// sub-second async-drain deliveries past a 5 s poll). Passing runs still
/// complete in milliseconds.
let ciSafeDeadline: Duration = .seconds(30)

/// Thread-safe, synchronous recorder of fake-client stream writes in call
/// order.
final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []
    func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
}

/// A fake-backed correlator: a real `TmuxControlCommandClient` whose stream
/// writes land in the returned recorder (onFatalError is a no-op). Tests feed
/// reply blocks by hand through `client.handle(...)`.
func makeFakeClient() -> (TmuxControlCommandClient, LineRecorder) {
    let recorder = LineRecorder()
    let client = TmuxControlCommandClient(
        writeLine: { recorder.record($0) },
        onFatalError: {})
    return (client, recorder)
}

/// Poll every 10 ms until `condition`, recording an Issue at the caller's
/// source location after `deadline`. A final post-deadline re-check absorbs
/// sleep slices that overshoot the deadline AFTER the condition became true
/// (observed live as `timedOut(got: N, want: N)` at loadavg ~40).
///
/// Returns whether the condition was met (false on timeout) so callers that
/// index into results afterwards can abort via `#require` instead of trapping
/// out of range; count/equality-checking callers may ignore the result.
@discardableResult
func waitFor(
    _ what: String, deadline: Duration = ciSafeDeadline,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws -> Bool {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return true }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    return false
}
