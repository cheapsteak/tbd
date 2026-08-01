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

    /// Every envelope the chokepoint handed to `panel.apply` during a gesture,
    /// in arrival order.
    @MainActor
    private final class EnvelopeCollector {
        private(set) var envelopes: [PanelOperationEnvelope] = []
        func record(_ envelope: PanelOperationEnvelope) { envelopes.append(envelope) }
    }

    /// Fire `gesture` and return every envelope it produced.
    ///
    /// Collecting, rather than resuming a `CheckedContinuation` from the stub:
    /// several tests here assert that a gesture produces *no* envelope, and a
    /// regression that made one fire would resume the continuation twice —
    /// `SWIFT TASK CONTINUATION MISUSE`, which kills the test process instead
    /// of failing the test. As an array the same regression is one extra
    /// element and a readable diff.
    private static func collect(
        _ state: AppState, committing tab: WorkspaceTabSurface,
        _ gesture: @MainActor () -> Void
    ) async -> [PanelOperationEnvelope] {
        let collector = EnvelopeCollector()
        state.panelApplyTrigger = { envelope in
            collector.record(envelope)
            return PanelApplyResult(tab: tab, replayed: false)
        }
        gesture()
        await drainMainActor()
        return collector.envelopes
    }

    /// Let the `Task {}` bodies the action set spawns run to completion.
    ///
    /// The gestures are synchronous closures that enqueue a MainActor task
    /// each, so handing the main actor back repeatedly is all the
    /// synchronization needed. No clock and no sleep is involved, and —
    /// unlike an "absence proved by ordering" assertion — nothing here
    /// depends on two sequentially created tasks running in creation order.
    private static func drainMainActor() async {
        for _ in 0..<64 { await Task.yield() }
    }

    /// The one envelope a gesture was supposed to produce. Fails cleanly,
    /// naming everything that actually arrived, rather than indexing off the
    /// end of an empty array.
    private static func single(
        _ envelopes: [PanelOperationEnvelope],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> PanelOperationEnvelope {
        try #require(
            envelopes.count == 1 ? envelopes.first : nil,
            "expected exactly one envelope, observed \(envelopes.map(\.operation))",
            sourceLocation: sourceLocation)
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
    func openBesideMapsToBeside() async throws {
        try await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let panelID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: panelID, splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))

            let envelope = try Self.single(await Self.collect(state, committing: surface) {
                actions.openBeside(panelID, .horizontal, .codeViewer(id: UUID(), path: "/tmp/x.swift"))
            })

            #expect(envelope.origin == .appUser)
            #expect(envelope.baseRevision == 1)
            #expect(envelope.operation == .open(
                content: .file(FileReference(path: "/tmp/x.swift")),
                placement: .beside(target: .panel(panelID), edge: .right, share: nil)))
        }
    }

    @Test("a vertical openBeside off the primary anchor lands below the primary")
    func openBesideVerticalFromPrimary() async throws {
        try await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let terminalID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            let envelope = try Self.single(await Self.collect(state, committing: surface) {
                actions.openBeside(terminalID, .vertical, .webview(id: UUID(), url: Self.fileURL))
            })

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

            // The dropped gesture contributes nothing to the collected
            // sequence. The known-good close alongside it is a positive
            // control: it proves the drain is long enough to have seen an
            // envelope, so the empty half is absence and not impatience.
            let envelopes = await Self.collect(state, committing: surface) {
                actions.openBeside(panelID, .horizontal, .terminal(terminalID: UUID()))
                actions.close(.webview(id: panelID, url: Self.fileURL))
            }

            #expect(envelopes.map(\.operation) == [.close(panelID: panelID)],
                    "terminal content has no viewer-panel form and must be dropped app-side")
        }
    }

    @Test("routeFile becomes an .automatic file open — the reducer's reuse-then-split contract")
    func routeFileMapsToAutomaticOpen() async throws {
        try await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let terminalID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: UUID(), splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            let envelope = try Self.single(await Self.collect(state, committing: surface) {
                actions.routeFile(terminalID, "/tmp/clicked.swift")
            })

            #expect(envelope.operation == .open(
                content: .file(FileReference(path: "/tmp/clicked.swift")), placement: .automatic))
        }
    }

    @Test("toggleTranscript opens when closed and closes the open transcript panel")
    func toggleTranscriptBothDirections() async throws {
        let worktreeID = UUID()
        let tabID = UUID()
        let terminalID = UUID()
        let panelID = UUID()

        try await Self.makeState(flagEnabled: true) { state in
            let closed = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: terminalID,
                panelID: panelID, splitID: UUID(), panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [closed], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)
            #expect(actions.isTranscriptOpen(terminalID) == false)

            let envelope = try Self.single(await Self.collect(state, committing: closed) {
                actions.toggleTranscript(terminalID, terminalID)
            })
            #expect(envelope.operation == .open(
                content: .transcript(terminalID: terminalID), placement: .automatic))
        }

        try await Self.makeState(flagEnabled: true) { state in
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

            let envelope = try Self.single(await Self.collect(state, committing: open) {
                actions.toggleTranscript(terminalID, terminalID)
            })
            #expect(envelope.operation == .close(panelID: panelID))
        }
    }

    @Test("each history step maps to its PanelHistoryAction")
    func historyStepsMap() async throws {
        let expected: [(PaneActions.HistoryStep, PanelHistoryAction)] = [
            (.back, .back), (.forward, .forward), (.to(index: 3), .jump(index: 3)),
        ]
        for (step, action) in expected {
            try await Self.makeState(flagEnabled: true) { state in
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

                let envelope = try Self.single(await Self.collect(state, committing: surface) {
                    actions.historyStep(panelID, step)
                })
                #expect(envelope.operation == .history(panelID: panelID, action: action))
            }
        }
    }

    @Test("resize maps the divider's CGFloat ratios onto the split")
    func resizeMaps() async throws {
        try await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let splitID = UUID()
            let surface = Self.surface(
                tabID: tabID, worktreeID: worktreeID, terminalID: UUID(),
                panelID: UUID(), splitID: splitID, panelContent: .web(Self.fileURL))
            state.panelSurfaces[worktreeID] = PanelGetResult(tabs: [surface], activeTabID: tabID)
            let actions = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)

            let envelope = try Self.single(await Self.collect(state, committing: surface) {
                actions.resize(splitID, [0.4, 0.6])
            })

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
            // and rejected. The trailing routeFile is a positive control (see
            // `openBesideDropsTerminalContent`).
            let envelopes = await Self.collect(state, committing: surface) {
                actions.close(.terminal(terminalID: terminalID))
                actions.historyStep(terminalID, .back)
                actions.routeFile(terminalID, "/tmp/marker.swift")
            }

            #expect(envelopes.map(\.operation) == [.open(
                content: .file(FileReference(path: "/tmp/marker.swift")), placement: .automatic)],
                "close and history on the primary anchor must contribute no envelope")
        }
    }

    // MARK: - canClose

    @Test("the daemon path can close a viewer panel but not the primary anchor")
    func canCloseTracksTheAnchor() async {
        await Self.makeState(flagEnabled: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let panelID = UUID()

            let onPanel = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .panel(panelID))
            #expect(onPanel.canClose(), "a viewer panel has a PanelID to close")

            let onPrimary = PaneActions.daemonManaged(
                appState: state, worktreeID: worktreeID, tabID: tabID, anchor: .primary)
            // The leaf disables its × on this branch. Without the query the
            // button renders live and swallows the click, because `close`
            // has no PanelID to name.
            #expect(onPrimary.canClose() == false,
                    "the primary anchor is unremovable — its close button must be disabled")
        }
    }

    @Test("the legacy path can always close a leaf")
    func legacyCanCloseAlways() async {
        await Self.makeState(flagEnabled: false) { state in
            var tree = LayoutNode.pane(.terminal(terminalID: UUID()))
            let binding = Binding(get: { tree }, set: { tree = $0 })
            let actions = PaneActions.legacy(
                layout: binding, appState: state, worktreeID: UUID())

            // Including the last pane in a tab, where `close` falls back to
            // removing the whole tab rather than doing nothing.
            #expect(actions.canClose())
        }
    }

    // MARK: - Close is not delete

    @Test("closing a note panel removes the panel only — the note survives")
    func closingANoteDoesNotDeleteIt() async throws {
        try await Self.makeState(flagEnabled: true) { state in
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
            let envelope = try Self.single(await Self.collect(state, committing: surface) {
                actions.close(.note(noteID: noteID))
            })

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
