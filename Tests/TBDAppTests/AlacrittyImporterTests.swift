import Foundation
import Testing
@testable import TBDApp

@Suite("AlacrittyImporter")
struct AlacrittyImporterTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures/alacritty") else {
            Issue.record("missing fixture \(name).toml")
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    @Test("catppuccin-latte fixture decodes to expected hex tuple")
    func catppuccinLatte() throws {
        let url = try fixtureURL("catppuccin-latte")
        let theme = try AlacrittyImporter().importFile(url)
        #expect(theme.background == "#eff1f5")
        #expect(theme.foreground == "#4c4f69")
        #expect(theme.ansi.count == 16)
        // ansi[0] = normal black
        #expect(theme.ansi[0] == "#bcc0cc")
        // ansi[4] = normal blue
        #expect(theme.ansi[4] == "#1e66f5")
    }

    @Test("rose-pine-dawn fixture decodes with bright == normal where the source has it")
    func rosePineDawn() throws {
        let url = try fixtureURL("rose-pine-dawn")
        let theme = try AlacrittyImporter().importFile(url)
        #expect(theme.background == "#faf4ed")
        // normal red (ansi[1]) == bright red (ansi[9]) in this theme
        #expect(theme.ansi[1] == theme.ansi[9])
        // ansi[8] = bright black
        #expect(theme.ansi[8] == "#9893a5")
    }

    @Test("tokyonight-day fixture decodes")
    func tokyonightDay() throws {
        let url = try fixtureURL("tokyonight-day")
        let theme = try AlacrittyImporter().importFile(url)
        #expect(theme.background == "#e1e2e7")
        #expect(theme.ansi.count == 16)
    }

    @Test("missing [colors.normal] throws missingSection with the section name in the error")
    func missingNormalSection() throws {
        let url = try fixtureURL("malformed-no-normal")
        do {
            _ = try AlacrittyImporter().importFile(url)
            Issue.record("expected import to throw")
        } catch let AlacrittyImporter.ImportError.missingSection(section) {
            #expect(section == "colors.normal")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("interior 0x substring in a hex value is NOT stripped")
    func interior0xNotStripped() throws {
        // "#a0xbcdef" is 9 chars — invalid hex regardless. The fix means the
        // importer no longer collapses it to a valid-looking "#abcdef".
        let toml = """
        [colors.primary]
        background = "#ffffff"
        foreground = "#a0xbcdef"
        [colors.normal]
        black = "#000000"
        red = "#ff0000"
        green = "#00ff00"
        yellow = "#ffff00"
        blue = "#0000ff"
        magenta = "#ff00ff"
        cyan = "#00ffff"
        white = "#cccccc"
        [colors.bright]
        black = "#666666"
        red = "#ff6666"
        green = "#66ff66"
        yellow = "#ffff66"
        blue = "#6666ff"
        magenta = "#ff66ff"
        cyan = "#66ffff"
        white = "#ffffff"
        """
        do {
            _ = try AlacrittyImporter().importString(toml, suggestedDisplayName: "x")
            Issue.record("expected importString to throw on invalid hex")
        } catch AlacrittyImporter.ImportError.invalidHex(_, let key, _) {
            #expect(key == "foreground")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("leading 0x prefix is still stripped correctly")
    func leading0xStripped() throws {
        let toml = """
        [colors.primary]
        background = "0xffffff"
        foreground = "0x000000"
        [colors.normal]
        black = "#000000"
        red = "#ff0000"
        green = "#00ff00"
        yellow = "#ffff00"
        blue = "#0000ff"
        magenta = "#ff00ff"
        cyan = "#00ffff"
        white = "#cccccc"
        [colors.bright]
        black = "#666666"
        red = "#ff6666"
        green = "#66ff66"
        yellow = "#ffff66"
        blue = "#6666ff"
        magenta = "#ff66ff"
        cyan = "#66ffff"
        white = "#ffffff"
        """
        let theme = try AlacrittyImporter().importString(toml, suggestedDisplayName: "x")
        #expect(theme.background == "#ffffff")
        #expect(theme.foreground == "#000000")
    }

    @Test("missing [colors.bright] falls back to [colors.normal] values")
    func missingBrightFallsBackToNormal() throws {
        let toml = """
        [colors.primary]
        background = "#000000"
        foreground = "#ffffff"
        [colors.normal]
        black = "#111111"
        red = "#220000"
        green = "#002200"
        yellow = "#222200"
        blue = "#000022"
        magenta = "#220022"
        cyan = "#002222"
        white = "#222222"
        # No [colors.bright] section.
        """
        let theme = try AlacrittyImporter().importString(toml, suggestedDisplayName: "no-bright")
        // Normal and bright slots should be identical.
        for i in 0..<8 {
            #expect(theme.ansi[i] == theme.ansi[i + 8])
        }
        #expect(theme.ansi[0] == "#111111")
        #expect(theme.ansi[8] == "#111111")
    }
}
