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
        static let schemeID = ColorSchemes.defaultScheme.id
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
    /// effort detection at init — see `TmuxConfigStyleDetector`.
    @Published private(set) var hasTmuxStyleOverrides: Bool

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
                TmuxConfigStyleDetector.detectFromUserConfig()
            }.value
            self?.hasTmuxStyleOverrides = detected
        }
    }

    /// Resolves `fontName` + `fontSize` to an `NSFont`. Falls back to system
    /// mono if the named font isn't installed.
    var font: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Computes the COLORFGBG environment variable value based on a color scheme's
    /// background luminance. Returns "0;15" (black fg, white bg) for light backgrounds
    /// (luminance > 0.5), or "15;0" (white fg, black bg) for dark backgrounds.
    /// Uses an approximate luminance — the WCAG coefficients applied to raw sRGB values,
    /// skipping the gamma-linearization step. Sufficient for a binary light/dark
    /// threshold on near-black / near-white terminal backgrounds; do not use this
    /// helper as a general-purpose accessibility-contrast check.
    nonisolated static func colorFgBg(for scheme: TerminalColorScheme) -> String {
        // Convert SwiftTerm.Color channels (0–65535 scale) to 0–1 range.
        // Bundled scheme values are sRGB hex codes; use sRGB so wide-gamut
        // displays (Display P3) don't drift from the spec.
        let red = CGFloat(scheme.background.red) / 65535.0
        let green = CGFloat(scheme.background.green) / 65535.0
        let blue = CGFloat(scheme.background.blue) / 65535.0

        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        // Light background (luminance > 0.5) → use black foreground, white background hint
        // Dark background (luminance ≤ 0.5) → use white foreground, black background hint
        return luminance > 0.5 ? "0;15" : "15;0"
    }

    /// Computes COLORFGBG for the currently active terminal color scheme.
    var currentColorFgBg: String {
        let scheme = ColorSchemes.scheme(forID: schemeID)
        return Self.colorFgBg(for: scheme)
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
