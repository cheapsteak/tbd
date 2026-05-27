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
}
