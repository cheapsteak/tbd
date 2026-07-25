import Foundation
import Testing

// Named quarantine + retry metrics for the test-hardening program
// (`docs/specs/2026-07-24-test-hardening-design.md` §7).
//
// §7's whole point is that quarantine must not become a landfill: a retry is
// allowed only when it is attached to an open issue, and every retry (and every
// clean first-try pass) is written to a machine-readable ledger so the nightly
// audit can tell "still flaky" from "quietly fixed months ago".

// MARK: - Trait

/// Re-runs a test body up to three times, suppressing the failures of all but
/// the last attempt, and records the outcome to the retry-metrics ledger.
///
/// ```swift
/// @Test(.flaky(issue: 512))
/// func attachRacesSupersession() async { … }
/// ```
///
/// **The issue number is required, and that is the entire honesty mechanism.**
/// A blanket retry policy hides regressions: a test that starts failing 40% of
/// the time because someone broke the code under test is indistinguishable from
/// one that has always been 40% flaky. Quarantine has to *name* what it hides
/// so slice G's nightly audit can flag a `.flaky` whose issue is closed, or one
/// that passed first-try all week, for removal. An anonymous retry is a
/// permanent blind spot; a named one is a ticket.
///
/// **Tier 2 only.** A red tier-1 test is a bug — in the test or in the code —
/// full stop; it is deterministic and in-process, so "sometimes it fails" means
/// something is genuinely wrong. Never quarantine one. Tier 3 lives in its own
/// serial target where the contention this papers over is already contained.
///
/// Costs and interactions to know before reaching for it:
///
/// - Retries multiply wall clock by up to 3x, and that lands on top of
///   `.timeLimit` / `.clockDriven`, which bound **each attempt**, not the total.
///   A quarantined suite that takes 40 s takes 2 minutes when it misbehaves.
/// - The suite type is re-instantiated per attempt, so stored properties are
///   fresh — but `static`/global state is **not** reset. A body that mutates a
///   static sees attempt 1's residue on attempt 2. (The self-tests in
///   `FlakyQuarantineSelfTests` rely on exactly that; most tests are hurt by it.)
/// - `provideScope` runs once per test **case**, so a parameterized test retries
///   per case, not per test function.
///
/// **Known limitation — escaping Tasks break suppression in both directions.**
/// Swift Testing's known-issue matcher is scoped to the task tree that
/// `provideScope` wraps. An issue recorded from a `Task.detached` bypasses the
/// matcher entirely: the attempt looks like it *passed*, so no retry happens,
/// while the run still fails — a false-green attempt. Conversely, an inheriting
/// `Task { }` that outlives the scope keeps the matcher alive past the end of
/// this test, so an issue it records during a **later** test gets silently
/// swallowed as "known". Do not quarantine a test that reports failures from an
/// escaping Task; fix the escape first. The ledger inherits that lie: the
/// attempt looks clean, so a false-green attempt is recorded `passedFirstTry`
/// while the run itself goes red — a green record for a red run.
///
/// **Second limitation — a plain `throw` loses its throw site.** `#expect` and
/// `#require` failures keep their exact location (they record at their own call
/// site, before the trait ever sees them). A body that instead does a bare
/// `throw someError` reaches this trait's generic `catch`, and Swift does not
/// carry the throw site on an error, so the final attempt's failure is
/// attributed to the `@Test` declaration rather than the throwing line. That is
/// the closest true answer available, and it beats the default — which would
/// point into this file's plumbing — but prefer `#require` in a quarantined
/// test if you want the precise line.
///
/// Metrics: with `TBD_RETRY_METRICS_PATH` set (CI does this at the job level;
/// unset locally, where the trait writes nothing and does no work), every
/// execution appends one JSONL record — including clean first-try passes,
/// because the audit needs "passed first-try all week" as much as it needs
/// retries. **That schema is a consumed API** (slice G's nightly audit reads
/// it): adding a key is fine, changing or removing one means bumping `schema`.
///
/// Deliberately `TestTrait` only, never `SuiteTrait`: a quarantined *suite* is
/// precisely the landfill this mechanism exists to prevent.
public struct FlakyTrait: TestTrait, TestScoping {
    /// The open GitHub issue tracking this flake. Required — see the type doc.
    public let issue: Int

