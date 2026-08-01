import Foundation
import SwiftUI
import TBDShared
import Testing

@testable import TBDApp

/// Phase 3b slice 3 — the workspace render-path branch, the leaf content
/// mapping the shared leaf view is fed through, and the daemon-backed
/// `PaneActions` set.
///
/// Tier 1: deterministic, in-process only. Every daemon hop goes through the
/// injected `panelApplyTrigger` / `panelGetFetcher` closures, so no socket is
/// opened, and every `AppState` gets its own `UserDefaults` suite so the
/// developer's real `TBDApp.plist` is never touched.
@Suite("Panel surface render branch")
@MainActor
struct PanelSurfaceRenderBranchTests {

    // MARK: - Fixtures

    private static let fileURL = URL(string: "https://example.com/panels")!

    private struct UnstubbedSeam: Error {}

    private static func makeState(
        flagEnabled: Bool, panelSurfaceEnabled: Bool = true,
        _ body: @MainActor (AppState) async throws -> Void
    ) async rethrows {
        let suiteName = "PanelSurfaceRenderBranchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(flagEnabled, forKey: AppState.enableDaemonManagedPanelsKey)
        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, panelSurfaceEnabled: panelSurfaceEnabled)
        // Fail loudly if a test reaches a seam it did not stub.
        state.panelApplyTrigger = { _ in
            Issue.record("unexpected panel.apply")
            throw UnstubbedSeam()
        }
        state.panelGetFetcher = { _ in
            Issue.record("unexpected panel.get")
            throw UnstubbedSeam()
        }
        try await body(state)
    }

    /// A one-viewer-panel tab: primary terminal on the left, `panelID` on the
    /// right, joined by `splitID`.
    private static func surface(
        tabID: UUID, worktreeID: UUID, terminalID: UUID,
        panelID: UUID, splitID: UUID, panelContent: PanelContent,
        revision: UInt64 = 1
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID,
            primary: .terminal(terminalID: terminalID),
            layout: .split(SplitNode(
                id: splitID, direction: .horizontal,
                children: [.primary, .panel(PanelSlot(id: panelID, content: panelContent))],
                ratios: [0.65, 0.35])),
            revision: revision)
    }

    /// Fire `gesture` and return the envelope the chokepoint handed to
    /// `panel.apply`. Deterministic — the stub resumes the continuation, so
    /// nothing here polls or yields on a hope.
    private static func capture(
        _ state: AppState, committing tab: WorkspaceTabSurface,
        _ gesture: @MainActor () -> Void
    ) async -> PanelOperationEnvelope {
        await withCheckedContinuation(isolation: MainActor.shared) { continuation in
            state.panelApplyTrigger = { envelope in
                continuation.resume(returning: envelope)
                return PanelApplyResult(tab: tab, replayed: false)
            }
            gesture()
        }
    }

    // MARK: - Leaf content mapping (spec §Components — content only)

    @Test("every PanelContent case maps to a leaf PaneContent carrying the panel's identity")
    func panelContentMappingIsTotal() {
        let panelID = UUID()
        let terminalID = UUID()
        let noteID = UUID()

        #expect(PanelSurfaceLeaf.paneContent(
            for: .file(FileReference(path: "/tmp/a.swift")), panelID: panelID)
            == .codeViewer(id: panelID, path: "/tmp/a.swift"))
        #expect(PanelSurfaceLeaf.paneContent(for: .web(Self.fileURL), panelID: panelID)
            == .webview(id: panelID, url: Self.fileURL))
        #expect(PanelSurfaceLeaf.paneContent(for: .transcript(terminalID: terminalID), panelID: panelID)
            == .liveTranscript(id: panelID, terminalID: terminalID))
        // A note's legacy pane identity IS its note ID, not the panel ID —
        // which is exactly why the daemon action set captures its own
        // PanelID rather than reading it back off the leaf content.
        #expect(PanelSurfaceLeaf.paneContent(for: .note(noteID: noteID), panelID: panelID)
            == .note(noteID: noteID))
    }

    @Test("every PrimaryContent case maps to a leaf PaneContent, terminal included")
    func primaryContentMappingIsTotal() {
        let primaryID = UUID()
        let terminalID = UUID()
        let noteID = UUID()

        #expect(PanelSurfaceLeaf.paneContent(for: .terminal(terminalID: terminalID), primaryID: primaryID)
            == .terminal(terminalID: terminalID))
        #expect(PanelSurfaceLeaf.paneContent(for: .note(noteID: noteID), primaryID: primaryID)
            == .note(noteID: noteID))
        #expect(PanelSurfaceLeaf.paneContent(
            for: .file(FileReference(path: "/tmp/b.md")), primaryID: primaryID)
            == .codeViewer(id: primaryID, path: "/tmp/b.md"))
        #expect(PanelSurfaceLeaf.paneContent(for: .web(Self.fileURL), primaryID: primaryID)
            == .webview(id: primaryID, url: Self.fileURL))
        #expect(PanelSurfaceLeaf.paneContent(for: .transcript(terminalID: terminalID), primaryID: primaryID)
            == .liveTranscript(id: primaryID, terminalID: terminalID))
    }

    @Test("leaf content survives the round trip back to PanelContent")
    func panelContentRoundTrips() {
        let panelID = UUID()
        let cases: [PanelContent] = [
            .file(FileReference(path: "/tmp/c.swift")),
            .web(Self.fileURL),
            .transcript(terminalID: UUID()),
            .note(noteID: UUID()),
        ]
        for content in cases {
            let leaf = PanelSurfaceLeaf.paneContent(for: content, panelID: panelID)
            #expect(PanelSurfaceLeaf.panelContent(for: leaf) == content,
                    "content identity must survive the leaf mapping for \(content)")
        }
    }

    @Test("a terminal has no viewer-panel form")
    func terminalHasNoPanelForm() {
        // Spec C §5.5 — the invariant is enforced at the type level, so the
        // reverse mapping is partial by construction, not by oversight.
        #expect(PanelSurfaceLeaf.panelContent(for: .terminal(terminalID: UUID())) == nil)
    }

    // MARK: - Render-path branch

    @Test("flag OFF selects the legacy renderer even with a surface mirrored")
    func flagOffSelectsLegacy() async {
        await Self.makeState(flagEnabled: false) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            // The mirror can be non-empty with the flag off only if something
            // seeded it directly; assert the branch ignores it regardless.
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [Self.surface(
                    tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                    panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))],
                activeTabID: tabID)

            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tabID) == .legacy)
        }
    }

    @Test("flag ON with an EMPTY mirror still selects legacy — never a blank workspace")
    func flagOnWithoutSurfaceSelectsLegacy() async {
        await Self.makeState(flagEnabled: true) { state in
            #expect(state.daemonManagedPanelsActive, "precondition: the switch is on")
            #expect(state.panelSurfaces.isEmpty, "precondition: the mirror starts empty")

            #expect(state.workspaceRenderPath(worktreeID: UUID(), tabID: UUID()) == .legacy)
        }
    }

    @Test("flag ON with a mirrored surface selects the daemon renderer")
    func flagOnWithSurfaceSelectsDaemon() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)

            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tabID)
                == .daemonSurface(surface))
            // A sibling tab that the mirror does not hold still falls back.
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: UUID()) == .legacy)
        }
    }

    @Test("the daemon store flag OFF selects legacy even with a mirrored surface")
    func storeFlagOffSelectsLegacy() async {
        await Self.makeState(flagEnabled: true, panelSurfaceEnabled: false) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [Self.surface(
                    tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                    panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))],
                activeTabID: tabID)

            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tabID) == .legacy)
        }
    }

    // MARK: - Daemon-backed PaneActions → PanelOperation

    @Test("openBeside becomes a .beside open anchored on the leaf's own panel")
    func openBesideMapsToBeside() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let panelID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: panelID, splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))

            let envelope = await Self.capture(state, committing: surface) {
                actions.openBeside(panelID, .horizontal, .codeViewer(id: UUID(), path: "/tmp/x.swift"))
            }

            #expect(envelope.origin == .appUser)
            #expect(envelope.baseRevision == 1)
            #expect(envelope.operation == .open(
                content: .file(FileReference(path: "/tmp/x.swift")),
                placement: .beside(target: .panel(panelID), edge: .right, share: nil)))
        }
    }

    @Test("a vertical openBeside off the primary anchor lands below the primary")
    func openBesideVerticalFromPrimary() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let terminalID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            let envelope = await Self.capture(state, committing: surface) {
                actions.openBeside(terminalID, .vertical, .webview(id: UUID(), url: Self.fileURL))
            }

            #expect(envelope.operation == .open(
                content: .web(Self.fileURL),
                placement: .beside(target: .primary, edge: .below, share: nil)))
        }
    }

    @Test("openBeside with terminal content is dropped, not sent")
    func openBesideDropsTerminalContent() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let panelID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: panelID, splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))

            // Absence is proved by ordering, not by waiting: the dropped
            // gesture fires first and the next envelope to arrive must be the
            // known-good one.
            let envelope = await Self.capture(state, committing: surface) {
                actions.openBeside(panelID, .horizontal, .terminal(terminalID: UUID()))
                actions.close(.webview(id: panelID, url: Self.fileURL))
            }

            #expect(envelope.operation == .close(panelID: panelID))
        }
    }

    @Test("routeFile becomes an .automatic file open — the reducer's reuse-then-split contract")
    func routeFileMapsToAutomaticOpen() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let terminalID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            let envelope = await Self.capture(state, committing: surface) {
                actions.routeFile(terminalID, "/tmp/clicked.swift")
            }

            #expect(envelope.operation == .open(
                content: .file(FileReference(path: "/tmp/clicked.swift")), placement: .automatic))
        }
    }

    @Test("toggleTranscript opens when closed and closes the open transcript panel")
    func toggleTranscriptBothDirections() async {
        let worktreeID = UUID()
        let tabID = UUID()
        let terminalID = UUID()
        let panelID = UUID()

        await Self.makeState(flagEnabled: true) { state in
            let closed = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: panelID, splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [closed], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)
            #expect(actions.isTranscriptOpen(terminalID) == false)

            let envelope = await Self.capture(state, committing: closed) {
                actions.toggleTranscript(terminalID, terminalID)
            }
            #expect(envelope.operation == .open(
                content: .transcript(terminalID: terminalID), placement: .automatic))
        }

        await Self.makeState(flagEnabled: true) { state in
            let open = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: panelID, splitID: UUID(),
                panelContent: .transcript(terminalID: terminalID))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [open], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)
            #expect(actions.isTranscriptOpen(terminalID))
            #expect(actions.isTranscriptOpen(UUID()) == false,
                    "another terminal's transcript must not read as open")

            let envelope = await Self.capture(state, committing: open) {
                actions.toggleTranscript(terminalID, terminalID)
            }
            #expect(envelope.operation == .close(panelID: panelID))
        }
    }

    @Test("each history step maps to its PanelHistoryAction")
    func historyStepsMap() async {
        let expected: [(PaneActions.HistoryStep, PanelHistoryAction)] = [
            (.back, .back), (.forward, .forward), (.to(index: 3), .jump(index: 3)),
        ]
        for (step, action) in expected {
            await Self.makeState(flagEnabled: true) { state in
                let worktreeID = UUID()
                let tabID = UUID()
                let panelID = UUID()
                let surface = Self.surface(
                    tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                    panelID: panelID, splitID: UUID(), panelContent: .web(Self.fileURL))
                state.panelSurfaces[worktreeID] = PanelGetResult(
                    tabs: [surface], activeTabID: tabID)
                let actions = PaneActions.daemonManaged(
                    appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))

                let envelope = await Self.capture(state, committing: surface) {
                    actions.historyStep(panelID, step)
                }
                #expect(envelope.operation == .history(panelID: panelID, action: action))
            }
        }
    }

    @Test("resize maps the divider's CGFloat ratios onto the split")
    func resizeMaps() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let splitID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: UUID(), splitID: splitID, panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            let envelope = await Self.capture(state, committing: surface) {
                actions.resize(splitID, [0.4, 0.6])
            }

            #expect(envelope.operation == .resize(splitID: splitID, ratios: [0.4, 0.6]))
        }
    }

    @Test("the primary anchor cannot be closed or history-navigated")
    func primaryAnchorGesturesAreNoOps() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let terminalID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            // `.primary` is unremovable and history-less by type in the shared
            // reducer; both gestures must be dropped app-side rather than sent
            // and rejected. Absence proved by ordering (see above).
            let envelope = await Self.capture(state, committing: surface) {
                actions.close(.terminal(terminalID: terminalID))
                actions.historyStep(terminalID, .back)
                actions.routeFile(terminalID, "/tmp/marker.swift")
            }

            #expect(envelope.operation == .open(
                content: .file(FileReference(path: "/tmp/marker.swift")), placement: .automatic))
        }
    }

    // MARK: - Close is not delete

    @Test("closing a note panel removes the panel only — the note survives")
    func closingANoteDoesNotDeleteIt() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let panelID = UUID()
            let noteID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: panelID, splitID: UUID(), panelContent: .note(noteID: noteID))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            state.notes[worktreeID] = [
                Note(id: noteID, worktreeID: worktreeID, title: "keep me", content: "body",
                     createdAt: Date(), updatedAt: Date()),
            ]
            // Legacy state that the daemon path must leave completely alone.
            let legacyTabID = UUID()
            state.layouts[legacyTabID] = .pane(.note(noteID: noteID))
            state.paneHistories[noteID] = PaneHistory.seeded(with: .note(noteID: noteID))

            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))
            let envelope = await Self.capture(state, committing: surface) {
                actions.close(.note(noteID: noteID))
            }

            // The panel goes; nothing else does. Close ≠ delete is the
            // intended new semantics (spec §Non-goals) — the delete
            // affordance is a separate follow-up, so a note closed here is
            // deliberately left with no in-app removal path.
            #expect(envelope.operation == .close(panelID: panelID),
                    "the note's PanelID, not its note ID, identifies the panel")
            #expect(state.notes[worktreeID]?.contains { $0.id == noteID } == true)
            #expect(state.layouts[legacyTabID] == .pane(.note(noteID: noteID)),
                    "the daemon path must not touch the legacy layout store")
            #expect(state.paneHistories[noteID] != nil,
                    "the daemon path must not touch legacy pane histories")
        }
    }

    // MARK: - Queries

    @Test("the daemon path reports an honest single-entry history")
    func historyQueryIsSeeded() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let panelID = UUID()
            let content = PaneContent.codeViewer(id: panelID, path: "/tmp/y.swift")
            // A stale legacy entry under the same key must NOT leak through:
            // the mirror carries no histories, so anything the legacy store
            // happens to hold is unrelated to the daemon-owned panel.
            state.paneHistories[panelID] = PaneHistory.seeded(with: .note(noteID: UUID()))

            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))
            let history = actions.history(panelID, content)

            #expect(history.entries == [content])
            #expect(history.canGoBack == false)
            #expect(history.canGoForward == false)
        }
    }

    @Test("the legacy action set still answers both queries from the tree")
    func legacyQueriesUnchanged() async {
        await Self.makeState(flagEnabled: false) { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            let transcriptID = UUID()
            let paneID = UUID()
            var tree = LayoutNode.split(
                id: UUID(), direction: .horizontal,
                children: [
                    .pane(.terminal(terminalID: terminalID)),
                    .pane(.liveTranscript(id: transcriptID, terminalID: terminalID)),
                ],
                ratios: [0.5, 0.5])
            let binding = Binding(get: { tree }, set: { tree = $0 })
            let recorded = PaneHistory.seeded(with: .note(noteID: UUID()))
            state.paneHistories[paneID] = recorded

            let actions = PaneActions.legacy(
                layout: binding, appState: state, worktreeID: worktreeID)

            #expect(actions.isTranscriptOpen(terminalID))
            #expect(actions.isTranscriptOpen(UUID()) == false)
            #expect(actions.history(paneID, .terminal(terminalID: terminalID)) == recorded)
            let unknown = UUID()
            #expect(actions.history(unknown, .terminal(terminalID: terminalID))
                == PaneHistory.seeded(with: .terminal(terminalID: terminalID)),
                "a pane with no recorded history falls back to its current content")
        }
    }
}
