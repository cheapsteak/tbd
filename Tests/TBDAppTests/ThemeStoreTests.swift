import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

@MainActor
@Suite("ThemeStore")
struct ThemeStoreTests {
    /// Returns a fresh, isolated themes directory for each test.
    /// Creates the directory on disk and returns its URL directly,
    /// with no setenv — so parallel tests never race on TBD_HOME.
    private func makeIsolatedThemesDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-themestore-tests-\(UUID().uuidString)")
            .appendingPathComponent("terminal-themes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("returns empty when the themes dir doesn't exist yet")
    func emptyWhenDirMissing() async {
        // Pass a URL that doesn't exist — ThemeStore should handle it silently.
        let nonExistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-themestore-tests-\(UUID().uuidString)")
            .appendingPathComponent("terminal-themes")
        let store = ThemeStore(themesDirectory: nonExistent)
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)
    }

    @Test("loads all valid JSON theme files")
    func loadsValidThemes() async throws {
        let themesDir = try makeIsolatedThemesDir()

        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "my-test", displayName: "My Test",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        let data = try JSONEncoder().encode(theme)
        try data.write(to: themesDir.appendingPathComponent("my-test.json"))

        let store = ThemeStore(themesDirectory: themesDir)
        store.reloadFromDisk()
        #expect(store.userThemes.count == 1)
        #expect(store.userThemes.first?.id == "my-test")
    }

