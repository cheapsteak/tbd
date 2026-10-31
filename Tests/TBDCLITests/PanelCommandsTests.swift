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

    @Test func renderFlagOnNonFileContentIsInvalid() throws {
        let opts = try ContentOptions.parse(["--web", "https://example.com", "--render"])
        #expect(throws: CLIError.self) {
            _ = try resolvePanelContent(opts)
        }
    }
}

@Suite("tbd panel subcommands")
struct PanelSubcommandTests {
    @Test func subcommandsAreTheSideRegionVerbs() {
        let names = PanelCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names == [
            "list", "open", "navigate", "close", "select", "back", "forward", "jump",
            "collapse", "expand", "resize",
        ])
    }

    @Test func moveAndSelectTabAreGone() {
        let names = PanelCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(!names.contains("move"))
        #expect(!names.contains("select-tab"))
    }
}

@Suite("tbd panel argument parsing")
struct PanelArgumentParsingTests {
    @Test func openTakesNewPanelFlag() throws {
        let command = try PanelOpen.parse(["wt", "--file", "a.md", "--new-panel"])
        #expect(command.worktree == "wt")
        #expect(command.newPanel)
        #expect(command.tab == nil)
    }

    @Test func openDefaultsToReusingAPanel() throws {
        let command = try PanelOpen.parse(["wt", "--file", "a.md"])
        #expect(!command.newPanel)
    }

    @Test func tabIsOptionalOnEveryMutatingCommand() throws {
        let panel = UUID().uuidString
        #expect(try PanelOpen.parse(["wt", "--file", "a.md"]).tab == nil)
        #expect(try PanelNavigate.parse(["wt", "--panel", panel, "--file", "a.md"]).tab == nil)
        #expect(try PanelClose.parse(["wt", "--panel", panel]).tab == nil)
        #expect(try PanelSelect.parse(["wt", "--panel", panel]).tab == nil)
        #expect(try PanelBack.parse(["wt", "--panel", panel]).tab == nil)
        #expect(try PanelForward.parse(["wt", "--panel", panel]).tab == nil)
        #expect(try PanelJump.parse(["wt", "--panel", panel, "--index", "1"]).tab == nil)
        #expect(try PanelCollapse.parse(["wt"]).tab == nil)
        #expect(try PanelExpand.parse(["wt"]).tab == nil)
        #expect(try PanelResize.parse(["wt", "--width", "0.4"]).tab == nil)
    }

    @Test func tabIsAcceptedOnEveryMutatingCommand() throws {
        let panel = UUID().uuidString
        let tab = UUID().uuidString
        #expect(try PanelOpen.parse(["wt", "--file", "a.md", "--tab", tab]).tab == tab)
        #expect(try PanelNavigate.parse(["wt", "--panel", panel, "--file", "a.md", "--tab", tab]).tab == tab)
        #expect(try PanelClose.parse(["wt", "--panel", panel, "--tab", tab]).tab == tab)
        #expect(try PanelSelect.parse(["wt", "--panel", panel, "--tab", tab]).tab == tab)
        #expect(try PanelBack.parse(["wt", "--panel", panel, "--tab", tab]).tab == tab)
        #expect(try PanelForward.parse(["wt", "--panel", panel, "--tab", tab]).tab == tab)
        #expect(try PanelJump.parse(["wt", "--panel", panel, "--index", "1", "--tab", tab]).tab == tab)
        #expect(try PanelCollapse.parse(["wt", "--tab", tab]).tab == tab)
        #expect(try PanelExpand.parse(["wt", "--tab", tab]).tab == tab)
        #expect(try PanelResize.parse(["wt", "--width", "0.4", "--tab", tab]).tab == tab)
    }

    @Test func listTakesAnOptionalTab() throws {
        #expect(try PanelList.parse(["wt"]).tab == nil)
        let tab = UUID().uuidString
        #expect(try PanelList.parse(["wt", "--tab", tab]).tab == tab)
    }

