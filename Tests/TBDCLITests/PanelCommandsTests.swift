import Foundation
import Testing
import ArgumentParser
import TBDShared

@testable import TBDCLI

@Suite("tbd panel content resolution")
struct PanelContentResolutionTests {
    @Test func fileDefaultsToAutomaticPresentation() throws {
        let opts = try ContentOptions.parse(["--file", "/tmp/a.txt"])
        let content = try resolvePanelContent(opts)
        guard case .file(let ref) = content else { Issue.record("expected .file"); return }
        #expect(ref.path == "/tmp/a.txt")
        #expect(ref.presentation == .automatic)
    }

    @Test func fileRenderFlagForcesRenderedPresentation() throws {
        let opts = try ContentOptions.parse(["--file", "/tmp/a.md", "--render"])
        let content = try resolvePanelContent(opts)
        guard case .file(let ref) = content else { Issue.record("expected .file"); return }
        #expect(ref.presentation == .rendered)
    }

    @Test func fileSourceFlagForcesSourcePresentation() throws {
        let opts = try ContentOptions.parse(["--file", "/tmp/a.md", "--source"])
        let content = try resolvePanelContent(opts)
        guard case .file(let ref) = content else { Issue.record("expected .file"); return }
        #expect(ref.presentation == .source)
    }

