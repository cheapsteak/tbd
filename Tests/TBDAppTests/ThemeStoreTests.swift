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

    @Test("saveAs slugifies the display name and writes JSON")
    func saveAsSlugifies() async throws {
        let home = makeIsolatedHome()
        let store = ThemeStore()

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
        let file = home.appendingPathComponent("terminal-themes/my-cool-theme.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("saveAs deduplicates by appending -2, -3 etc.")
    func saveAsDedupes() async throws {
        _ = makeIsolatedHome()
        let store = ThemeStore()
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
    func saveAsRefusesBundledCollision() async {
        _ = makeIsolatedHome()
        let store = ThemeStore()
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
        _ = makeIsolatedHome()
        let store = ThemeStore()
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
}