    @Test func resizeTakesAWidth() throws {
        let command = try PanelResize.parse(["wt", "--width", "0.4"])
        #expect(command.width == 0.4)
    }

    @Test func resizeRequiresAWidth() {
        #expect(throws: (any Error).self) {
            _ = try PanelResize.parse(["wt"])
        }
    }

    @Test func removedPlacementOptionsAreRejected() {
        #expect(throws: (any Error).self) {
            _ = try PanelOpen.parse(["wt", "--file", "a", "--beside", "primary"])
        }
        #expect(throws: (any Error).self) {
            _ = try PanelOpen.parse(["wt", "--file", "a", "--replace", UUID().uuidString])
        }
        #expect(throws: (any Error).self) {
            _ = try PanelOpen.parse(["wt", "--file", "a", "--edge", "left"])
        }
    }

    @Test func removedSplitResizeOptionsAreRejected() {
        #expect(throws: (any Error).self) {
            _ = try PanelResize.parse(["wt", "--split", "x", "--ratios", "0.5,0.5"])
        }
        #expect(throws: (any Error).self) {
            _ = try PanelResize.parse(["wt", "--width", "0.4", "--ratios", "0.5,0.5"])
        }
    }
}

@Suite("tbd panel operations")
struct PanelOperationMappingTests {
    @Test func openSendsOpenWithoutNewPanelByDefault() throws {
        let command = try PanelOpen.parse(["wt", "--file", "/tmp/a.md"])
        #expect(try command.operation() == .open(
            content: .file(FileReference(path: "/tmp/a.md")), newPanel: false))
    }

    @Test func openWithNewPanelSendsNewPanelTrue() throws {
        let command = try PanelOpen.parse(["wt", "--web", "https://example.com", "--new-panel"])
        let url = try #require(URL(string: "https://example.com"))
        #expect(try command.operation() == .open(content: .web(url), newPanel: true))
    }

    @Test func navigateSendsNavigate() throws {
        let panelID = UUID()
        let command = try PanelNavigate.parse(["wt", "--panel", panelID.uuidString, "--file", "/tmp/b.md"])
        #expect(try command.operation() == .navigate(
            panelID: panelID, destination: .file(FileReference(path: "/tmp/b.md"))))
    }

    @Test func closeSendsClose() throws {
        let panelID = UUID()
        let command = try PanelClose.parse(["wt", "--panel", panelID.uuidString])
        #expect(try command.operation() == .close(panelID: panelID))
    }

    @Test func selectSendsSelect() throws {
        let panelID = UUID()
        let command = try PanelSelect.parse(["wt", "--panel", panelID.uuidString])
        #expect(try command.operation() == .select(panelID: panelID))
    }

    @Test func historyVerbsSendHistoryActions() throws {
        let panelID = UUID()
        let back = try PanelBack.parse(["wt", "--panel", panelID.uuidString])
        let forward = try PanelForward.parse(["wt", "--panel", panelID.uuidString])
        let jump = try PanelJump.parse(["wt", "--panel", panelID.uuidString, "--index", "2"])
        #expect(try back.operation() == .history(panelID: panelID, action: .back))
        #expect(try forward.operation() == .history(panelID: panelID, action: .forward))
        #expect(try jump.operation() == .history(panelID: panelID, action: .jump(index: 2)))
    }

    @Test func collapseSendsSetCollapsedTrue() throws {
        #expect(try PanelCollapse.parse(["wt"]).operation() == .setCollapsed(true))
    }

    @Test func expandSendsSetCollapsedFalse() throws {
        #expect(try PanelExpand.parse(["wt"]).operation() == .setCollapsed(false))
    }

    @Test func resizeSendsTheWidthAsGiven() throws {
        #expect(try PanelResize.parse(["wt", "--width", "0.4"]).operation() == .resize(width: 0.4))
    }

    /// The daemon owns the range check and answers with a typed error; the
    /// CLI passes an out-of-range width through rather than pre-validating.
    @Test func resizePassesAnOutOfRangeWidthThrough() throws {
        #expect(try PanelResize.parse(["wt", "--width", "1.5"]).operation() == .resize(width: 1.5))
    }

    @Test func invalidPanelIDIsRejected() throws {
        let command = try PanelClose.parse(["wt", "--panel", "not-a-uuid"])
        #expect(throws: CLIError.self) {
            _ = try command.operation()
        }
    }
}

