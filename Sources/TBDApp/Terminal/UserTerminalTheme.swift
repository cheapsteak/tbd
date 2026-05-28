import Foundation
import SwiftTerm

/// Codable representation of a user-authored terminal color scheme as stored
/// on disk in `~/tbd/terminal-themes/<id>.json`. Converts to a runtime
/// `TerminalColorScheme` for the renderer. See the user-custom-terminal-themes
/// design doc.
struct UserTerminalTheme: Codable, Equatable, Hashable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let ansi: [String]
    let foreground: String
    let background: String
    let cursor: String
    let selection: String

    enum ValidationError: Error, Equatable {
        case wrongAnsiCount(Int)
        case invalidHex(field: String, value: String)
        case invalidID(String)
        case unsupportedSchemaVersion(Int)
    }

    func validated() throws -> UserTerminalTheme {
        guard schemaVersion == 1 else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard ansi.count == 16 else { throw ValidationError.wrongAnsiCount(ansi.count) }
        for (i, hex) in ansi.enumerated() {
            guard Self.parseHex(hex) != nil else {
                throw ValidationError.invalidHex(field: "ansi[\(i)]", value: hex)
            }
        }
        for (name, hex) in [
            ("foreground", foreground), ("background", background),
            ("cursor", cursor), ("selection", selection)
        ] {
            guard Self.parseHex(hex) != nil else {
                throw ValidationError.invalidHex(field: name, value: hex)
            }
        }
        guard !id.isEmpty, id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            throw ValidationError.invalidID(id)
        }
        return self
    }

    func toScheme() throws -> TerminalColorScheme {
        _ = try validated()
        return TerminalColorScheme(
            id: id,
            displayName: displayName,
            ansi: ansi.map { Self.color(fromHex: $0)! },
            foreground: Self.color(fromHex: foreground)!,
            background: Self.color(fromHex: background)!,
            cursor: Self.color(fromHex: cursor)!,
            selection: Self.color(fromHex: selection)!
        )
    }

    static func parseHex(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        let scanner = Scanner(string: String(hex.dropFirst()))
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value), scanner.isAtEnd else { return nil }
        return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }

    static func color(fromHex hex: String) -> SwiftTerm.Color? {
        guard let (r, g, b) = parseHex(hex) else { return nil }
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    static func hex(from color: SwiftTerm.Color) -> String {
        let r = Int(color.red / 257)
        let g = Int(color.green / 257)
        let b = Int(color.blue / 257)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
