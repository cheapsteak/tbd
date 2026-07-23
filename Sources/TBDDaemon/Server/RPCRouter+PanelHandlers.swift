import Foundation
import os
import TBDShared

private let panelHandlersLog = Logger(subsystem: "com.tbd.daemon", category: "panelHandlers")

/// RPC handlers for the daemon-owned panel surface (Task 10/11, spec C §10,
/// §11.2). `panel.get` is ungated (§10.2); `panel.apply` routes straight to
/// `PanelCoordinator.apply`, which owns gating, idempotency, resource
/// validation, and post-commit broadcast internally — these handlers only
/// decode params and translate the coordinator's typed errors to RPC
/// responses. Do NOT re-implement gating for `panel.apply` here.
///
/// `panel.importLegacy` (Task 11) is NOT routed through `PanelCoordinator` —
/// it's a one-shot migration write (convert → commit → stamp), not a
/// surface-mutation operation, so it drives `LegacySurfaceImporter` and
/// `db.panelSurface.commitImport` directly and broadcasts through the same
/// `subscriptions` channel the coordinator uses.
extension RPCRouter {
    func handlePanelGet(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelGetParams.self, from: paramsData)
        let result = try await panelCoordinator.get(worktreeID: params.worktreeID, tabID: params.tabID)
        return try RPCResponse(result: result)
    }

    func handlePanelApply(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelApplyParams.self, from: paramsData)
        do {
            let result = try await panelCoordinator.apply(params.envelope)
            return try RPCResponse(result: result)
        } catch PanelCoordinatorError.surfaceDisabled {
            // Stable string (spec §10.2) — names the flag so the app/CLI can
            // surface an actionable message without matching this exactly.
            return RPCResponse(error: "panel surface is disabled (daemon_panel_surface_enabled)")
        } catch PanelCoordinatorError.agentControlDisabled {
            return RPCResponse(error: "agent panel control is disabled (agent_panel_control_enabled)")
        }
        // Every other `PanelCoordinatorError` case (tabNotFound, staleTarget,
        // invalidResource, operation) has no stable-string requirement — it
        // propagates to `RPCRouter.handle`'s generic catch, which formats it
        // via string interpolation.
    }

    /// One-time §11.2 legacy-layout migration: gate → convert → commit →
    /// stamp → (carry-forward) set active tab → broadcast. Create-if-absent
    /// and idempotent: a worktree already imported (stamped OR holding any
    /// surface row — `commitImport`'s guard) replays as a no-op result, not
    /// an error, and does NOT broadcast again.
    func handlePanelImportLegacy(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelImportParams.self, from: paramsData)

        let config = try await db.config.get()
        guard config.panelSurfaceEnabled else {
            // Stable string (mirrors `handlePanelApply`) — import is
            // meaningless with the store off.
            return RPCResponse(error: "panel surface is disabled (daemon_panel_surface_enabled)")
        }

        // Daemon-side hygiene defense: the app already filters, but never
        // trust the wire — drop any paneHistories entry whose legacy pane ID
        // appears in NO payload tab's tree before handing it to the importer.
        var liveLegacyPaneIDs = Set<UUID>()
        for tab in params.tabs {
            let tree = tab.layout ?? .pane(tab.content)
            liveLegacyPaneIDs.formUnion(tree.allPaneIDs())
        }
        let hygienicPaneHistories = params.paneHistories.filter { liveLegacyPaneIDs.contains($0.key) }

        let conversion = LegacySurfaceImporter.convert(
            worktreeID: params.worktreeID, tabs: params.tabs, tabOrder: params.tabOrder,
            paneHistories: hygienicPaneHistories)

        do {
            try await db.panelSurface.commitImport(
                worktreeID: params.worktreeID, conversion: conversion, now: Date())
        } catch PanelSurfaceStoreError.alreadyImported {
            return try RPCResponse(result: PanelImportResult(
                imported: false, tabCount: 0, promotedTerminalTabs: 0, skipped: []))
        }

        // Carry-forward (spec §11.2.7): `LegacySurfaceImporter.convert` only
        // preserves label/order, not the active tab — this import path owns
        // setting it. Directly-converted tabs keep their legacy `tabID` as
        // their new surface `id` (see `convertTab`), so the legacy
        // `activeTabID` maps to "the same ID, if it survived conversion";
        // when the active tab's own source was skipped (only its terminal(s)
        // got promoted under fresh IDs), there's no surviving counterpart to
        // point at, so the active tab is simply left unset.
        let resolvedActiveTabID = params.activeTabID.flatMap { legacyActiveTabID in
            conversion.surfaces.contains(where: { $0.id == legacyActiveTabID }) ? legacyActiveTabID : nil
        }
        if let resolvedActiveTabID {
            try await db.worktrees.setActiveTabID(worktreeID: params.worktreeID, tabID: resolvedActiveTabID)
        }

        panelHandlersLog.info("""
            panel.importLegacy worktree=\(params.worktreeID, privacy: .public) \
            tabs=\(conversion.surfaces.count, privacy: .public) \
            promoted=\(conversion.promotedTerminalTabs, privacy: .public) \
            skipped=\(conversion.skipped.count, privacy: .public)
            """)

        // Broadcast AFTER commit, exactly once — never on the alreadyImported
        // no-op path above (already returned).
        subscriptions.broadcast(delta: .panelSurfaceChanged(PanelSurfaceDelta(
            worktreeID: params.worktreeID,
            tabs: conversion.surfaces,
            removedTabIDs: [],
            activeTabID: resolvedActiveTabID,
            originOperationID: nil)))

        return try RPCResponse(result: PanelImportResult(
            imported: true, tabCount: conversion.surfaces.count,
            promotedTerminalTabs: conversion.promotedTerminalTabs, skipped: conversion.skipped))
    }
}
