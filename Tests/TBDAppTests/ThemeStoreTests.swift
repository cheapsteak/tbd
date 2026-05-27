import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Suite("ThemeStore")
struct ThemeStoreTests {
    private func makeIsolatedHome() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-themestore-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("TBD_HOME", dir.path, 1)
        return dir
    }

    @Test("returns empty when the themes dir doesn't exist yet")
    func emptyWhenDirMissing() async {
        _ = makeIsolatedHome()
        let store = ThemeStore()
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)
    }

    @Test("loads all valid JSON theme files")
    func loadsValidThemes() async throws {
        let home = makeIsolatedHome()
        let themesDir = home.appendingPathComponent("terminal-themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "my-test", displayName: "My Test",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        let data = try JSONEncoder().encode(theme)
        try data.write(to: themesDir.appendingPathComponent("my-test.json"))

        let store = ThemeStore()
        store.reloadFromDisk()
        #expect(store.userThemes.count == 1)
        #expect(store.userThemes.first?.id == "my-test")
    }

    @Test("skips malformed JSON files and records the error")
    func skipsMalformed() async throws {
        let home = makeIsolatedHome()
        let themesDir = home.appendingPathComponent("terminal-themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        try "{ not json".write(
            to: themesDir.appendingPathComponent("bad.json"),
            atomically: true, encoding: .utf8
        )

        let store = ThemeStore()
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)
        #expect(store.loadErrors.count == 1)
        #expect(store.loadErrors.first?.filename == "bad.json")
    }

    @Test("ignores files that aren't .json")
    func ignoresNonJSON() async throws {
        let home = makeIsolatedHome()
        let themesDir = home.appendingPathComponent("terminal-themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        try "ignored".write(
            to: themesDir.appendingPathComponent("foo.toml"),
            atomically: true, encoding: .utf8
        )

        let store = ThemeStore()
        store.reloadFromDisk()
        #expect(store.userThemes.isEmpty)
        #expect(store.loadErrors.isEmpty)
    }
}
