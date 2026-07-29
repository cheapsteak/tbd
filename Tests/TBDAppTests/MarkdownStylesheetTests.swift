import Foundation
import Testing
@testable import TBDApp

/// Tier 1, except for `themesDirectoryWatchSeesAStylesheetCreatedLater`, which
/// is tier 2 (real filesystem, real dispatch source, bounded polling).
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
        let name = "com.tbd.tests.markdown-stylesheet.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
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

    @Test("the bundled stylesheet URL resolves and points at the file bundledCSS reads")
    func bundledURLResolves() throws {
        let url = try #require(MarkdownStylesheet.bundledURL)
        #expect(url.lastPathComponent == "markdown-default.css")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == MarkdownStylesheet.bundledCSS)
    }

    // MARK: - Live reload (tier 2)

    /// The load-bearing assumption behind watching the themes *directory*: a
    /// `FileWatcher` on a directory fires when an entry is created inside it.
    /// That is the only way the viewer can notice a stylesheet that did not
    /// exist when it opened — there is no inode for a file watcher to open.
    ///
    /// Tier 2 by construction (real dispatch source), so it uses the production
    /// clock and bounded polling rather than a `TestClock`.
    @Test("a watch on the themes directory sees a stylesheet created later")
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

        let notified = Counter()
        let watcher = FileWatcher()
        let stream = watcher.changes(for: dir.path)
        let consumer = Task { for await _ in stream { notified.record() } }
        defer { consumer.cancel() }

        // Same dispatch-source registration race `FileWatcherTests` documents:
        // `resume()` is asynchronous, so the first create can land before the
        // source is listening. Retry, waiting out three full debounce windows
        // per attempt.
        let url = dir.appendingPathComponent("later.css")
        for attempt in 0..<4 {
            try "body{color:teal}".write(
                to: dir.appendingPathComponent("probe-\(attempt).css"),
                atomically: true, encoding: .utf8
            )
            let deadline = ContinuousClock.now.advanced(by: FileWatcher.debounceInterval * 3)
            while notified.count == 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if notified.count > 0 { break }
        }
        guard notified.count > 0 else {
            throw Failure("""
                a FileWatcher on a directory never reported an entry being created — \
                observed \(notified.count) notifications after \
                4 attempts of \(FileWatcher.debounceInterval * 3) each
                """)
        }

        // The event the viewer actually cares about: the selected stylesheet
        // appearing. After it, resolution must stop returning the bundled sheet.
        let before = notified.count
        try "body{color:teal}".write(to: url, atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while notified.count == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard notified.count > before else {
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
}

// MARK: - Local helpers

/// Timeout diagnostics travel as a thrown `Error` so they land on the primary
/// failure line and survive into the CI summary (Tests/CLAUDE.md, rule 4).
private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
