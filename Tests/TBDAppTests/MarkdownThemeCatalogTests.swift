import Foundation
import Testing
@testable import TBDApp

/// Tier 1 (real filesystem, but no concurrency, no sleeps, no external process).
///
/// Every test supplies its own tmp themes directory and its own
/// `UserDefaults(suiteName:)`. Neither `~/tbd` nor `UserDefaults.standard` is
/// reachable from here: `TBD_HOME` may not be `setenv`'d outside
/// `TBDHomeSerialized` in `TBDDaemonTests`, and `.standard` on this unbundled
/// executable is the developer's real `TBDApp.plist`.
@Suite("MarkdownThemeCatalog")
struct MarkdownThemeCatalogTests {

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let name = "com.tbd.tests.markdown-theme-catalog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        return try body(defaults)
    }

    private func write(_ contents: String, named name: String, in dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private let bundledMarker = "/* bundled marker */\nbody{color:red}"

    // MARK: - Enumeration

    @Test("enumeration lists only *.css files, by stem, sorted case-insensitively")
    func enumerationListsStems() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "Zebra.css", in: dir)
        try write("a{}", named: "amber.css", in: dir)
        try write("a{}", named: "notes.md", in: dir)
        try write("a{}", named: "theme.css.bak", in: dir)
        try write("a{}", named: "README", in: dir)

        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir) == ["amber", "Zebra"])
    }

    @Test("an uppercase .CSS extension still counts")
    func uppercaseExtensionCounts() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "Loud.CSS", in: dir)

        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir) == ["Loud"])
    }

    @Test("a directory named like a stylesheet is not listed")
    func directoryNamedCSSIgnored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("bundle.css"), withIntermediateDirectories: true
        )
        try write("a{}", named: "real.css", in: dir)

        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir) == ["real"])
    }

    @Test("enumerating a missing directory returns empty rather than throwing")
    func missingDirectoryEnumeratesEmpty() throws {
        let dir = try tempDir()
        try FileManager.default.removeItem(at: dir)

        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir).isEmpty)
    }

    @Test("an empty directory returns empty")
    func emptyDirectoryEnumeratesEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir).isEmpty)
    }

    // MARK: - Selection state

    @Test("no stored theme means no selection and nothing missing")
    func noSelection() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "amber.css", in: dir)

        try withDefaults { defaults in
            let catalog = MarkdownThemeCatalog.load(themesDirectory: dir, defaults: defaults)
            #expect(catalog.installed == ["amber"])
            #expect(catalog.selected == nil)
            #expect(catalog.missingSelection == nil)
        }
    }

    @Test("a stored theme whose file exists is selected and not reported missing")
    func presentSelection() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "amber.css", in: dir)

        try withDefaults { defaults in
            defaults.set("amber", forKey: MarkdownStylesheet.themeKey)
            let catalog = MarkdownThemeCatalog.load(themesDirectory: dir, defaults: defaults)
            #expect(catalog.selected == "amber")
            #expect(catalog.missingSelection == nil)
        }
    }

    @Test("a stored theme whose file is absent is reported as missing, not silently defaulted")
    func missingSelectionReported() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "amber.css", in: dir)

        try withDefaults { defaults in
            defaults.set("deleted", forKey: MarkdownStylesheet.themeKey)
            let catalog = MarkdownThemeCatalog.load(themesDirectory: dir, defaults: defaults)
            #expect(catalog.selected == "deleted")
            #expect(catalog.missingSelection == "deleted")
            // The point of surfacing it: resolution has already fallen back, so
            // nothing else would tell the user their selection is dead.
            #expect(MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: bundledMarker
            ) == bundledMarker)
        }
    }

    @Test("a selection is reported missing when the whole directory is gone")
    func missingDirectoryMakesSelectionMissing() throws {
        let dir = try tempDir()
        try FileManager.default.removeItem(at: dir)

        try withDefaults { defaults in
            defaults.set("amber", forKey: MarkdownStylesheet.themeKey)
            let catalog = MarkdownThemeCatalog.load(themesDirectory: dir, defaults: defaults)
            #expect(catalog.installed.isEmpty)
            #expect(catalog.missingSelection == "amber")
        }
    }

    @Test("a path-bearing stored theme is rejected upstream, so it is neither selected nor missing")
    func pathBearingSelectionRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDefaults { defaults in
            defaults.set("../outside/secret", forKey: MarkdownStylesheet.themeKey)
            let catalog = MarkdownThemeCatalog.load(themesDirectory: dir, defaults: defaults)
            #expect(catalog.selected == nil)
            #expect(catalog.missingSelection == nil)
        }
    }

    // MARK: - Name selection

    @Test("the first copy takes the base name, later ones increment the suffix")
    func nameSuffixIncrements() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownThemeCatalog.nextAvailableThemeID(in: dir) == "custom")
        try write("a{}", named: "custom.css", in: dir)
        #expect(MarkdownThemeCatalog.nextAvailableThemeID(in: dir) == "custom-2")
        try write("a{}", named: "custom-2.css", in: dir)
        #expect(MarkdownThemeCatalog.nextAvailableThemeID(in: dir) == "custom-3")
    }

    // MARK: - Duplicate Default

    @Test("duplicating seeds the bundled CSS plus a no-auto-update header")
    func duplicateSeedsBundledPlusHeader() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: bundledMarker))
        #expect(id == "custom")

        let written = try String(
            contentsOf: dir.appendingPathComponent("custom.css"), encoding: .utf8
        )
        #expect(written.contains(bundledMarker))
        // The header is the whole point: a copy wins over the bundled sheet, so
        // an upstream fix is invisible to whoever holds one.
        #expect(written.hasPrefix("/*"))
        #expect(written.lowercased().contains("will not receive future updates"))
        #expect(written.contains("snapshot"))
    }

    @Test("the seeded file is what resolution then uses")
    func seededFileResolves() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: bundledMarker))
        try withDefaults { defaults in
            defaults.set(id, forKey: MarkdownStylesheet.themeKey)
            let resolved = MarkdownStylesheet.resolve(
                themesDirectory: dir, defaults: defaults, bundled: "/* not this one */"
            )
            #expect(resolved.contains(bundledMarker))
            #expect(resolved.contains(MarkdownThemeCatalog.snapshotHeader))
        }
    }

    @Test("duplicating twice never clobbers: the second copy gets the next suffix")
    func duplicateDoesNotClobber() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: "/* one */"))
        let second = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: "/* two */"))
        let third = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: "/* three */"))

        #expect([first, second, third] == ["custom", "custom-2", "custom-3"])
        // Each file still holds its own contents — nothing was overwritten.
        #expect(try String(contentsOf: dir.appendingPathComponent("custom.css"), encoding: .utf8)
            .contains("/* one */"))
        #expect(try String(contentsOf: dir.appendingPathComponent("custom-2.css"), encoding: .utf8)
            .contains("/* two */"))
        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir) == ["custom", "custom-2", "custom-3"])
    }

    @Test("duplicating never clobbers a hand-made file that already owns the name")
    func duplicateSkipsHandMadeName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("/* mine, do not touch */", named: "custom.css", in: dir)

        let id = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: bundledMarker))
        #expect(id == "custom-2")
        #expect(try String(contentsOf: dir.appendingPathComponent("custom.css"), encoding: .utf8)
            == "/* mine, do not touch */")
    }

    @Test("duplicating creates the themes directory when it is absent")
    func duplicateCreatesDirectory() throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("markdown-themes", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        let id = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: bundledMarker))
        #expect(id == "custom")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("custom.css").path))
    }

    @Test("duplicating reports failure when the themes path is a regular file")
    func duplicateFailsOnFileInPlaceOfDirectory() throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("markdown-themes")
        try "not a directory".write(to: dir, atomically: true, encoding: .utf8)

        #expect(MarkdownThemeCatalog.duplicateBundledDefault(in: dir, bundled: bundledMarker) == nil)
    }

    @Test("the real bundled default is what a copy carries")
    func duplicateUsesTheRealBundledDefault() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try #require(MarkdownThemeCatalog.duplicateBundledDefault(in: dir))
        let written = try String(
            contentsOf: dir.appendingPathComponent("\(id).css"), encoding: .utf8
        )
        #expect(written.contains(MarkdownStylesheet.bundledCSS))
        #expect(written.contains("prefers-color-scheme"))
    }
}