/// `resolvePanelTarget`: an Arrange verb makes one `panel.get`, scoped to
/// `--tab` when given and unscoped otherwise, and reads the envelope's
/// `baseRevision` from that same reply.
@Suite("tbd panel tab resolution")
struct PanelTabResolutionTests {
    private func surface(_ tabID: UUID, revision: UInt64) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: tabID, worktreeID: UUID(), primary: .terminal(terminalID: UUID()), revision: revision)
    }

    @Test func givenTabMakesOneGetScopedToThatTab() throws {
        let tabID = UUID()
        var asked: [UUID?] = []
        let target = try resolvePanelTarget(tab: tabID.uuidString) { scoped in
            asked.append(scoped)
            return PanelGetResult(tabs: [surface(tabID, revision: 3)], activeTabID: nil)
        }
        let expected: [UUID?] = [tabID]
        #expect(asked == expected)
        #expect(target.tabID == tabID)
        let envelope = panelEnvelope(
            worktreeID: UUID(), tabID: target.tabID, current: target.current, operation: .setCollapsed(true))
        #expect(envelope.baseRevision == 3)
    }

    @Test func invalidGivenTabIsRejectedBeforeAnyGet() {
        var asked = 0
        do {
            _ = try resolvePanelTarget(tab: "not-a-uuid") { _ in
                asked += 1
                return PanelGetResult(tabs: [], activeTabID: nil)
            }
            Issue.record("expected resolvePanelTarget to throw")
        } catch {
            #expect(error is CLIError, "expected CLIError, got \(error)")
        }
        #expect(asked == 0)
    }

    /// Without `--tab` the unscoped get both names the active tab and carries
    /// its surface, so no second, tab-scoped get is needed for the revision.
    @Test func missingTabMakesOneUnscopedGetAndTakesTheRevisionFromIt() throws {
        let activeTabID = UUID()
        let otherTabID = UUID()
        var asked: [UUID?] = []
        let target = try resolvePanelTarget(tab: nil) { scoped in
            asked.append(scoped)
            return PanelGetResult(
                tabs: [surface(otherTabID, revision: 9), surface(activeTabID, revision: 4)],
                activeTabID: activeTabID)
        }
        let expected: [UUID?] = [nil]
        #expect(asked == expected, "one unscoped get, and no tab-scoped one")
        #expect(target.tabID == activeTabID)
        let envelope = panelEnvelope(
            worktreeID: UUID(), tabID: target.tabID, current: target.current, operation: .setCollapsed(true))
        #expect(envelope.baseRevision == 4, "the active tab's revision, not another tab's")
    }

    /// With the side panel off, or an active tab the daemon has no surface
    /// for, the apply still goes out without a base revision, and the daemon's
    /// refusal names the real reason.
    @Test func activeTabWithoutASurfaceStillSendsWithoutABaseRevision() throws {
        let activeTabID = UUID()
        let target = try resolvePanelTarget(tab: nil) { _ in
            PanelGetResult(tabs: [surface(UUID(), revision: 2)], activeTabID: activeTabID)
        }
        #expect(target.tabID == activeTabID)
        let envelope = panelEnvelope(
            worktreeID: UUID(), tabID: target.tabID, current: target.current, operation: .resize(width: 0.4))
        #expect(envelope.tabID == activeTabID)
        #expect(envelope.baseRevision == nil)
    }

    @Test func missingTabWithNoActiveTabAsksForTab() {
        var asked = 0
        do {
            _ = try resolvePanelTarget(tab: nil) { _ in
                asked += 1
                return PanelGetResult(tabs: [], activeTabID: nil)
            }
            Issue.record("expected resolvePanelTarget to throw")
        } catch let error as CLIError {
            #expect("\(error)" == "no active tab; pass --tab")
        } catch {
            Issue.record("expected CLIError, got \(error)")
        }
        #expect(asked == 1)
    }
}