    @Test("skips malformed JSON files and records the error")
    func skipsMalformed() async throws {
        let themesDir = try makeIsolatedThemesDir()
        try "{ not json".write(
            to: themesDir.appendingPathComponent("bad.json"),
            atomically: true, encoding: .utf8
        )

        let store = ThemeStore(themesDirectory: themesDir)
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)
        #expect(store.loadErrors.count == 1)
        #expect(store.loadErrors.first?.filename == "bad.json")
    }

    @Test("ignores files that aren't .json")
    func ignoresNonJSON() async throws {
        let themesDir = try makeIsolatedThemesDir()
        try "ignored".write(
            to: themesDir.appendingPathComponent("foo.toml"),
            atomically: true, encoding: .utf8
        )

        let store = ThemeStore(themesDirectory: themesDir)
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)
        #expect(store.loadErrors.isEmpty)
    }

    @Test("saveAs slugifies the display name and writes JSON")
    func saveAsSlugifies() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)

        let id = try store.saveAs(
            UserTerminalTheme(
                schemaVersion: 1, id: "", displayName: "My Cool Theme!",
                ansi: Array(repeating: "#000000", count: 16),
                foreground: "#ffffff", background: "#000000",
                cursor: "#ffffff", selection: "#505050"
            ),
            suggestedDisplayName: "My Cool Theme!"
        )
        #expect(id == "my-cool-theme")
        let file = themesDir.appendingPathComponent("my-cool-theme.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("saveAs deduplicates by appending -2, -3 etc.")
    func saveAsDedupes() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)
        let draft = UserTerminalTheme(
            schemaVersion: 1, id: "", displayName: "Gruvbox Dark Copy",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        let id1 = try store.saveAs(draft, suggestedDisplayName: "Gruvbox Dark Copy")
        let id2 = try store.saveAs(draft, suggestedDisplayName: "Gruvbox Dark Copy")
        let id3 = try store.saveAs(draft, suggestedDisplayName: "Gruvbox Dark Copy")
        #expect(id1 == "gruvbox-dark-copy")
        #expect(id2 == "gruvbox-dark-copy-2")
        #expect(id3 == "gruvbox-dark-copy-3")
    }

    @Test("saveAs refuses ids that collide with bundled schemes")
    func saveAsRefusesBundledCollision() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)
        let draft = UserTerminalTheme(
            schemaVersion: 1, id: "", displayName: "Gruvbox Dark",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        #expect(throws: ThemeStore.SaveError.self) {
            try store.saveAs(draft, suggestedDisplayName: "Gruvbox Dark")
        }
    }

    @Test("save overwrites the existing file for the same id")
    func saveOverwrites() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)
        let draft = UserTerminalTheme(
            schemaVersion: 1, id: "", displayName: "Foo",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        let id = try store.saveAs(draft, suggestedDisplayName: "Foo")

        let edited = UserTerminalTheme(
            schemaVersion: 1, id: id, displayName: "Foo",
            ansi: Array(repeating: "#ff0000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        try store.save(edited)
        store.reloadFromDisk()
        #expect(store.userThemes.first?.ansi[0].red == UInt16(0xff) * 257)
    }

    @Test("delete moves the file into .trash/ with a timestamp suffix")
    func deleteSoftDeletes() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)
        let draft = UserTerminalTheme(
            schemaVersion: 1, id: "", displayName: "Throwaway",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        let id = try store.saveAs(draft, suggestedDisplayName: "Throwaway")

        try store.delete(id: id)

        let originalPath = themesDir.appendingPathComponent("\(id).json")
        #expect(!FileManager.default.fileExists(atPath: originalPath.path))

        let trashDir = themesDir.appendingPathComponent(".trash")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trashDir.path)
        #expect(trashed.count == 1)
        #expect(trashed[0].hasPrefix("\(id)-"))
    }

    @Test("external file additions trigger a reload via the watcher")
    func watcherReloadsOnExternalAdd() async throws {
        let themesDir = try makeIsolatedThemesDir()

        let store = ThemeStore(themesDirectory: themesDir)
        store.startWatching()
        defer { store.stopWatching() }
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)

        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "ext", displayName: "Ext",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        // Two phases. The watcher's stream starts at
        // `kFSEventStreamEventIdSinceNow`, so a write made right after
        // `startWatching()` can fall before the point the stream counts as now
        // when `fseventsd` lags, and no event for it ever arrives. CI shows that
        // loss: on each red run every other test in the pass had finished
        // 18–40 s before this one gave up, so nothing was queued ahead of the
        // watcher's main-actor callback, and the reload still never came. A user
        // adds a theme long after the watcher is live, so the miss is a property
        // of this test's timing, not of the behaviour under test.
        //
        // Phase 1 waits for the stream to be live: it re-adds `ext.json` every
        // few seconds until a reload is seen. Each re-add removes the file
        // first, so it is still an add, and the retry path never calls
        // `reloadFromDisk()`, so only the watcher's own callback can fill
        // `userThemes`. Phase 2 then adds `ext2.json` once, with no re-adds:
        // the stream is proven live, so the since-now miss cannot apply, and a
        // watcher that drops a single add fails the test.
        //
        // Each wait is a hang guard, not a tolerance window: it ends on the
        // first satisfying probe. Its budget is `TestDeadlines.saturatedPass`
        // because the poll and the callback's `Task { @MainActor in ... }`
        // reload both need turns on the main actor, which every `@MainActor`
        // test in the pass queues for; green runs have reported this test at up
        // to 87.6 s (Tests/CLAUDE.md, "Population is the scheduler").
        let contents = try JSONEncoder().encode(theme)
        let adder = ThemeFileAdder(file: themesDir.appendingPathComponent("ext.json"), contents: contents)
        let reAddInterval: Duration = .seconds(5)
        let start = ContinuousClock.now
        try adder.add()
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(100)
        ) { @Sendable in
            await MainActor.run { () -> Bool in
                if !store.userThemes.isEmpty { return true }
                adder.reAddIfDue(every: reAddInterval)
                return false
            }
        }
        switch outcome {
        case .satisfied:
            break
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            // Thrown, not `#expect(..., "message")`: only `Issue.record(_: some
            // Error)` puts the diagnostic on the primary failure line CI
            // summaries quote (Tests/CLAUDE.md rule 4). The count of adds over
            // the elapsed time separates a lost first event (one add, or few)
            // from a watcher that never fires (many adds, none seen).
            // `loadErrors` separates "reload ran but decode failed" from
            // "reload never ran", and the directory listing separates "the file
            // never landed" (a test bug) from "the watcher never fired".
            throw Failure("""
                the themes-directory watcher never reloaded after an external add — \
                \(adder.adds) add(s) of ext.json over \(ContinuousClock.now - start) \
                (budget \(TestDeadlines.saturatedPass)), none seen; \
                failed re-adds=\(adder.failures), \
                userThemes=\(store.userThemes.map(\.id)), \
                loadErrors=\(store.loadErrors), \
                directory contents=\(String(describing: try? FileManager.default
                    .contentsOfDirectory(atPath: themesDir.path)))
                """)
        }
        let afterFirst = store.userThemes.map(\.id)
        #expect(afterFirst == ["ext"])

        // Phase 2: one add, no re-adds.
        let second = UserTerminalTheme(
            schemaVersion: 1, id: "ext2", displayName: "Ext 2",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        try JSONEncoder().encode(second).write(to: themesDir.appendingPathComponent("ext2.json"))
        let secondStart = ContinuousClock.now
        let secondOutcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(100)
        ) { @Sendable in
            await MainActor.run { () -> Bool in
                store.userThemes.contains { theme in theme.id == "ext2" }
            }
        }
        switch secondOutcome {
        case .satisfied:
            break
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw Failure("""
                the themes-directory watcher missed a single add once its stream was live — \
                ext2.json, added once, not seen after \(ContinuousClock.now - secondStart) \
                (budget \(TestDeadlines.saturatedPass)); \
                userThemes=\(store.userThemes.map(\.id)), \
                loadErrors=\(store.loadErrors), \
                directory contents=\(String(describing: try? FileManager.default
                    .contentsOfDirectory(atPath: themesDir.path)))
                """)
        }
        let ids = store.userThemes.map(\.id).sorted()
        #expect(ids == ["ext", "ext2"])
    }

    @Test("saveAs rejects display names that slugify to empty")
    func saveAsRejectsEmptySlug() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)
        let draft = UserTerminalTheme(
            schemaVersion: 1, id: "", displayName: "!!!",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        #expect(throws: ThemeStore.SaveError.self) {
            try store.saveAs(draft, suggestedDisplayName: "!!!")
        }
    }

    @Test("save throws when called for an id that has no file on disk")
    func saveThrowsForUnknownID() async throws {
        let themesDir = try makeIsolatedThemesDir()
        let store = ThemeStore(themesDirectory: themesDir)
        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "ghost", displayName: "Ghost",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        #expect(throws: ThemeStore.SaveError.self) {
            try store.save(theme)
        }
    }

    @Test("save refuses to overwrite a file whose id collides with a bundled scheme")
    func saveRefusesBundledCollision() async throws {
        let themesDir = try makeIsolatedThemesDir()

        // Plant a stray JSON named after a bundled scheme (simulates a manual cp
        // or a future import path) so the fileExists guard would otherwise pass.
        let stray = UserTerminalTheme(
            schemaVersion: 1, id: "gruvbox-dark", displayName: "Stray",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        try JSONEncoder().encode(stray)
            .write(to: themesDir.appendingPathComponent("gruvbox-dark.json"))

        let store = ThemeStore(themesDirectory: themesDir)
        do {
            try store.save(stray)
            Issue.record("expected SaveError.bundledIDCollision")
        } catch let ThemeStore.SaveError.bundledIDCollision(id) {
            #expect(id == "gruvbox-dark")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("when the active theme file vanishes, the schemeID reverts to default")
    func activeThemeVanishesFallsBack() async throws {
        let themesDir = try makeIsolatedThemesDir()

        let suite = TestDefaultsSuite("tbd.test.fallback")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let appearance = AppearanceSettings(defaults: defaults)
        let store = ThemeStore(themesDirectory: themesDir)
        appearance.themeStore = store

        // Create a user theme and select it.
        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "ephemeral", displayName: "Ephemeral",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        try JSONEncoder().encode(theme)
            .write(to: themesDir.appendingPathComponent("ephemeral.json"))
        store.reloadFromDisk()
        appearance.schemeID = "ephemeral"
        appearance.draftSchemeOverride = ColorSchemes.scheme(forID: "tango")

        // Externally delete the file (simulates `rm`).
        try FileManager.default.removeItem(at: themesDir.appendingPathComponent("ephemeral.json"))
        store.reloadFromDisk()
        appearance.reconcileWithStore()

        #expect(appearance.schemeID == ColorSchemes.defaultScheme.id)
        #expect(appearance.draftSchemeOverride == nil)
    }
}

// MARK: - Local helpers

/// Timeout diagnostics travel as a thrown `Error` so they land on the primary
/// failure line and survive into the CI summary (Tests/CLAUDE.md, rule 4).
private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Adds one theme file to a watched directory, again on request, and counts the
/// adds, so a timeout can say how many the watcher missed. It writes the file
/// and nothing else: it never reloads the store, so only the watcher's callback
/// can make a write visible.
@MainActor
private final class ThemeFileAdder {
    let file: URL
    let contents: Data
    /// Writes that landed.
    private(set) var adds = 0
    /// Re-adds whose write failed, as their errors read.
    private(set) var failures: [String] = []
    private var lastAttempt = ContinuousClock.now

    init(file: URL, contents: Data) {
        self.file = file
        self.contents = contents
    }

    /// Writes the file as a new one: an earlier copy is removed first, so each
    /// write is an add rather than a change to a file already there.
    func add() throws {
        lastAttempt = ContinuousClock.now
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try contents.write(to: file)
        adds += 1
    }

    /// Adds the file again once `interval` has passed since the last attempt,
    /// recording a failed write instead of throwing it, since the poll that
    /// calls this cannot throw.
    func reAddIfDue(every interval: Duration) {
        guard ContinuousClock.now - lastAttempt >= interval else { return }
        do {
            try add()
        } catch {
            failures.append("\(error)")
        }
    }
}
