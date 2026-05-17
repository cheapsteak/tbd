import AppKit
import Combine
import Foundation
import SwiftTerm

/// Global user-customizable terminal appearance settings.
///
/// One instance lives at the app root and is injected as `@EnvironmentObject`.
/// Live `TBDTerminalView` instances subscribe to `objectWillChange` to reapply
/// font/colors/cursor whenever the user edits a value in the Terminal tab of
/// Settings.
///
/// Persistence: each property writes to `UserDefaults` on `didSet`. `UserDefaults`
/// is injectable for tests (see `Tests/TBDAppTests/AppearanceSettingsTests.swift`).
@MainActor
final class AppearanceSettings: ObservableObject {
    enum Keys {
        static let fontName = "terminal.font.name"
        static let fontSize = "terminal.font.size"
        static let schemeID = "terminal.scheme.id"
        static let cursorStyle = "terminal.cursor.style"
        static let thinStrokes = "terminal.thin-strokes"
    }

    @MainActor
    enum Defaults {
        static let fontName = "Monaco"
        static let fontSize: CGFloat = 12.0
        static let schemeID = "tango"
        static let cursorStyle: CursorStyle = .blinkBlock
        static let thinStrokes = true   // matches iTerm's typical Retina Dark Only behavior
    }

    private let defaults: UserDefaults

    @Published var fontName: String { didSet { defaults.set(fontName, forKey: Keys.fontName) } }
    @Published var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: Keys.fontSize) } }
    @Published var schemeID: String { didSet { defaults.set(schemeID, forKey: Keys.schemeID) } }
    @Published var cursorStyle: CursorStyle { didSet { defaults.set(cursorStyle.rawString, forKey: Keys.cursorStyle) } }
    @Published var thinStrokes: Bool { didSet { defaults.set(thinStrokes, forKey: Keys.thinStrokes) } }

    /// True if the user's tmux config sets a cell-painting style option that
    /// would override the chosen color scheme's foreground/background. Best-
    /// effort detection at init — see `detectTmuxStyleOverrides()`.
    @Published var hasTmuxStyleOverrides: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Font name — accept any non-empty string; resolution happens in `font`.
        let storedName = defaults.string(forKey: Keys.fontName)
        self.fontName = (storedName?.isEmpty == false) ? storedName! : Defaults.fontName

        // Font size — must be > 0 to be valid.
        let storedSize = defaults.double(forKey: Keys.fontSize)
        self.fontSize = storedSize > 0 ? CGFloat(storedSize) : Defaults.fontSize

        // Scheme ID — normalize unknown ids to the default so the Settings Picker
        // always has a matching tag selected (otherwise it renders empty).
        let storedScheme = defaults.string(forKey: Keys.schemeID) ?? Defaults.schemeID
        self.schemeID = ColorSchemes.bundled.contains(where: { $0.id == storedScheme })
            ? storedScheme : Defaults.schemeID

        // Cursor — round-trip via rawString; fall back on unknown.
        let storedCursor = defaults.string(forKey: Keys.cursorStyle) ?? ""
        self.cursorStyle = CursorStyle.from(rawString: storedCursor) ?? Defaults.cursorStyle

        // Thin strokes — UserDefaults.bool(forKey:) returns false for missing keys,
        // so check existence explicitly to apply the default-on behavior.
        if defaults.object(forKey: Keys.thinStrokes) != nil {
            self.thinStrokes = defaults.bool(forKey: Keys.thinStrokes)
        } else {
            self.thinStrokes = Defaults.thinStrokes
        }

        // Detection reads tmux config files from disk. Defer to a detached task
        // so app launch isn't blocked by synchronous I/O; the property updates
        // asynchronously on the main actor once detection finishes.
        self.hasTmuxStyleOverrides = false
        Task { @MainActor [weak self] in
            let detected = await Task.detached {
                AppearanceSettings.detectTmuxStyleOverrides()
            }.value
            self?.hasTmuxStyleOverrides = detected
        }
    }

    /// Greps the user's tmux config files for any of the cell-painting style
    /// options that would override TBD's color scheme. Best-effort: misses
    /// configs loaded via `source-file` or `if-shell`, but catches the common
    /// case of a directly-set `window-style` etc.
    ///
    /// `nonisolated` because it reads files and has no actor-isolated state —
    /// safe to call from a detached task.
    nonisolated private static func detectTmuxStyleOverrides() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = ["\(home)/.tmux.conf", "\(home)/.config/tmux/tmux.conf"]
        let pattern = #"^\s*(set|setw)\b(\s+-[a-zA-Z]+)*\s+(window-style|window-active-style|pane-style|default-style)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return false
        }
        for path in candidatePaths {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let range = NSRange(contents.startIndex..., in: contents)
            if regex.firstMatch(in: contents, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Resolves `fontName` + `fontSize` to an `NSFont`. Falls back to system
    /// mono if the named font isn't installed.
    var font: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}

// MARK: - CursorStyle <-> String

extension CursorStyle {
    /// Stable string keys for UserDefaults round-tripping. Don't rename
    /// without writing a migration — stored in user prefs.
    var rawString: String {
        switch self {
        case .blinkBlock: return "blink-block"
        case .steadyBlock: return "steady-block"
        case .blinkUnderline: return "blink-underline"
        case .steadyUnderline: return "steady-underline"
        case .blinkBar: return "blink-bar"
        case .steadyBar: return "steady-bar"
        @unknown default: return "blink-block"
        }
    }

    static func from(rawString: String) -> CursorStyle? {
        switch rawString {
        case "blink-block": return .blinkBlock
        case "steady-block": return .steadyBlock
        case "blink-underline": return .blinkUnderline
        case "steady-underline": return .steadyUnderline
        case "blink-bar": return .blinkBar
        case "steady-bar": return .steadyBar
        default: return nil
        }
    }
}
