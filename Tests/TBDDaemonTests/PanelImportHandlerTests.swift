import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Task 11: `panel.importLegacy` handler tests. Router-level — exercises the
/// full gating → convert → commitImport → broadcast pipeline. The pure
/// conversion logic itself is covered exhaustively by
/// `LegacySurfaceImporterTests`/`LegacySurfaceImporterFixtureTests`; here we
/// check the RPC wiring, idempotency, and the two carry-forwards deferred
/// from earlier reviews: active-tab preservation (spec §11.2.7) and
/// dup-terminal-primary tolerance.
@Suite("Panel import handler tests")
struct PanelImportHandlerTests {

    /// Router whose panel-surface broadcasts are captured in `deltas`
    /// (mirrors `RPCRouterWorktreeCreateBroadcastTests`'s pattern).
    private func makeRouterAndDB() throws -> (router: RPCRouter, db: TBDDatabase, deltas: BroadcastDeltas) {
        let db = try TBDDatabase(inMemory: true)
        let deltas = BroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs
        )
        return (router, db, deltas)
    }

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pih-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pih-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    private func panelSurfaceDeltas(_ deltas: BroadcastDeltas) -> [PanelSurfaceDelta] {
        deltas.snapshot().compactMap {
            if case .panelSurfaceChanged(let delta) = $0 { return delta }
            return nil
        }
    }

    // MARK: - Gate

    @Test("import with the surface flag off returns the named gate error, no write")
    func importWithFlagOffReturnsGateError() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        let tabID = UUID()
        let params = PanelImportParams(
            worktreeID: wtID,
            tabs: [LegacyTabPayload(tabID: tabID, label: nil, content: .terminal(terminalID: UUID()), layout: nil)],
            tabOrder: [tabID], activeTabID: tabID, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)

        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("daemon_panel_surface_enabled") == true)
        #expect(try await db.panelSurface.isEmpty(worktreeID: wtID))
        #expect(panelSurfaceDeltas(deltas).isEmpty)
    }

    // MARK: - Full round trip

    /// Two legacy tabs: tabA has an extra terminal leaf (promotes to its own
    /// tab), tabB is a plain terminal tab. Result: 3 surfaces (tabA, promoted,
    /// tabB), 1 promotion, histories present, stamp set, one broadcast.
    @Test("full round trip: convert, commit, stamp, one broadcast, panel.get reflects it")
    func fullRoundTripImports() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)

        let tabAID = UUID()
        let tabBID = UUID()
        let mainTerm = UUID()
        let extraTerm = UUID()
        let viewerID = UUID()
        let layoutA = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: mainTerm)),
                .pane(.codeViewer(id: viewerID, path: "/one")),
                .pane(.terminal(terminalID: extraTerm)),
            ],
            ratios: [0.34, 0.33, 0.33])
        let payloadA = LegacyTabPayload(
            tabID: tabAID, label: "A", content: .terminal(terminalID: mainTerm), layout: layoutA)
        let payloadB = LegacyTabPayload(
            tabID: tabBID, label: "B", content: .terminal(terminalID: UUID()), layout: nil)
        let history = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: viewerID, path: "/one"))

        try await db.config.setPanelSurfaceEnabled(true)
        let params = PanelImportParams(
            worktreeID: wtID, tabs: [payloadA, payloadB], tabOrder: [tabAID, tabBID],
            activeTabID: nil, paneHistories: [viewerID: history])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)

        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(PanelImportResult.self)
        #expect(result.imported == true)
        #expect(result.tabCount == 3)
        #expect(result.promotedTerminalTabs == 1)
        #expect(result.skipped.isEmpty)

        // panel.get reflects the converted surfaces in order.
        let getResponse = await router.handle(
            try RPCRequest(method: RPCMethod.panelGet, params: PanelGetParams(worktreeID: wtID)))
        let getResult = try getResponse.decodeResult(PanelGetResult.self)
        #expect(getResult.tabs.count == 3)
        #expect(getResult.tabs[0].id == tabAID)
        #expect(getResult.tabs[2].id == tabBID)

        // History survives, re-keyed to the new panel ID under tabA.
        let stateA = try await db.panelSurface.state(tabID: tabAID)
        #expect(stateA?.histories.count == 1)

        // Stamp set.
        let stampedAt = try await db.worktrees.panelSurfaceImportedAt(worktreeID: wtID)
        #expect(stampedAt != nil)

        // Exactly one broadcast, carrying the full tab list.
        let broadcasts = panelSurfaceDeltas(deltas)
        #expect(broadcasts.count == 1)
        #expect(broadcasts[0].tabs.count == 3)
        #expect(broadcasts[0].worktreeID == wtID)
    }

    // MARK: - Idempotency: second call is a no-op, no second broadcast

    @Test("second identical call returns imported:false, no DB change, no second broadcast")
    func secondCallIsNoOpNoSecondBroadcast() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        try await db.config.setPanelSurfaceEnabled(true)
        let tabID = UUID()
        let params = PanelImportParams(
            worktreeID: wtID,
            tabs: [LegacyTabPayload(tabID: tabID, label: nil, content: .terminal(terminalID: UUID()), layout: nil)],
            tabOrder: [tabID], activeTabID: nil, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)

        let firstResponse = await router.handle(request)
        #expect(firstResponse.success)
        #expect(try firstResponse.decodeResult(PanelImportResult.self).imported == true)
        #expect(panelSurfaceDeltas(deltas).count == 1)

        let secondResponse = await router.handle(request)
        #expect(secondResponse.success)
        let secondResult = try secondResponse.decodeResult(PanelImportResult.self)
        #expect(secondResult.imported == false)
        #expect(secondResult.tabCount == 0)
        #expect(secondResult.promotedTerminalTabs == 0)
        #expect(secondResult.skipped.isEmpty)

        // Nothing changed, and no second broadcast.
        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.map(\.id) == [tabID])
        #expect(panelSurfaceDeltas(deltas).count == 1)
    }

    // MARK: - Payload hygiene: orphan history keys dropped

    @Test("paneHistories entries keyed by IDs absent from every tab tree are dropped")
    func orphanHistoryKeysDropped() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        try await db.config.setPanelSurfaceEnabled(true)
        let tabID = UUID()
        let mainTerm = UUID()
        let viewerID = UUID()
        let orphanID = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: mainTerm)), .pane(.codeViewer(id: viewerID, path: "/x"))],
            ratios: [0.5, 0.5])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: mainTerm), layout: layout)
        // orphanID appears in NO payload tab tree — daemon-side defense must
        // drop it before conversion (it would otherwise be silently ignored
        // by the importer anyway, but this pins the hygiene filter itself).
        let orphanHistory = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: orphanID, path: "/orphan"))
        let liveHistory = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: viewerID, path: "/x"))
        _ = deltas

        let params = PanelImportParams(
            worktreeID: wtID, tabs: [payload], tabOrder: [tabID], activeTabID: nil,
            paneHistories: [orphanID: orphanHistory, viewerID: liveHistory])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(PanelImportResult.self)
        #expect(result.tabCount == 1)

        let state = try await db.panelSurface.state(tabID: tabID)
        #expect(state?.histories.count == 1)
    }

    // MARK: - Skipped-tab reason propagates

    @Test("a malformed tab's skip reason propagates into the result, its terminals still promote")
    func skippedTabReasonPropagates() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        try await db.config.setPanelSurfaceEnabled(true)
        _ = deltas
        let tabID = UUID()
        let declaredPrimary = UUID()
        let actualTerm = UUID()
        // Declared primary (`declaredPrimary`) never appears as a leaf in the
        // tree — malformed data the importer must skip the tab (0 primaries)
        // while still promoting EVERY terminal it references: the tree's own
        // leaf (`actualTerm`) AND the declared-but-unmatched primary itself
        // (`LegacySurfaceImporter.convertTab`'s doc comment: "never kill or
        // discard a terminal", covering both cases).
        let layout = LayoutNode.pane(.terminal(terminalID: actualTerm))
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: declaredPrimary), layout: layout)

        let params = PanelImportParams(
            worktreeID: wtID, tabs: [payload], tabOrder: [tabID], activeTabID: nil, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(PanelImportResult.self)
        #expect(result.skipped.count == 1)
        #expect(result.skipped[0].contains(tabID.uuidString))
        // The tab's own surface never lands; both its terminals are promoted.
        #expect(result.tabCount == 2)
        #expect(result.promotedTerminalTabs == 2)
        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        let terminalIDs = surfaces.compactMap { surface -> UUID? in
            if case .terminal(let id) = surface.primary { return id }
            return nil
        }
        #expect(Set(terminalIDs) == Set([declaredPrimary, actualTerm]))
    }

    // MARK: - Carry-forward 1: active-tab metadata survives import (spec §11.2.7)

    @Test("the imported worktree's active tab is set from the legacy payload's activeTabID")
    func activeTabSurvivesImport() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        try await db.config.setPanelSurfaceEnabled(true)
        let tabAID = UUID()
        let tabBID = UUID()
        let payloadA = LegacyTabPayload(
            tabID: tabAID, label: "A", content: .terminal(terminalID: UUID()), layout: nil)
        let payloadB = LegacyTabPayload(
            tabID: tabBID, label: "B", content: .terminal(terminalID: UUID()), layout: nil)

        let params = PanelImportParams(
            worktreeID: wtID, tabs: [payloadA, payloadB], tabOrder: [tabAID, tabBID],
            activeTabID: tabBID, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)
        let response = await router.handle(request)

        #expect(response.success)
        let persistedActive = try await db.worktrees.getActiveTabID(worktreeID: wtID)
        #expect(persistedActive == tabBID)

        let broadcasts = panelSurfaceDeltas(deltas)
        #expect(broadcasts.count == 1)
        #expect(broadcasts[0].activeTabID == tabBID)
    }

    @Test("an activeTabID that matches no imported tab (its source was skipped) leaves active tab unset")
    func activeTabWithNoSurvivingSurfaceLeavesUnset() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        try await db.config.setPanelSurfaceEnabled(true)
        _ = deltas
        let tabID = UUID()
        let declaredPrimary = UUID()
        let layout = LayoutNode.pane(.terminal(terminalID: UUID()))
        // Malformed: declared primary never in the tree -> tab is skipped ->
        // no surface exists under `tabID` for the active-tab pointer to match.
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: declaredPrimary), layout: layout)

        let params = PanelImportParams(
            worktreeID: wtID, tabs: [payload], tabOrder: [tabID], activeTabID: tabID, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)
        let response = await router.handle(request)

        #expect(response.success)
        let persistedActive = try await db.worktrees.getActiveTabID(worktreeID: wtID)
        #expect(persistedActive == nil)
    }

    // MARK: - Carry-forward 2: dup-terminal-primary blob is tolerated

    /// A corrupt legacy blob where one tab's tree contains the SAME terminal
    /// UUID twice: the first occurrence matches the declared primary, the
    /// second is an "extra" terminal leaf that gets promoted into its own
    /// new tab (spec §11.2 step 4, "never kill or discard a terminal"). Both
    /// output tabs end up with `primary == .terminal(terminalID: dupTerm)` —
    /// the importer over-promotes rather than drops. Neither
    /// `commitImport`'s `panelHistoryOwnedByOtherTab` guard nor any DB
    /// constraint may fire: terminal primaries are never `PanelContent`
    /// panels, so they never appear in `panel_history`.
    @Test("two output tabs sharing a primary terminalID (corrupt dup-terminal blob) commit without error")
    func dupTerminalPrimaryBlobCommitsWithoutError() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        try await db.config.setPanelSurfaceEnabled(true)
        let tabID = UUID()
        let dupTerm = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: dupTerm)), .pane(.terminal(terminalID: dupTerm))],
            ratios: [0.5, 0.5])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: dupTerm), layout: layout)

        let params = PanelImportParams(
            worktreeID: wtID, tabs: [payload], tabOrder: [tabID], activeTabID: nil, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(PanelImportResult.self)
        #expect(result.tabCount == 2, "the source tab + its promoted duplicate terminal")
        #expect(result.promotedTerminalTabs == 1)
        #expect(result.skipped.isEmpty)

        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.count == 2, "both tabs survive")
        let terminalIDs = surfaces.compactMap { surface -> UUID? in
            if case .terminal(let id) = surface.primary { return id }
            return nil
        }
        #expect(terminalIDs == [dupTerm, dupTerm], "both surviving tabs claim the SAME primary terminalID")

        let broadcasts = panelSurfaceDeltas(deltas)
        #expect(broadcasts.count == 1)
    }
}

/// Thread-safe collector for broadcast StateDeltas (mirrors the private
/// helper in `RPCRouterWorktreeCreateBroadcastTests`).
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}