    @Test func fileRenderAndSourceTogetherIsInvalid() throws {
        let opts = try ContentOptions.parse(["--file", "/tmp/a.md", "--render", "--source"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelContent(opts)
        }
    }

    @Test func webResolvesToURL() throws {
        let opts = try ContentOptions.parse(["--web", "https://example.com"])
        let content = try resolvePanelContent(opts)
        guard case .web(let url) = content else { Issue.record("expected .web"); return }
        #expect(url.absoluteString == "https://example.com")
    }

    @Test func transcriptResolvesToTerminalID() throws {
        let id = UUID()
        let opts = try ContentOptions.parse(["--transcript", id.uuidString])
        let content = try resolvePanelContent(opts)
        guard case .transcript(let terminalID) = content else { Issue.record("expected .transcript"); return }
        #expect(terminalID == id)
    }

    @Test func transcriptRejectsInvalidUUID() throws {
        let opts = try ContentOptions.parse(["--transcript", "not-a-uuid"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelContent(opts)
        }
    }

    @Test func noteResolvesToNoteID() throws {
        let id = UUID()
        let opts = try ContentOptions.parse(["--note", id.uuidString])
        let content = try resolvePanelContent(opts)
        guard case .note(let noteID) = content else { Issue.record("expected .note"); return }
        #expect(noteID == id)
    }

    @Test func noContentSourceIsInvalid() throws {
        let opts = try ContentOptions.parse([])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelContent(opts)
        }
    }

    @Test func multipleContentSourcesIsInvalid() throws {
        let opts = try ContentOptions.parse(["--file", "/tmp/a.txt", "--web", "https://example.com"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelContent(opts)
        }
    }
}

@Suite("tbd panel placement resolution")
struct PanelPlacementResolutionTests {
    @Test func noFlagsDefaultToAutomatic() throws {
        let opts = try PlacementOptions.parse([])
        #expect(try resolvePanelPlacement(opts) == .automatic)
    }

    @Test func replaceResolvesToReplacePlacement() throws {
        let id = UUID()
        let opts = try PlacementOptions.parse(["--replace", id.uuidString])
        #expect(try resolvePanelPlacement(opts) == .replace(panelID: id))
    }

    @Test func replaceRejectsInvalidUUID() throws {
        let opts = try PlacementOptions.parse(["--replace", "nope"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelPlacement(opts)
        }
    }

    @Test func replaceWithEdgeIsInvalid() throws {
        let opts = try PlacementOptions.parse(["--replace", UUID().uuidString, "--edge", "left"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelPlacement(opts)
        }
    }

    @Test func besidePrimaryWithEdgeResolves() throws {
        let opts = try PlacementOptions.parse(["--beside", "primary", "--edge", "right"])
        #expect(try resolvePanelPlacement(opts) == .beside(target: .primary, edge: .right, share: nil))
    }

    @Test func besidePanelIDWithEdgeAndShareResolves() throws {
        let id = UUID()
        let opts = try PlacementOptions.parse(["--beside", id.uuidString, "--edge", "below", "--share", "0.3"])
        #expect(try resolvePanelPlacement(opts) == .beside(target: .panel(id), edge: .below, share: 0.3))
    }

    @Test func besideWithoutEdgeIsInvalid() throws {
        let opts = try PlacementOptions.parse(["--beside", "primary"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelPlacement(opts)
        }
    }

    @Test func edgeWithoutBesideOrReplaceIsInvalid() throws {
        let opts = try PlacementOptions.parse(["--edge", "left"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelPlacement(opts)
        }
    }

    @Test func replaceAndBesideTogetherIsInvalid() throws {
        let opts = try PlacementOptions.parse([
            "--replace", UUID().uuidString, "--beside", "primary", "--edge", "left",
        ])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelPlacement(opts)
        }
    }

    @Test func shareOutOfRangeIsInvalid() throws {
        let opts = try PlacementOptions.parse(["--beside", "primary", "--edge", "left", "--share", "1.5"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelPlacement(opts)
        }
    }
}

@Suite("tbd panel --ratios parsing")
struct PanelRatiosParsingTests {
    @Test func parsesTwoValues() throws {
        #expect(try parseRatios("0.5,0.5") == [0.5, 0.5])
    }

    @Test func trimsWhitespaceAroundValues() throws {
        #expect(try parseRatios("0.3, 0.7") == [0.3, 0.7])
    }

    @Test func parsesThreeValues() throws {
        #expect(try parseRatios("0.2,0.3,0.5") == [0.2, 0.3, 0.5])
    }

    @Test func emptyStringIsInvalid() {
        #expect(throws: CLIError.self) {
            _ = try parseRatios("")
        }
    }

    @Test func trailingCommaIsInvalid() {
        #expect(throws: CLIError.self) {
            _ = try parseRatios("0.5,")
        }
    }

    @Test func nonNumericEntryIsInvalid() {
        #expect(throws: CLIError.self) {
            _ = try parseRatios("0.5,abc")
        }
    }
}

@Suite("tbd panel layout tree rendering")
struct PanelTreeRenderingTests {
    @Test func rendersPanelIDsSplitIDsAndRatiosAndPrimaryMarker() {
        let terminalID = UUID()
        let filePanelID = UUID()
        let webPanelID = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let worktreeID = UUID()

        let tab = WorkspaceTabSurface(
            id: tabID,
            worktreeID: worktreeID,
            label: "My Tab",
            primary: .terminal(terminalID: terminalID),
            layout: .split(SplitNode(
                id: splitID,
                direction: .horizontal,
                children: [
                    .primary,
                    .panel(PanelSlot(id: filePanelID, content: .file(FileReference(path: "/a.swift")))),
                    .panel(PanelSlot(id: webPanelID, content: .web(URL(string: "https://example.com")!))),
                ],
                ratios: [0.5, 0.25, 0.25]
            )),
            revision: 7
        )

        let lines = tabLines(tab, activeTabID: tabID)
        let joined = lines.joined(separator: "\n")

        #expect(lines.first == "Tab \(tabID) [ACTIVE] — My Tab")
        #expect(joined.contains("revision: 7"))
        #expect(joined.contains("primary: terminal \(terminalID)"))
        #expect(joined.contains("split \(splitID) (horizontal, ratios: 0.50,0.25,0.25)"))
        #expect(joined.contains("[primary]"))
        #expect(joined.contains("panel \(filePanelID): file /a.swift"))
        #expect(joined.contains("panel \(webPanelID): web https://example.com"))
    }

    @Test func inactiveTabHasNoActiveMarker() {
        let tabID = UUID()
        let tab = WorkspaceTabSurface(
            id: tabID, worktreeID: UUID(), label: nil,
            primary: .terminal(terminalID: UUID()), layout: .primary, revision: 0)
        let lines = tabLines(tab, activeTabID: UUID())
        #expect(lines.first == "Tab \(tabID)")
        #expect(!lines.first!.contains("ACTIVE"))
    }

    @Test func filePresentationShownWhenNonAutomatic() {
        let content = PanelContent.file(FileReference(path: "/a.md", presentation: .rendered))
        #expect(describe(content) == "file /a.md (rendered)")
    }
}
