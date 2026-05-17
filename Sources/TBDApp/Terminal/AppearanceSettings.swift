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
    }

    @MainActor
    enum Defaults {
        static let fontName = "Monaco"
        static let fontSize: CGFloat = 12.0
        static let schemeID = "tango"
        static let cursorStyle: CursorStyle = .blinkBlock
    }

    private let defaults: UserDefaults

    @Published var fontName: String { didSet { defaults.set(fontName, forKey: Keys.fontName) } }
    @Published var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: Keys.fontSize) } }
    @Published var schemeID: String { didSet { defaults.set(schemeID, forKey: Keys.schemeID) } }
    @Published var cursorStyle: CursorStyle { didSet { defaults.set(cursorStyle.rawString, forKey: Keys.cursorStyle) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Font name — accept any non-empty string; resolution happens in `font`.
        let storedName = defaults.string(forKey: Keys.fontName)
        self.fontName = (storedName?.isEmpty == false) ? storedName! : Defaults.fontName

        // Font size — must be > 0 to be valid.
        let storedSize = defaults.double(forKey: Keys.fontSize)
        self.fontSize = storedSize > 0 ? CGFloat(storedSize) : Defaults.fontSize

        // Scheme ID — accept any string (lookup itself falls back if unknown).
        self.schemeID = defaults.string(forKey: Keys.schemeID) ?? Defaults.schemeID

        // Cursor — round-trip via rawString; fall back on unknown.
        let storedCursor = defaults.string(forKey: Keys.cursorStyle) ?? ""
        self.cursorStyle = CursorStyle.from(rawString: storedCursor) ?? Defaults.cursorStyle
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
