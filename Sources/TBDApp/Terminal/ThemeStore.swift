import Foundation
import Combine
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "themes")

@MainActor
final class ThemeStore: ObservableObject {

    @Published private(set) var userThemes: [TerminalColorScheme] = []
    @Published private(set) var loadErrors: [LoadError] = []

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
        var loaded: [TerminalColorScheme] = []
        var errors: [LoadError] = []

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: themesDirectory,
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
}

#if DEBUG
extension ThemeStore {
    /// Test seam: inject user themes without touching disk.
    func injectForTest(userThemes: [TerminalColorScheme]) {
        self.userThemes = userThemes
    }
}
#endif