    /// Total attempts, including the final unsuppressed one.
    public static let maxAttempts = 3

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        for attempt in 1...Self.maxAttempts {
            let isFinal = attempt == Self.maxAttempts
            let result = await Self.runAttempt(
                comment: "flaky issue #\(issue), attempt \(attempt)",
                suppressing: !isFinal,
                attributingTo: test.sourceLocation,
                function
            )
            if result.cancelled {
                // Cancellation ends the sequence — there is nothing to retry.
                // But `#expect` records without throwing, so an attempt can
                // record a real failure and *then* be cancelled. On the final
                // attempt that verdict was surfaced unsuppressed, so it is a
                // genuine red and belongs in the ledger; leaving it out would
                // make CI red and the audit data silent. On a non-final
                // attempt the failure was suppressed and no verdict stands.
                if isFinal, result.failed {
                    RetryMetrics.record(test: test, issue: issue, attempts: attempt, outcome: .failed)
                }
                throw CancellationError()
            }
            if !result.failed {
                RetryMetrics.record(
                    test: test,
                    issue: issue,
                    attempts: attempt,
                    outcome: attempt == 1 ? .passedFirstTry : .passedOnRetry
                )
                return
            }
            if isFinal {
                RetryMetrics.record(test: test, issue: issue, attempts: attempt, outcome: .failed)
                return
            }
        }
    }

    /// What one attempt did. `failed` and `cancelled` are independent: a body
    /// can record a failing `#expect` (which does not throw) and then hit
    /// cancellation in the same attempt.
    private struct AttemptResult {
        let failed: Bool
        let cancelled: Bool
    }

    /// Runs one attempt and reports whether it recorded any issue.
    ///
    /// The `withKnownIssue` scope is present on **every** attempt, including the
    /// last, because its matcher is the only way to observe "did this attempt
    /// fail" — a failing `#expect` does not throw, and Swift Testing exposes no
    /// public per-case result. On the final attempt the matcher returns `false`,
    /// which passes the issue straight through to be recorded for real, keeping
    /// its original source location and comment. `isIntermittent: true` is what
    /// stops the unmatched scope from adding a spurious "expected an issue"
    /// failure of its own.
    ///
    /// The `do`/`catch` is not optional: the `matching:` overload is `rethrows`,
    /// so `try await function()` cannot be called directly inside it. And
    /// `#require` throws `ExpectationFailedError` *after* it has already
    /// recorded its issue, so re-recording that specific error trips Swift
    /// Testing's "An API was misused" diagnostic — it must be swallowed.
    ///
    /// Cancellation is reported separately rather than retried. Swallowing it
    /// would green a cancelled test; recording it as an issue would burn all
    /// three attempts and write `attempts: 3, outcome: .failed` —
    /// indistinguishable, in the ledger, from a genuinely always-failing flake.
    /// It is "neither a failure nor a pass" only until an unsuppressed verdict
    /// has already been recorded; see the caller for that case.
    ///
    /// `attributingTo` is the `@Test` declaration site. It is only used for a
    /// body that does a plain `throw` rather than failing through `#expect` or
    /// `#require`: that error reaches the generic `catch`, and `Issue.record`
    /// would otherwise default `sourceLocation` to *its own* call site in this
    /// file, pointing the reader at the trait's plumbing on the one attempt
    /// designed to surface honestly. The original throw site is not recoverable
    /// — Swift does not carry it on the error — so the test declaration is the
    /// closest true answer.
    private static func runAttempt(
        comment: Comment,
        suppressing: Bool,
        attributingTo sourceLocation: SourceLocation,
        _ function: @Sendable () async throws -> Void
    ) async -> AttemptResult {
        let failed = FlagBox()
        let cancelled = FlagBox()
        await withKnownIssue(comment, isIntermittent: true) {
            do {
                try await function()
            } catch is ExpectationFailedError {
                // Already recorded by `#require`; re-recording misuses the API.
            } catch is CancellationError {
                cancelled.set()
            } catch {
                Issue.record(error, sourceLocation: sourceLocation)
            }
        } matching: { _ in
            failed.set()
            return suppressing
        }
        return AttemptResult(failed: failed.isSet, cancelled: cancelled.isSet)
    }
}

public extension Trait where Self == FlakyTrait {
    /// See ``FlakyTrait``. Tier 2 only; the issue number is required.
    static func flaky(issue: Int) -> Self { FlakyTrait(issue: issue) }
}

// MARK: - Metrics ledger

