import Foundation
import Testing
@testable import TBDApp

@Suite("UserTerminalTheme")
struct UserTerminalThemeTests {
    @Test("decodes a canonical JSON file")
    func decodeCanonical() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "my-gruvbox",
          "displayName": "My Gruvbox",
          "ansi": [
            "#282828","#cc241d","#98971a","#d79921",
            "#458588","#b16286","#689d6a","#a89984",
            "#928374","#fb4934","#b8bb26","#fabd2f",
            "#83a598","#d3869b","#8ec07c","#ebdbb2"
          ],
          "foreground": "#ebdbb2",
          "background": "#282828",
          "cursor": "#ebdbb2",
          "selection": "#3c3836"
        }
        """.data(using: .utf8)!
        let theme = try JSONDecoder().decode(UserTerminalTheme.self, from: json)
        #expect(theme.id == "my-gruvbox")
        #expect(theme.displayName == "My Gruvbox")
        #expect(theme.ansi.count == 16)
        #expect(theme.ansi[0] == "#282828")
        #expect(theme.background == "#282828")
    }

    @Test("round-trips through encode/decode")
    func roundTrip() throws {
        let theme = UserTerminalTheme(
            schemaVersion: 1,
            id: "x", displayName: "X",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(UserTerminalTheme.self, from: data)
        #expect(decoded == theme)
    }

    @Test("rejects wrong-length ansi array on validation")
    func validatesAnsiLength() {
        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "x", displayName: "X",
            ansi: Array(repeating: "#000000", count: 15),
            foreground: "#fff", background: "#000",
            cursor: "#fff", selection: "#505050"
        )
        #expect(throws: UserTerminalTheme.ValidationError.self) {
            try theme.validated()
        }
    }

    @Test("rejects invalid hex on validation")
    func validatesHex() {
        var ansi = Array(repeating: "#000000", count: 16)
        ansi[3] = "red"
        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "x", displayName: "X", ansi: ansi,
            foreground: "#fff", background: "#000",
            cursor: "#fff", selection: "#505050"
        )
        #expect(throws: UserTerminalTheme.ValidationError.self) {
            try theme.validated()
        }
    }

    @Test("rejects invalid id patterns on validation")
    func validatesID() {
        let cases = ["MY-THEME", "my theme", "my_theme", "", "ünicode"]
        for badID in cases {
            let theme = UserTerminalTheme(
                schemaVersion: 1, id: badID, displayName: "X",
                ansi: Array(repeating: "#000000", count: 16),
                foreground: "#ffffff", background: "#000000",
                cursor: "#ffffff", selection: "#505050"
            )
            #expect(throws: UserTerminalTheme.ValidationError.self) {
                try theme.validated()
            }
        }
    }

    @Test("rejects unsupported schemaVersion on validation")
    func rejectsFutureSchemaVersion() {
        let theme = UserTerminalTheme(
            schemaVersion: 99,
            id: "x", displayName: "X",
            ansi: Array(repeating: "#000000", count: 16),
            foreground: "#ffffff", background: "#000000",
            cursor: "#ffffff", selection: "#505050"
        )
        do {
            _ = try theme.validated()
            Issue.record("expected unsupportedSchemaVersion error")
        } catch UserTerminalTheme.ValidationError.unsupportedSchemaVersion(let v) {
            #expect(v == 99)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("converts to a TerminalColorScheme with matching RGB")
    func convertsToScheme() throws {
        let theme = UserTerminalTheme(
            schemaVersion: 1, id: "x", displayName: "X",
            ansi: Array(repeating: "#101010", count: 16),
            foreground: "#abcdef", background: "#202020",
            cursor: "#ffffff", selection: "#505050"
        )
        let scheme = try theme.toScheme()
        #expect(scheme.id == "x")
        #expect(scheme.displayName == "X")
        #expect(scheme.ansi.count == 16)
        #expect(scheme.foreground.red == 171 * 257)
        #expect(scheme.foreground.green == 205 * 257)
        #expect(scheme.foreground.blue == 239 * 257)
    }
}
