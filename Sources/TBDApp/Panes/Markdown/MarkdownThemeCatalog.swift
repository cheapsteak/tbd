import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// What Settings needs to know about the markdown themes directory: which
/// stylesheets are installed, which one is selected, and whether that selection
/// still points at a file.
///
/// All of it is pure filesystem + `UserDefaults` reading, kept out of the view
/// so it is testable with an explicit directory and an explicit defaults suite —
/// the Settings pane is a thin shell over this type. There is no file watcher
/// here on purpose: a settings pane re-enumerates on appear and after each
/// action that changes the directory. The *viewer* watches (see
/// `CodeViewerPaneView`), because it has to re-render.
enum MarkdownThemeCatalog {

    /// Filename stem the "New from Default" action prefers.
    static let defaultCopyBase = "custom"

    /// How far the `custom`, `custom-2`, `custom-3`… search runs before giving
    /// up and appending a random suffix. Nobody has 400 stylesheets; the cap
    /// exists so the loop is bounded, not because the number matters.
    private static let maxCopySuffix = 400

    /// A snapshot of the themes directory paired with the current selection.
    struct Catalog: Equatable, Sendable {
        /// Theme IDs (filename stems) of every `*.css` in the directory, sorted
        /// case-insensitively.
        var installed: [String] = []
        /// The stored theme ID, or `nil` for "use the bundled default".
        var selected: String?
        /// The stored theme ID when it names no installed stylesheet.
        ///
        /// Surfaced explicitly rather than collapsed into `nil`: resolution
        /// already falls back to the bundled sheet, so a picker that quietly
        /// showed "Default (bundled)" would leave the user with a dead
        /// selection and no way to notice.
        var missingSelection: String?
    }

    /// Reads the directory and the selection in one shot.
    static func load(
        themesDirectory: URL = TBDConstants.markdownThemesDir,
        defaults: UserDefaults = .standard
    ) -> Catalog {
        let installed = installedThemeIDs(in: themesDirectory)
        let selected = MarkdownStylesheet.themeID(defaults)
        return Catalog(
            installed: installed,
            selected: selected,
            missingSelection: selected.flatMap { installed.contains($0) ? nil : $0 }
        )
    }

    /// Theme IDs of every `*.css` file directly inside `directory`, sorted
    /// case-insensitively.
    ///
    /// A missing or unreadable directory yields an empty list rather than an
    /// error: "you have no themes yet" and "the directory does not exist yet"
    /// are the same thing to a picker.
    static func installedThemeIDs(in directory: URL) -> [String] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            logger.debug("markdown themes directory unreadable: \(directory.path, privacy: .public)")
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "css" }
            // A *directory* named `theme.css` is not a stylesheet.
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// First unused stem in the `custom`, `custom-2`, `custom-3`… sequence.
    ///
    /// Advisory only — `duplicateBundledDefault` still writes with
    /// `.withoutOverwriting`, so nothing is clobbered even if the directory
    /// changes between the check and the write.
    static func nextAvailableThemeID(in directory: URL, base: String = defaultCopyBase) -> String {
        let fm = FileManager.default
        for suffix in 1...maxCopySuffix {
            let id = suffix == 1 ? base : "\(base)-\(suffix)"
            if !fm.fileExists(atPath: directory.appendingPathComponent("\(id).css").path) {
                return id
            }
        }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Header prepended to a seeded copy of the bundled stylesheet.
    ///
    /// Load-bearing, not decoration: a user copy wins over the bundled sheet
    /// outright, so every later fix to the shipped default is invisible to
    /// anyone holding a copy. The file has to say so, because the Settings pane
    /// that said it is long gone by the time it matters.
    ///
    /// Deliberately carries no date. A timestamp would be persisted data and
    /// would need the `Date` seam; the fact that matters ("this will not
    /// update") does not depend on when the copy was made.
    static let snapshotHeader = """
        /*
         * A snapshot of TBD's bundled default markdown stylesheet.
         *
         * This copy will NOT receive future updates to that default. While this
         * theme is selected it wins outright, so later fixes and additions to
         * TBD's own sheet stay invisible here. To follow the bundled sheet
         * again, pick "Default (bundled)" in Settings › General › Markdown.
         *
         * The format is free-form CSS. TBD injects no theme attribute and
         * defines no CSS variable contract, so the --md-* names below are this
         * file's own convention rather than an API.
         */
        """

    /// The contents written by "New from Default": the header, then the
    /// bundled sheet verbatim.
    static func seededStylesheet(bundled: String = MarkdownStylesheet.bundledCSS) -> String {
        "\(snapshotHeader)\n\n\(bundled)"
    }

    /// Seeds a new stylesheet from the bundled default and returns its theme ID,
    /// or `nil` when the directory could not be created or the write failed.
    ///
    /// Never overwrites an existing file: the name search skips taken stems and
    /// the write itself uses `.withoutOverwriting`, which closes the gap between
    /// the two.
    static func duplicateBundledDefault(
        in directory: URL,
        base: String = defaultCopyBase,
        bundled: String = MarkdownStylesheet.bundledCSS
    ) -> String? {
        guard MarkdownStylesheet.ensureThemesDirectoryExists(directory) else { return nil }
        let contents = Data(seededStylesheet(bundled: bundled).utf8)
        // Retry only covers losing the name race to another writer; a real
        // failure (permissions, full disk) bails on the first attempt.
        for _ in 0..<3 {
            let id = nextAvailableThemeID(in: directory, base: base)
            let url = directory.appendingPathComponent("\(id).css")
            do {
                try contents.write(to: url, options: .withoutOverwriting)
                return id
            } catch {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    logger.error("""
                        could not seed markdown stylesheet \(url.path, privacy: .public): \
                        \(error, privacy: .public)
                        """)
                    return nil
                }
            }
        }
        logger.error("could not find a free stylesheet name under \(directory.path, privacy: .public)")
        return nil
    }
}