@Suite("tbd panel apply envelope")
struct PanelEnvelopeTests {
    @Test func carriesTheTabsRevisionAsTheAgentCLI() {
        let worktreeID = UUID()
        let tabID = UUID()
        let operationID = UUID()
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, primary: .terminal(terminalID: UUID()), revision: 4)
        let envelope = panelEnvelope(
            worktreeID: worktreeID, tabID: tabID,
            current: PanelGetResult(tabs: [surface], activeTabID: nil),
            operation: .setCollapsed(true), operationID: operationID)
        #expect(envelope == PanelOperationEnvelope(
            operationID: operationID, worktreeID: worktreeID, tabID: tabID,
            baseRevision: 4, origin: .agentCLI, operation: .setCollapsed(true)))
    }

    /// With the side panel off no surface exists, so the get comes back empty.
    /// The apply still goes out without a base revision, and the daemon's
    /// refusal naming the flag is what the user sees.
    @Test func aTabWithNoSurfaceStillSendsWithoutABaseRevision() {
        let tabID = UUID()
        let envelope = panelEnvelope(
            worktreeID: UUID(), tabID: tabID,
            current: PanelGetResult(tabs: [], activeTabID: nil),
            operation: .resize(width: 0.4))
        #expect(envelope.tabID == tabID)
        #expect(envelope.baseRevision == nil)
        #expect(envelope.origin == .agentCLI)
    }
}

@Suite("tbd panel side region rendering")
struct PanelSideRegionRenderingTests {
    private let fileID = UUID()
    private let webID = UUID()
    private let transcriptID = UUID()
    private let terminalID = UUID()

    private func surface(active: UUID?, collapsed: Bool = false) -> WorkspaceTabSurface {
        let side = SideRegion(
            panels: [
                ViewerPanel(id: fileID, content: .file(FileReference(path: "/a.swift"))),
                ViewerPanel(id: webID, content: .web(URL(string: "https://example.com")!)),
                ViewerPanel(id: transcriptID, content: .transcript(terminalID: terminalID)),
            ],
            activePanelID: active,
            recency: [webID, fileID, transcriptID],
            collapsed: collapsed,
            width: 0.4)
        return WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), label: "My Tab",
            primary: .terminal(terminalID: terminalID), side: side, revision: 7)
    }

    @Test func listsPanelsInStripOrderWithKindAndContent() throws {
        let lines = renderSideRegion(surface(active: webID))
        let file = try #require(lines.firstIndex(where: { $0.contains("panel \(fileID)") }))
        let web = try #require(lines.firstIndex(where: { $0.contains("panel \(webID)") }))
        let transcript = try #require(lines.firstIndex(where: { $0.contains("panel \(transcriptID)") }))
        #expect(file < web && web < transcript)
        #expect(lines[file].contains("file /a.swift"))
        #expect(lines[web].contains("web https://example.com"))
        #expect(lines[transcript].contains("transcript \(terminalID)"))
    }

    @Test func marksOnlyTheActivePanel() {
        let lines = renderSideRegion(surface(active: webID))
        let marked = lines.filter { $0.contains("[ACTIVE]") }
        #expect(marked.count == 1)
        #expect(marked.first?.contains("panel \(webID)") == true)
    }

    @Test func notesACollapsedRegion() {
        let lines = renderSideRegion(surface(active: fileID, collapsed: true))
        #expect(lines.first?.contains("collapsed") == true)
        #expect(lines.first?.contains("tbd panel expand") == true)
    }

    @Test func anOpenRegionCarriesNoCollapsedNote() {
        let lines = renderSideRegion(surface(active: fileID))
        #expect(!lines.joined(separator: "\n").contains("collapsed"))
        #expect(lines.first?.contains("width 0.40") == true)
    }

    @Test func anEmptyRegionSaysSo() {
        let tab = WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), primary: .terminal(terminalID: UUID()))
        #expect(renderSideRegion(tab) == ["side region: no panels"])
    }

    @Test func aPanelWithNoContentSaysSo() {
        let panelID = UUID()
        let side = SideRegion(
            panels: [ViewerPanel(id: panelID, history: MRUHistory<PanelContent>())],
            activePanelID: panelID, recency: [panelID])
        let tab = WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), primary: .terminal(terminalID: UUID()), side: side)
        let lines = renderSideRegion(tab)
        #expect(lines.contains(where: { $0.contains("panel \(panelID)") && $0.contains("(no content)") }))
    }

    @Test func tabLinesCarryHeaderPrimaryRevisionAndSideRegion() {
        let tab = surface(active: webID)
        let lines = tabLines(tab, activeTabID: tab.id)
        let joined = lines.joined(separator: "\n")
        #expect(lines.first == "Tab \(tab.id) [ACTIVE] — My Tab")
        #expect(joined.contains("primary: terminal \(terminalID)"))
        #expect(joined.contains("revision: 7"))
        #expect(joined.contains("panel \(webID) [ACTIVE]: web https://example.com"))
    }

    @Test func inactiveTabHasNoActiveMarker() {
        let tab = surface(active: webID)
        let lines = tabLines(tab, activeTabID: UUID())
        #expect(lines.first == "Tab \(tab.id) — My Tab")
    }

    @Test func filePresentationShownWhenNonAutomatic() {
        let content = PanelContent.file(FileReference(path: "/a.md", presentation: .rendered))
        #expect(describe(content) == "file /a.md (rendered)")
    }
}

