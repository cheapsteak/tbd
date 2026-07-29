import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// Resolves the CSS handed to the markdown viewer.
///
/// The stylesheet *is* the configuration format — see
/// `docs/specs/2026-07-28-markdown-display-options-design.md`, "Freeform CSS as
/// the configuration format". A user stylesheet lives at
/// `<themesDirectory>/<themeID>.css`, where `themeID` comes from the
/// `markdown.viewer.theme` user default; anything missing, unreadable, or blank
/// falls back to the bundled sheet.
///
/// ## Deliberately not cached
///
/// `resolve` reads the file on **every render**. The predecessor of this type
/// was a `static let` on `MarkdownDocumentBuilder`, which meant a stylesheet
/// edit only took effect after a rebuild and relaunch. Only `bundledCSS` stays
/// cached, because a resource inside the bundle genuinely cannot change without
/// a rebuild.
///
/// ## Injection seam
///
/// Every entry point takes the themes directory and the `UserDefaults` instance
/// as parameters, defaulted to production values. Tests pass a tmp directory and
/// a `UserDefaults(suiteName:)` — they must never touch `~/tbd` or the
/// developer's real `TBDApp.plist`.
enum MarkdownStylesheet {

    /// Selected theme ID — a bare filename stem, no extension and no path
    /// components. Absent or empty means "use the bundled default".
    static let themeKey = "markdown.viewer.theme"

    /// The selected theme ID, or `nil` when none is selected or the stored
    /// value is unusable.
    static func themeID(_ defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: themeKey) else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        // A theme ID names one file *inside* the themes directory; it is never
        // a path. Rejecting separators and the dot entries keeps a hand-edited
        // default from aiming the viewer at an arbitrary file on disk.
        guard !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else {
            logger.error("ignoring markdown theme id containing path components: \(id, privacy: .public)")
            return nil
        }
        return id
    }

    /// Where the selected theme's stylesheet would live, or `nil` when no theme
    /// is selected. The file need not exist — this is also what the live-reload
    /// watcher watches.
    static func userStylesheetURL(
        themesDirectory: URL = TBDConstants.markdownThemesDir,
        defaults: UserDefaults = .standard
    ) -> URL? {
        guard let id = themeID(defaults) else { return nil }
        return themesDirectory.appendingPathComponent("\(id).css")
    }

    /// The CSS to inline into the next rendered document.
    ///
    /// Resolution order, first match wins:
    /// 1. `<themesDirectory>/<themeID>.css`, when `markdown.viewer.theme` names
    ///    a usable ID and the file reads as non-blank UTF-8.
    /// 2. `bundled` — the app's `markdown-default.css`.
    ///
    /// A blank file falls through to the bundled sheet on purpose: a zero-byte
    /// stylesheet is far more likely to be a half-finished edit than a request
    /// to render completely unstyled, and unstyled markdown reads as a bug.
    static func resolve(
        themesDirectory: URL = TBDConstants.markdownThemesDir,
        defaults: UserDefaults = .standard,
        bundled: String = MarkdownStylesheet.bundledCSS
    ) -> String {
        guard let url = userStylesheetURL(themesDirectory: themesDirectory, defaults: defaults) else {
            return bundled
        }
        guard let css = try? String(contentsOf: url, encoding: .utf8) else {
            // Missing, unreadable, or not valid UTF-8. `.debug` rather than
            // `.error`: "no user stylesheet yet" is the common case.
            logger.debug("markdown stylesheet unavailable, using bundled default: \(url.path, privacy: .public)")
            return bundled
        }
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("markdown stylesheet is blank, using bundled default: \(url.path, privacy: .public)")
            return bundled
        }
        return css
    }

    /// Creates `directory` if it is absent, returning whether it exists
    /// afterwards.
    ///
    /// The live-reload watcher opens the themes *directory* so that a
    /// stylesheet created after the viewer opened is noticed, and
    /// `open(2)` cannot watch a directory that does not exist yet. Callers only
    /// reach this once the user has actually selected a theme, so TBD does not
    /// litter `~/tbd` for people who never touched the setting.
    @discardableResult
    static func ensureThemesDirectoryExists(_ directory: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            logger.error("could not create markdown themes directory \(directory.path, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    /// The bundled stylesheet. Falls back to an empty string if the resource is
    /// missing, which renders unstyled rather than failing the document.
    ///
    /// Cached for the process lifetime, which is correct here and only here: a
    /// bundle resource cannot change without a rebuild.
    static let bundledCSS: String = {
        guard let url = Bundle.module.url(forResource: "markdown-default", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("bundled markdown-default.css missing; rendering unstyled")
            return ""
        }
        return css
    }()
}
