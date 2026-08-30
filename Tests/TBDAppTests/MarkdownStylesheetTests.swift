import Clocks
import Foundation
import Testing
@testable import TBDApp
import TestSupport

/// Tier 1, except for `themesDirectoryWatchSeesAStylesheetCreatedLater`, which
/// is tier 2: a real filesystem and a real dispatch source deliver the *event*,
/// while the debounce *timer* is virtual — the same split `FileWatcherTests`
/// documents.
///
/// Every test supplies its own tmp themes directory and its own
/// `UserDefaults(suiteName:)`. Neither `~/tbd` nor `UserDefaults.standard` is
/// reachable from here: `TBD_HOME` may not be `setenv`'d outside
/// `TBDHomeSerialized` in `TBDDaemonTests`, and `.standard` on this unbundled
/// executable is the developer's real `TBDApp.plist`.
@Suite("MarkdownStylesheet")
struct MarkdownStylesheetTests {

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-css-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A throwaway defaults suite, torn down with `removePersistentDomain`.
    private func withDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let defaultsSuite = TestDefaultsSuite("markdown-stylesheet")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        return try body(defaults)
    }

    private let bundledMarker = "/* bundled */"

    // MARK: - Resolution

    @Test("a present user stylesheet is used verbatim")
    func userStylesheetWins() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "body{color:hotpink}".write(
            to: dir.appendingPathComponent("neon.css"), atomically: true, encoding: .utf8
        )

        try withDefaults { defaults in
            defaults.set("neon", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == "body{color:hotpink}")
        }
    }

    @Test("an unset theme key falls back to the bundled stylesheet")
    func unsetKeyFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A stylesheet exists, but nothing selects it.
        try "body{color:hotpink}".write(
            to: dir.appendingPathComponent("neon.css"), atomically: true, encoding: .utf8
        )

        try withDefaults { defaults in
            #expect(MarkdownStylesheet.themeID(defaults) == nil)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("an empty or whitespace-only theme id falls back to the bundled stylesheet")
    func blankThemeIDFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDefaults { defaults in
            for raw in ["", "   ", "\n"] {
                defaults.set(raw, forKey: MarkdownStylesheet.themeKey)
                #expect(MarkdownStylesheet.resolve(
                    themesDirectory: dir, defaults: defaults, bundled: bundledMarker
                ) == bundledMarker)
            }
        }
    }

    @Test("a missing stylesheet file falls back to the bundled stylesheet")
    func missingFileFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDefaults { defaults in
            defaults.set("nothing-here", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("a missing themes directory falls back to the bundled stylesheet")
    func missingDirectoryFallsBack() throws {
        let dir = try tempDir()
        try FileManager.default.removeItem(at: dir)

        try withDefaults { defaults in
            defaults.set("neon", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("a stylesheet that is not valid UTF-8 falls back to the bundled stylesheet")
    func garbageFileFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 0xFF is not a legal UTF-8 byte in any position.
        try Data([0xFF, 0xFE, 0xFF, 0x00, 0xC0, 0x80])
            .write(to: dir.appendingPathComponent("broken.css"))

        try withDefaults { defaults in
            defaults.set("broken", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("a blank stylesheet falls back rather than rendering unstyled")
    func blankFileFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "  \n\t\n".write(
            to: dir.appendingPathComponent("empty.css"), atomically: true, encoding: .utf8
        )

        try withDefaults { defaults in
            defaults.set("empty", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("a theme id carrying path components is rejected, not resolved")
    func pathTraversalRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "body{color:red}".write(
            to: outside.appendingPathComponent("secret.css"), atomically: true, encoding: .utf8
        )

        try withDefaults { defaults in
            for raw in ["outside/secret", "../outside/secret", "..", "."] {
                defaults.set(raw, forKey: MarkdownStylesheet.themeKey)
                #expect(MarkdownStylesheet.themeID(defaults) == nil, "rejected: \(raw)")
                #expect(MarkdownStylesheet.userStylesheetURL(
                    themesDirectory: dir, defaults: defaults
                ) == nil)
                #expect(MarkdownStylesheet.resolve(
                    themesDirectory: dir, defaults: defaults, bundled: bundledMarker
                ) == bundledMarker)
            }
        }
    }

    @Test("the stylesheet URL is <themesDir>/<themeID>.css")
    func stylesheetURLShape() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDefaults { defaults in
            defaults.set("neon", forKey: MarkdownStylesheet.themeKey)
            let url = try #require(MarkdownStylesheet.userStylesheetURL(
                themesDirectory: dir, defaults: defaults
            ))
            #expect(url.lastPathComponent == "neon.css")
            #expect(url.deletingLastPathComponent().path == dir.path)
            // The file does not exist; the URL is still produced, because this
            // is also what the live-reload watcher watches.
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - No process-lifetime caching

    /// The whole point of the change: the predecessor was a `static let`, so an
    /// edit only landed after a rebuild + relaunch. Two resolves either side of
    /// an edit must differ.
    @Test("resolution is not cached across calls, so an edit is picked up")
    func resolutionIsNotCached() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.css")
        try "body{color:red}".write(to: url, atomically: true, encoding: .utf8)

        try withDefaults { defaults in
            defaults.set("live", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == "body{color:red}")

            try "body{color:blue}".write(to: url, atomically: true, encoding: .utf8)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == "body{color:blue}")

            // …including a delete, which must return to the bundled sheet.
            try FileManager.default.removeItem(at: url)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("an atomic rename-replace is visible to the very next resolve")
    func atomicReplaceIsPickedUp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.css")
        try "body{color:red}".write(to: url, atomically: true, encoding: .utf8)

        try withDefaults { defaults in
            defaults.set("live", forKey: MarkdownStylesheet.themeKey)
            _ = MarkdownStylesheet.resolve(themesDirectory: dir, defaults: defaults, bundled: bundledMarker)

            // `atomically: true` is write-temp-then-rename, the editor pattern.
            try "body{color:green}".write(to: url, atomically: true, encoding: .utf8)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == "body{color:green}")
        }
    }

    // MARK: - Directory creation

    @Test("the themes directory is created on demand and reported as existing")
    func ensureDirectoryCreates() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themes = dir.appendingPathComponent("markdown-themes", isDirectory: true)

        #expect(!FileManager.default.fileExists(atPath: themes.path))
        #expect(MarkdownStylesheet.ensureThemesDirectoryExists(themes))
        #expect(FileManager.default.fileExists(atPath: themes.path))
        // Idempotent.
        #expect(MarkdownStylesheet.ensureThemesDirectoryExists(themes))
    }

    @Test("a regular file where the themes directory should be reports failure")
    func ensureDirectoryRejectsAFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themes = dir.appendingPathComponent("markdown-themes")
        try "not a directory".write(to: themes, atomically: true, encoding: .utf8)

        #expect(!MarkdownStylesheet.ensureThemesDirectoryExists(themes))
    }

    // MARK: - Bundled default

    @Test("the bundled stylesheet loads and is non-empty")
    func bundledCSSLoads() {
        #expect(MarkdownStylesheet.bundledCSS.contains("--md-fg"))
        #expect(MarkdownStylesheet.bundledCSS.contains("prefers-color-scheme"))
    }

    /// Both `.copy(...)` resources (the CSS and this doc) now sit in the same
    /// generated `TBDApp_TBDApp.bundle` — this guards that adding the second
    /// one didn't disturb the first's lookup.
    @Test("the bundled stylesheet doc resolves and is non-empty")
    func stylesheetDocsURLResolves() throws {
        let url = try #require(MarkdownStylesheet.stylesheetDocsURL)
        #expect(url.pathExtension == "md")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("# Writing a markdown stylesheet"))
        // Same-run cross-check: the sibling CSS resource still resolves too.
        #expect(!MarkdownStylesheet.bundledCSS.isEmpty)
    }

    // MARK: - Live reload (tier 2)

    /// The load-bearing assumption behind watching the themes *directory*: a
    /// `FileWatcher` on a directory fires when an entry is created inside it.
    /// That is the only way the viewer can notice a stylesheet that did not
    /// exist when it opened — there is no inode for a file watcher to open.
    ///
    /// Tier 2, split the way `FileWatcherTests` splits: a real dispatch source
    /// delivers the *event*, while the debounce *timer* is virtual — production
    /// takes `clock: any Clock<Duration>`, so the 150 ms window is crossed by
    /// advancing a `TestClock` instead of being waited out on a loaded runner.
    /// Waiting out a real debounce plus `AsyncStream` delivery under one 8 s
    /// bound is exactly what starved here when the process carried >5000 tests.
    ///
    /// The bounded polls that remain wait only on legs that are genuinely
    /// real-time — the dispatch source delivering an event and production
    /// reaching `clock.sleep` (observed through `armed`), and the consuming
    /// `Task` receiving an `AsyncStream` element — never on the debounce
    /// interval itself. Each is a hang guard whose healthy path exits on its
    /// first probe, and each timeout travels as a thrown `Failure` carrying the
    /// observed counts (Tests/CLAUDE.md rule 4).
    ///
    /// One-sidedness worth naming: this watches a *directory*, so the events
    /// are not attributable to a particular entry. A straggler probe event
    /// could in principle supply the phase-2 arm or notification. The final
    /// `resolve()` assertion is what pins the actual content — a watcher that
    /// never saw `later.css` cannot make it read `body{color:teal}`.
    @Test("a watch on the themes directory sees a stylesheet created later", .clockDriven)
    func themesDirectoryWatchSeesAStylesheetCreatedLater() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDefaults { defaults in
            defaults.set("later", forKey: MarkdownStylesheet.themeKey)
            // Precondition: nothing to read yet, so the bundled sheet is in force.
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }

        let clock = TestClock<Swift.Duration>()
        let armed = Counter()
        let notified = Counter()
        let watcher = FileWatcher(clock: RecordingClock(base: clock, armed: armed))
        let stream = watcher.changes(for: dir.path)
        let consumer = Task { for await _ in stream { notified.record() } }
        defer { consumer.cancel() }

        // Phase 1 — prove the source is registered and delivering.
        //
        // Same dispatch-source registration race `FileWatcherTests.writeUntilArmed`
        // documents: `resume()` registers its kqueue filter asynchronously, so a
        // create issued right after `changes(for:)` returns can be lost forever.
        // Retrying is legitimate ONLY for that first-write race; every wait after
        // this one treats a missing event as event loss, not as something to
        // retry.
        let attempts = 4
        let attemptWindow: Duration = .seconds(2)
        var registered = false
        for attempt in 0..<attempts {
            try "body{color:teal}".write(
                to: dir.appendingPathComponent("probe-\(attempt).css"),
                atomically: true, encoding: .utf8
            )
            if await Self.waitUntil(attemptWindow, { armed.count > 0 }) {
                registered = true
                break
            }
        }
        guard registered else {
            throw Failure("""
                a FileWatcher on a directory armed no debounce timer for an entry being \
                created — observed armed=\(armed.count) after \(attempts) attempts of \
                \(attemptWindow) each
                """)
        }

        // The timer is virtual, so crossing the window costs no wall time. The
        // poll after it is the real leg: `AsyncStream` delivery into the
        // consuming `Task`, on the same 8 s budget `FileWatcherTests.poll` uses.
        await clock.advanceWhenSuspended(by: FileWatcher.debounceInterval)
        guard await Self.waitUntil(.seconds(8), { notified.count > 0 }) else {
            throw Failure("""
                the debounce window elapsed but no notification reached the consumer — \
                observed \(notified.count) after polling up to 8 seconds
                """)
        }

        // Phase 2 — the event the viewer actually cares about: the selected
        // stylesheet appearing. After it, resolution must stop returning the
        // bundled sheet.
        let before = notified.count
        let armedBefore = armed.count
        let url = dir.appendingPathComponent("later.css")
        try "body{color:teal}".write(to: url, atomically: true, encoding: .utf8)
        // No retry here: the source has already delivered once, so a missing arm
        // is event loss. This waits only for kernel event -> GCD handler ->
        // production reaching `clock.sleep`, the leg `writeUntilArmed`'s 8 s
        // budget covers.
        guard await Self.waitUntil(.seconds(8), { armed.count > armedBefore }) else {
            throw Failure("""
                creating the selected stylesheet armed no new debounce timer — observed \
                armed=\(armed.count) (baseline \(armedBefore)) after polling up to 8 seconds
                """)
        }
        await clock.advanceWhenSuspended(by: FileWatcher.debounceInterval)
        guard await Self.waitUntil(.seconds(8), { notified.count > before }) else {
            throw Failure("""
                creating the selected stylesheet produced no directory notification — \
                observed \(notified.count) (baseline \(before)) after polling up to 8 seconds
                """)
        }

        try withDefaults { defaults in
            defaults.set("later", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == "body{color:teal}")
        }

        consumer.cancel()
        _ = await consumer.value
    }

    /// Bounded poll on a fact produced by **real** scheduling — a dispatch
    /// source delivering an event, or `AsyncStream` handing an element to its
    /// consumer.
    ///
    /// `timeout` is a hang guard, never a tolerance window: the healthy path
    /// returns on the first probe. It returns a `Bool` rather than recording an
    /// issue itself so each call site can throw a `Failure` naming what it
    /// observed (Tests/CLAUDE.md rule 4) — only a thrown error lands on the
    /// primary failure line that CI summaries quote.
    private static func waitUntil(_ timeout: Duration,
                                  pollInterval: Duration = .milliseconds(25),
                                  _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        return condition()
    }
}

// MARK: - Local helpers

/// Timeout diagnostics travel as a thrown `Error` so they land on the primary
/// failure line and survive into the CI summary (Tests/CLAUDE.md, rule 4).
private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A `Clock` that delegates to a `TestClock` and counts every armed sleep.
///
/// Mirrors `FileWatcherTests.RecordingClock`, for the same reason: arming is
/// the only *positive, pollable* fact that the FS event was delivered and
/// production reached its timer. `TestClock.checkSuspension()` can answer only
/// "is anything suspended", so it cannot distinguish a superseded debounce
/// still being torn down from the fresh one a later write just armed.
///
/// Delegating rather than reimplementing keeps virtual time exactly
/// `TestClock`'s, so `advanceWhenSuspended` on the base clock behaves normally.
private struct RecordingClock: Clock {
    let base: TestClock<Swift.Duration>
    let armed: Counter

    var now: TestClock<Swift.Duration>.Instant { base.now }
    var minimumResolution: Swift.Duration { base.minimumResolution }

    func sleep(until deadline: TestClock<Swift.Duration>.Instant,
               tolerance: Swift.Duration?) async throws {
        armed.record()
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
