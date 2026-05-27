import Foundation
import TOMLKit

struct AlacrittyImporter {

    enum ImportError: Error, Equatable {
        case fileUnreadable(String)
        case tomlParseFailed(String)
        case missingSection(String)
        case missingKey(section: String, key: String)
        case invalidHex(section: String, key: String, value: String)
    }

    func importFile(_ url: URL) throws -> UserTerminalTheme {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ImportError.fileUnreadable(String(describing: error))
        }
        return try importString(raw, suggestedDisplayName: url.deletingPathExtension().lastPathComponent)
    }

    func importString(_ raw: String, suggestedDisplayName: String) throws -> UserTerminalTheme {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: raw)
        } catch {
            throw ImportError.tomlParseFailed(String(describing: error))
        }

        let colors = try requireTable(table, path: ["colors"])
        let primary = try requireSubtable(colors, name: "primary", path: "colors.primary")
        let normal = try requireSubtable(colors, name: "normal", path: "colors.normal")
        // Some real-world Alacritty themes omit [colors.bright] and rely on the
        // terminal emulator to derive bright variants from normal. Match that
        // behavior: when bright is absent, copy normal into the bright half of
        // the ANSI array.
        let bright: TOMLTable = colors["bright"]?.table ?? normal

        let foreground = try requireHex(primary, key: "foreground", section: "colors.primary")
        let background = try requireHex(primary, key: "background", section: "colors.primary")

        let cursorTable = colors["cursor"]?.table
        let cursor = (try? requireHex(cursorTable, key: "cursor", section: "colors.cursor"))
            ?? (try? requireHex(cursorTable, key: "text", section: "colors.cursor"))
            ?? foreground

        let selectionTable = colors["selection"]?.table
        let selection = (try? requireHex(selectionTable, key: "background", section: "colors.selection"))
            ?? "#505050"

        let normalKeys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        let ansi = try (normalKeys.map { try requireHex(normal, key: $0, section: "colors.normal") }
                       + normalKeys.map { try requireHex(bright, key: $0, section: "colors.bright") })

        return UserTerminalTheme(
            schemaVersion: 1,
            id: "",
            displayName: suggestedDisplayName,
            ansi: ansi,
            foreground: foreground,
            background: background,
            cursor: cursor,
            selection: selection
        )
    }

    private func requireTable(_ table: TOMLTable, path: [String]) throws -> TOMLTable {
        var cur = table
        for segment in path {
            guard let next = cur[segment]?.table else {
                throw ImportError.missingSection(path.joined(separator: "."))
            }
            cur = next
        }
        return cur
    }

    private func requireSubtable(_ parent: TOMLTable, name: String, path: String) throws -> TOMLTable {
        guard let t = parent[name]?.table else { throw ImportError.missingSection(path) }
        return t
    }

    private func requireHex(_ table: TOMLTable?, key: String, section: String) throws -> String {
        guard let table else { throw ImportError.missingSection(section) }
        guard let raw = table[key]?.string else {
            throw ImportError.missingKey(section: section, key: key)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped: String
        if trimmed.hasPrefix("0x") {
            stripped = String(trimmed.dropFirst(2))
        } else {
            stripped = trimmed
        }
        let withHash = stripped.hasPrefix("#") ? stripped : "#" + stripped
        guard UserTerminalTheme.parseHex(withHash) != nil else {
            throw ImportError.invalidHex(section: section, key: key, value: raw)
        }
        return withHash
    }
}
