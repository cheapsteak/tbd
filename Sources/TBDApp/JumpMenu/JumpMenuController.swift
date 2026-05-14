import AppKit
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "JumpMenu")

@MainActor
final class JumpMenuController {
    static let shared = JumpMenuController()

    private weak var appState: AppState?
    private var panel: FloatingPanel?
    private var viewModel: JumpMenuViewModel?

    private init() {}

    /// Wire AppState once at app launch. Called from TBDApp.swift after
    /// the AppState instance is created. Keeping this out of the
    /// initializer avoids a chicken-and-egg with @StateObject AppState.
    func configure(appState: AppState) {
        self.appState = appState
    }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    private func open() {
        guard let appState else {
            logger.warning("toggle() called before configure(appState:)")
            return
        }

        // Snapshot all worktrees + unread + recents at open time. Mutations
        // arriving while the panel is visible don't affect the displayed
        // list — that's the design's "snapshot semantics" rule.
        let snapshots = appState.worktrees.values
            .flatMap { $0 }
            .map { wt -> JumpMenuWorktreeSnapshot in
                let repoName = appState.repos.first { $0.id == wt.repoID }?.displayName ?? "?"
                return JumpMenuWorktreeSnapshot(
                    id: wt.id,
                    displayName: wt.displayName,
                    repoName: repoName
                )
            }

        let vm = JumpMenuViewModel(
            worktrees: snapshots,
            unread: appState.unreadByWorktree,
            recentIDs: appState.recentWorktreeIDs
        )
        self.viewModel = vm

        let view = JumpMenuView(
            viewModel: vm,
            onSubmit: { [weak self] row in
                self?.submit(row)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        let panel = self.panel ?? JumpMenuPanel(content: view)
        panel.updateContent(view)
        positionPanel(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        logger.debug("Jump menu opened with \(snapshots.count, privacy: .public) worktrees, \(appState.unreadByWorktree.count, privacy: .public) unread, \(appState.recentWorktreeIDs.count, privacy: .public) recents")
    }

    private func close() {
        panel?.dismiss()
        viewModel = nil
    }

    private func submit(_ row: JumpMenuRow) {
        guard let appState else { return }
        // Filter against the live worktree map — the snapshot may be stale
        // if a worktree was deleted while the panel was open.
        let liveIDs = Set(appState.worktrees.values.flatMap { $0 }.map(\.id))
        guard liveIDs.contains(row.id) else {
            logger.debug("Submit on stale worktree id \(row.id, privacy: .public) — closing without jumping")
            close()
            return
        }
        appState.selectedWorktreeIDs = [row.id]
        close()
    }

    /// Anchor the panel ~80pt below the top of the key TBD window,
    /// horizontally centered. If there is no key window (e.g. all windows
    /// are minimized) fall back to the main screen.
    private func positionPanel(_ panel: NSPanel) {
        let panelSize = panel.frame.size == .zero
            ? CGSize(width: 440, height: 360)
            : panel.frame.size

        let anchorRect: NSRect = {
            if let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                return win.frame
            }
            return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        }()

        let originX = anchorRect.midX - panelSize.width / 2
        let originY = anchorRect.maxY - panelSize.height - 80
        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize),
            display: true
        )
    }
}

/// FloatingPanel variant that *can* become the key window. The base
/// FloatingPanel is non-key by design (hover overlays); the jump menu
/// needs key status so its TextField receives input.
final class JumpMenuPanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}
