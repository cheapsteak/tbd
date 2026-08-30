import Foundation
import TestSupport
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
        let defaultsSuite = TestDefaultsSuite("markdown-theme-catalog")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
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

    // MARK: - New from Default

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

    // MARK: - Picker action sentinel

    @Test("the action tag routes to the action and never to storage")
    func actionTagRoutesToAction() {
        #expect(
            MarkdownThemeCatalog.pickerSelection(forTag: MarkdownThemeCatalog.newFromDefaultTag)
                == .newFromDefault
        )
        #expect(MarkdownThemeCatalog.pickerSelection(forTag: "") == .bundledDefault)
        #expect(MarkdownThemeCatalog.pickerSelection(forTag: "   ") == .bundledDefault)
        #expect(MarkdownThemeCatalog.pickerSelection(forTag: "amber") == .theme("amber"))
    }

    /// The sentinel's guard is that it contains a path separator, which is the
    /// one byte a POSIX filename cannot hold. Without it, a stylesheet named
    /// after the sentinel would silently become an un-selectable entry that
    /// re-fires the create action.
    @Test("no stylesheet filename can produce the action tag")
    func actionTagIsUnreachableFromFilenames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sentinel = MarkdownThemeCatalog.newFromDefaultTag
        #expect(sentinel.contains("/"))

        // Everything a user could plausibly get onto disk while aiming at it.
        // The literal name is impossible — `write` would treat the slashes as
        // directories — so these are the near misses that actually can exist.
        let nearMisses = [
            "\(sentinel.replacingOccurrences(of: "/", with: "-")).css",
            "\(sentinel.replacingOccurrences(of: "/", with: ":")).css",
            "\(sentinel.replacingOccurrences(of: "/", with: "%2F")).css",
            "new-from-default.css",
            "action.css",
        ]
        for name in nearMisses {
            try write("a{}", named: name, in: dir)
        }

        let installed = MarkdownThemeCatalog.installedThemeIDs(in: dir)
        #expect(installed.count == nearMisses.count)
        #expect(!installed.contains(sentinel))
        // Mutation check: the guard is the separator, so a would-be tag that
        // differs only by it must still be classified as a plain theme.
        for id in installed {
            #expect(MarkdownThemeCatalog.pickerSelection(forTag: id) == .theme(id))
        }

        // And if the sentinel somehow reached the stored default by hand, the
        // path-component guard upstream refuses to treat it as a selection.
        try withDefaults { defaults in
            defaults.set(sentinel, forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownStylesheet.themeID(defaults) == nil)
            let catalog = MarkdownThemeCatalog.load(themesDirectory: dir, defaults: defaults)
            #expect(catalog.selected == nil)
            #expect(catalog.missingSelection == nil)
        }
    }

    // MARK: - Reveal target

    @Test("a selected stylesheet that exists is the reveal target")
    func revealTargetIsTheSelectedStylesheet() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "amber.css", in: dir)

        try withDefaults { defaults in
            defaults.set("amber", forKey: MarkdownStylesheet.themeKey)
            let target = MarkdownThemeCatalog.revealTarget(themesDirectory: dir, defaults: defaults)
            #expect(target == .stylesheet(dir.appendingPathComponent("amber.css")))
            #expect(!target.isFolder)
            // The path shown is the path revealed — one value drives both.
            #expect(target.url.lastPathComponent == "amber.css")
        }
    }

    /// The bundled sheet lives inside the `.app`, so there is no user file to
    /// point at and a path in there would be useless.
    @Test("the bundled default reveals the folder, never a path inside the app bundle")
    func revealTargetForBundledDefaultIsTheFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "amber.css", in: dir)

        try withDefaults { defaults in
            let target = MarkdownThemeCatalog.revealTarget(themesDirectory: dir, defaults: defaults)
            #expect(target == .folder(dir))
            #expect(target.isFolder)
            #expect(!target.url.path.contains(".app/"))
        }
    }

    /// `activateFileViewerSelecting` on a nonexistent path silently does
    /// nothing, which reads as a broken button — so a dead selection falls back
    /// to the folder.
    @Test("a selection whose file is gone reveals the folder, not the dead path")
    func revealTargetForMissingSelectionIsTheFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a{}", named: "amber.css", in: dir)

        try withDefaults { defaults in
            defaults.set("deleted", forKey: MarkdownStylesheet.themeKey)
            let target = MarkdownThemeCatalog.revealTarget(themesDirectory: dir, defaults: defaults)
            #expect(target == .folder(dir))
            #expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("deleted.css").path
            ))
        }
    }

    @Test("a missing themes directory still resolves to the folder")
    func revealTargetWithNoDirectory() throws {
        let dir = try tempDir()
        try FileManager.default.removeItem(at: dir)

        try withDefaults { defaults in
            defaults.set("amber", forKey: MarkdownStylesheet.themeKey)
            #expect(MarkdownThemeCatalog.revealTarget(themesDirectory: dir, defaults: defaults)
                == .folder(dir))
        }
    }

    // MARK: - Managed README

    private func readmeURL(in dir: URL) -> URL {
        dir.appendingPathComponent(MarkdownThemeCatalog.managedReadmeName)
    }

    @Test("the README is created, with the overwrite warning ahead of the guide")
    func readmeCreated() throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("markdown-themes", isDirectory: true)

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir, doc: "# Guide\n") == .created)

        let written = try String(contentsOf: readmeURL(in: dir), encoding: .utf8)
        #expect(written.hasSuffix("# Guide\n"))
        #expect(written.hasPrefix("<!--"))
        #expect(written.lowercased().contains("generated by tbd"))
        #expect(written.lowercased().contains("overwritten"))
        // It is a mirror, not a stylesheet — the picker must not list it.
        #expect(MarkdownThemeCatalog.installedThemeIDs(in: dir).isEmpty)
    }

    @Test("a stale README is rewritten from the bundled guide")
    func readmeRefreshedWhenStale() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("# Old guide\n", named: MarkdownThemeCatalog.managedReadmeName, in: dir)

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir, doc: "# New guide\n") == .refreshed)

        let written = try String(contentsOf: readmeURL(in: dir), encoding: .utf8)
        #expect(written.contains("# New guide"))
        #expect(!written.contains("# Old guide"))
    }

    /// Not just "reports `.unchanged`": the modification date is stamped into
    /// the past first, so a rewrite would move it. That is what proves opening
    /// Settings repeatedly does not churn the file.
    @Test("a README that already matches is not rewritten")
    func readmeUntouchedWhenCurrent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir, doc: "# Guide\n") == .created)

        let url = readmeURL(in: dir)
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir, doc: "# Guide\n") == .unchanged)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(after == stamp)
    }

    @Test("no bundled guide means no README rather than an empty one")
    func readmeSkippedWhenGuideUnavailable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir, doc: nil) == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: readmeURL(in: dir).path))
    }

    @Test("a regular file where the themes directory should be reports failure")
    func readmeFailsOnFileInPlaceOfDirectory() throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("markdown-themes")
        try "not a directory".write(to: dir, atomically: true, encoding: .utf8)

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir, doc: "# Guide\n") == .failed)
    }

    /// The bundled resource is the single source of truth; the folder copy is
    /// a mirror of it, so the default argument must actually carry it.
    @Test("the default argument mirrors the real bundled guide")
    func readmeMirrorsTheRealBundledGuide() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir) == .created)
        let written = try String(contentsOf: readmeURL(in: dir), encoding: .utf8)
        let doc = try #require(MarkdownStylesheet.bundledStylesheetDoc)
        #expect(written.contains(doc))
        #expect(doc.contains("# Writing a markdown stylesheet"))
        // Second pass over an untouched folder is a no-op.
        #expect(MarkdownThemeCatalog.syncManagedReadme(in: dir) == .unchanged)
    }
}
