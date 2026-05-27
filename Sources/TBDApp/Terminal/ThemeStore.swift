import Foundation
import Combine
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "themes")

@MainActor
final class ThemeStore: ObservableObject {

    @Published private(set) var userThemes: [TerminalColorScheme] = []
    @Published private(set) var loadErrors: [LoadError] = []

    private var watcher: ThemeDirectoryWatcher?
    // Snapshot of themesDirectory taken at startWatching() time.
    // Keeps the FSEvents callback pointing at the correct directory even if
    // TBD_HOME changes (test isolation via setenv).
    private var watchedDirectory: URL?

    struct LoadError: Equatable, Identifiable {
        let id = UUID()
        let filename: String
        let message: String

        static func == (lhs: LoadError, rhs: LoadError) -> Bool {
            lhs.filename == rhs.filename && lhs.message == rhs.message
        }
    }

    var themesDirectory: URL {
        TBDConstants.configDir.appendingPathComponent("terminal-themes")
    }

    func reloadFromDisk() {
        reloadFromDisk(at: themesDirectory)
    }

    private func reloadFromDisk(at directory: URL) {
        var loaded: [TerminalColorScheme] = []
        var errors: [LoadError] = []

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            self.userThemes = []
            self.loadErrors = []
            return
        }

        for url in entries where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let theme = try JSONDecoder().decode(UserTerminalTheme.self, from: data)
                let scheme = try theme.toScheme()
                loaded.append(scheme)
            } catch {
                logger.warning("Failed to load theme \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                errors.append(LoadError(
                    filename: url.lastPathComponent,
                    message: String(describing: error)
                ))
            }
        }

        self.userThemes = loaded.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        self.loadErrors = errors
    }

    // MARK: - Watching

    func startWatching() {
        guard watcher == nil else { return }
        // Snapshot the directory URL now so the FSEvents callback reloads from
        // the same path even if TBD_HOME changes (e.g. setenv in tests).
        let dir = themesDirectory
        watchedDirectory = dir
        let w = ThemeDirectoryWatcher { [weak self] in
            self?.reloadFromDisk(at: dir)
        }
        w.start(directory: dir)
        self.watcher = w
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchedDirectory = nil
    }

    // MARK: - Save

    enum SaveError: Error, Equatable {
        case bundledIDCollision(String)
        case ioFailed(String)
    }

    enum DeleteError: Error, Equatable {
        case notFound(String)
        case ioFailed(String)
    }

    @discardableResult
    func saveAs(_ draft: UserTerminalTheme, suggestedDisplayName: String) throws -> String {
        let baseSlug = Self.slugify(suggestedDisplayName)
        let id = try uniqueID(basedOn: baseSlug)
        let theme = UserTerminalTheme(
            schemaVersion: draft.schemaVersion,
            id: id,
            displayName: suggestedDisplayName,
            ansi: draft.ansi,
            foreground: draft.foreground,
            background: draft.background,
            cursor: draft.cursor,
            selection: draft.selection
        )
        try persist(theme)
        reloadFromDisk()
        return id
    }

    /// Overwrite an existing user theme by id. For new themes use `saveAs`.
    func save(_ theme: UserTerminalTheme) throws {
        guard fileExists(forID: theme.id) else {
            throw SaveError.ioFailed("save called for unknown id \(theme.id); use saveAs for new themes")
        }
        try persist(theme)
        reloadFromDisk()
    }

    private func uniqueID(basedOn slug: String) throws -> String {
        if ColorSchemes.bundled.contains(where: { $0.id == slug }) {
            throw SaveError.bundledIDCollision(slug)
        }
        if !fileExists(forID: slug) { return slug }
        for n in 2...999 {
            let candidate = "\(slug)-\(n)"
            if ColorSchemes.bundled.contains(where: { $0.id == candidate }) { continue }
            if !fileExists(forID: candidate) { return candidate }
        }
        throw SaveError.ioFailed("could not find a unique id for slug \(slug)")
    }

    private func fileExists(forID id: String) -> Bool {
        let url = themesDirectory.appendingPathComponent("\(id).json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func persist(_ theme: UserTerminalTheme) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        let url = themesDirectory.appendingPathComponent("\(theme.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(theme).write(to: url, options: .atomic)
        } catch {
            throw SaveError.ioFailed(String(describing: error))
        }
    }

    // MARK: - Delete

    func delete(id: String) throws {
        let src = themesDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw DeleteError.notFound(id)
        }
        let trashDir = themesDirectory.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let dst = trashDir.appendingPathComponent("\(id)-\(ts).json")
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            throw DeleteError.ioFailed(String(describing: error))
        }
        reloadFromDisk()
    }

    /// "My Cool Theme!" → "my-cool-theme"
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var prevWasDash = true
        for char in lowered {
            if char.isLetter || char.isNumber {
                out.append(char)
                prevWasDash = false
            } else if !prevWasDash {
                out.append("-")
                prevWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

#if DEBUG
extension ThemeStore {
    /// Test seam: inject user themes without touching disk.
    func injectForTest(userThemes: [TerminalColorScheme]) {
        self.userThemes = userThemes
    }
}
#endif