/// Appends one JSONL record per `.flaky` test-case execution to the path in
/// `TBD_RETRY_METRICS_PATH`. Unset (the local default) means no file, no work.
enum RetryMetrics {
    enum Outcome: String, Encodable {
        case passedFirstTry, passedOnRetry, failed
    }

    private struct Record: Encodable {
        let schema = 1
        let testID: String
        let issue: Int
        let attempts: Int
        let outcome: Outcome
        let file: String
        let line: Int
    }

    static func record(test: Test, issue: Int, attempts: Int, outcome: Outcome) {
        guard MetricsAppender.shared.isEnabled else { return }
        let location = test.sourceLocation
        let record = Record(
            testID: stableID(test.id),
            issue: issue,
            attempts: attempts,
            outcome: outcome,
            file: repoRelativePath(location),
            line: location.line
        )
        let encoder = JSONEncoder()
        // Sanctioned by §7's brief: sorted keys give a stable order so the CI
        // artifact diffs cleanly, and JSONEncoder handles escaping for free.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record), let json = String(data: data, encoding: .utf8) else {
            MetricsAppender.shared.warnOnce("failed to encode a retry-metrics record")
            return
        }
        MetricsAppender.shared.append(json)
    }

    /// `Test.ID.description` appends the declaration's source location
    /// (`…/retriesUntilPass()/FlakyQuarantineSelfTests.swift:29:6`), which
    /// churns every time someone adds a line above the test — useless as a
    /// ledger key or as an audit exclusion. This rebuilds the stable
    /// `Module.Suite/testName()` prefix instead, which is also the form
    /// `swift test --filter` matches. Parameterized cases share one ID:
    /// `provideScope` still runs (and records) once per case, so a
    /// parameterized test contributes one record per case under the same key.
    private static func stableID(_ id: Test.ID) -> String {
        ([id.moduleName] + id.nameComponents.prefix(1)).joined(separator: ".")
            + id.nameComponents.dropFirst().map { "/" + $0 }.joined()
    }

    /// `SourceLocation` carries an absolute path; the ledger wants
    /// `Tests/TBDDaemonTests/Foo.swift` so records are comparable across
    /// machines and CI checkouts. Falls back to reconstructing from `fileID`
    /// (module + basename), which is exact for this repo's flat
    /// `Tests/<Target>/<File>.swift` layout and only loses nested directories.
    private static func repoRelativePath(_ location: SourceLocation) -> String {
        let path = location._filePath
        // `.backwards`: a checkout path that itself contains `/Tests/` would
        // otherwise be cut at the wrong occurrence.
        if let marker = path.range(of: "/Tests/", options: .backwards) {
            return "Tests/" + path[marker.upperBound...]
        }
        return "Tests/" + location.fileID
    }
}

// MARK: - Plumbing

/// Serializes appends across the in-process parallel test run, and opens the
/// file exactly once.
private final class MetricsAppender: @unchecked Sendable {
    static let shared = MetricsAppender()

    private let path: String?
    private let lock = NSLock()
    private var descriptor: Int32?
    private var openFailed = false
    private var warned = false

    private init() {
        let raw = ProcessInfo.processInfo.environment["TBD_RETRY_METRICS_PATH"]
        path = (raw?.isEmpty == false) ? raw : nil
    }

    var isEnabled: Bool { path != nil }

    func append(_ line: String) {
        guard let path else { return }
        lock.lock()
        defer { lock.unlock() }
        if descriptor == nil, !openFailed {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd < 0 {
                openFailed = true
                warnLocked("could not open \(path) (errno \(errno))")
            } else {
                descriptor = fd
            }
        }
        guard let fd = descriptor else { return }
        let bytes = Array((line + "\n").utf8)
        // Loop rather than one `write`: the consumer is a line parser, so a
        // partial write would leave a fragment that the next record
        // concatenates onto, yielding one unparseable line. Retries EINTR too.
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    warnLocked("short write to \(path) (\(offset) of \(buffer.count) bytes, errno \(errno))")
                    return
                }
            }
        }
    }

    func warnOnce(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        warnLocked(message)
    }

    /// An infra hiccup must never look like a code failure, so this never fails
    /// a test — but it must not be silent either, or broken CI wiring shows up
    /// as an empty artifact nobody questions. One line per process.
    private func warnLocked(_ message: String) {
        guard !warned else { return }
        warned = true
        let text = "warning: retry metrics disabled — \(message)\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Lock-guarded latch. The known-issue matcher runs on whatever task recorded
/// the issue, so this crosses threads.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