/// `tbd panel list`: one `panel.get`, scoped to `--tab` when given. Scoped
/// or not, the daemon's reply names the worktree's active tab, which the
/// listing marks `[ACTIVE]`.
@Suite("tbd panel list rendering")
struct PanelListRenderingTests {
    private let activeTabID = UUID()
    private let otherTabID = UUID()

    private var all: PanelGetResult {
        PanelGetResult(
            tabs: [
                WorkspaceTabSurface(
                    id: activeTabID, worktreeID: UUID(), label: "Active",
                    primary: .terminal(terminalID: UUID()), revision: 3),
                WorkspaceTabSurface(
                    id: otherTabID, worktreeID: UUID(), label: "Other",
                    primary: .terminal(terminalID: UUID()), revision: 5),
            ],
            activeTabID: activeTabID)
    }

    /// The daemon's reply to a get scoped to `tabID`: that tab alone, and the
    /// worktree's active tab.
    private func scoped(to tabID: UUID) -> PanelGetResult {
        PanelGetResult(tabs: all.tabs.filter { $0.id == tabID }, activeTabID: activeTabID)
    }

    @Test func tabOptionMarksTheActiveTab() {
        let lines = panelListLines(scoped(to: activeTabID))
        #expect(lines.first == "Tab \(activeTabID) [ACTIVE] — Active")
        #expect(!lines.contains(where: { $0.contains("\(otherTabID)") }), "only the requested tab is listed")
    }

    @Test func tabOptionOnAnInactiveTabListsItUnmarked() {
        let lines = panelListLines(scoped(to: otherTabID))
        #expect(lines.first == "Tab \(otherTabID) — Other")
        #expect(!lines.contains(where: { $0.contains("\(activeTabID)") }))
    }

    @Test func noTabOptionListsEveryTabWithABlankLineBetween() {
        let lines = panelListLines(all)
        let headers = lines.filter { $0.hasPrefix("Tab ") }
        #expect(headers == ["Tab \(activeTabID) [ACTIVE] — Active", "Tab \(otherTabID) — Other"])
        let second = lines.firstIndex(of: "Tab \(otherTabID) — Other")
        #expect(second.map { $0 > 0 && lines[$0 - 1].isEmpty } == true,
                "a blank line separates one tab from the next")
    }

    @Test func aTabTheWorktreeDoesNotHoldListsNothing() {
        #expect(panelListLines(scoped(to: UUID())) == ["No tabs found."])
    }
}
