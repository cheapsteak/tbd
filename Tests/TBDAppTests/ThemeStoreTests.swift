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

    /// The watcher is FSEvents-backed, so its reload waits on `fseventsd`, a
    /// daemon outside this process. On CI under the fast pass's filesystem
    /// load, deliveries took 21–88 s on green runs, and on red runs none
    /// arrived within the budget even while the process was otherwise idle; a
    /// red run that re-added the file every 5 s saw none of 19 adds in 120 s.
    /// No wait in the test can shorten that, so the test is quarantined: the
    /// trait retries it, and #1201 holds the diagnosis and the follow-up.
    @Test("external file additions trigger a reload via the watcher", .flaky(issue: 1201))
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
        try JSONEncoder().encode(theme)
            .write(to: themesDir.appendingPathComponent("ext.json"))

        // A hang guard, not a tolerance window: the wait ends on the first
        // satisfying probe, so only a run whose event never arrives pays the
        // budget, the shared `TestDeadlines.saturatedPass`.
        let start = ContinuousClock.now
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(100)
        ) { @Sendable in
            await MainActor.run { !store.userThemes.isEmpty }
        }
        switch outcome {
        case .satisfied:
            break
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            // Thrown, not `#expect(..., "message")`: only `Issue.record(_: some
            // Error)` puts the diagnostic on the primary failure line CI
            // summaries quote (Tests/CLAUDE.md rule 4). `loadErrors` separates
            // "reload ran but decode failed" from "reload never ran", and the
            // directory listing separates "the file never landed" (a test bug)
            // from "the watcher never fired".
            throw Failure("""
                the themes-directory watcher never reloaded after an external add — \
                after \(ContinuousClock.now - start) (budget \(TestDeadlines.saturatedPass)), \
                userThemes=\(store.userThemes.map(\.id)), \
                loadErrors=\(store.loadErrors), \
                directory contents=\(String(describing: try? FileManager.default
                    .contentsOfDirectory(atPath: themesDir.path)))
                """)
        }
        #expect(store.userThemes.count == 1)
        #expect(store.userThemes.first?.id == "ext")
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
