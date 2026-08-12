import AppKit
import Foundation
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Tabs")

/// Edge of a tab where a drop should insert the dragged tab.
enum DropEdge: Sendable, Equatable {
    case leading, trailing
}

/// What the active selection should follow when `applyStoredOrder` re-points it.
///
/// A bare `UUID?` cannot express this: it conflates "the caller omitted an
/// anchor, derive one" with "the caller captured no valid pre-mutation
/// selection". Those need opposite handling — deriving after a mutation reads
/// the already-mutated array, where a stale index has silently re-bound to
/// whatever slid into its slot (the note tab is last, so usually Notes), and
/// pinning that would hand the resolver an arbitrary tab it then honours as a
/// deliberate choice.
enum ActiveTabAnchor: Sendable, Equatable {
    /// Derive the anchor from the current selection. Correct only for a pure
    /// reorder — i.e. when no tab has been added or removed since that
    /// selection was made.
    case derive
    /// Follow this tab id, captured BEFORE the caller mutated the array. `nil`
    /// means there was no explicit selection to preserve, and the selection is
    /// cleared so `resolvedActiveTabIndex`'s default applies.
    case pinned(UUID?)
}

extension AppState {

    // MARK: - Active tab resolution

    /// The tab index a worktree should display: the stored selection when it is
    /// still in range, otherwise the FIRST non-note tab, otherwise 0.
    ///
    /// Single source of truth for "which tab is showing". Every read of
    /// `activeTabIndices` that used to spell its own `?? 0` / `min(idx, count - 1)`
    /// fallback routes through here, because those spellings disagreed: a stale or
    /// oversized index clamped to `count - 1`, and the daemon appends a worktree's
    /// note tab LAST, so the clamp landed on Notes for every freshly-created
    /// worktree. Falling forward to the first non-note tab instead lands on the
    /// agent — matching the daemon's own "active = primary" default — while a
    /// note-only worktree still shows its note at index 0.
    ///
    /// Never overrides a deliberate selection: an in-range stored index is
    /// returned as-is, note tab or not. Returns 0 for an empty tab array;
    /// callers must guard on `isEmpty` before indexing.
    func resolvedActiveTabIndex(worktreeID: UUID) -> Int {
        let arr = tabs[worktreeID] ?? []
        guard !arr.isEmpty else { return 0 }
        if let stored = activeTabIndices[worktreeID], arr.indices.contains(stored) {
            return stored
        }
        return arr.firstIndex { tab in
            if case .note = tab.content { return false }
            return true
        } ?? 0
    }

    /// The tab a worktree should display, or nil when it has no tabs.
    func resolvedActiveTab(worktreeID: UUID) -> TBDShared.Tab? {
        let arr = tabs[worktreeID] ?? []
        guard !arr.isEmpty else { return nil }
        return arr[resolvedActiveTabIndex(worktreeID: worktreeID)]
    }

    /// The tab.id of the worktree's EXPLICIT selection — nil when nothing is
    /// selected or the stored index is out of range. Deliberately does not fall
    /// back to `resolvedActiveTabIndex`: this is the identity a mutation must
    /// preserve, and "no explicit selection" has to stay "no explicit
    /// selection" so the resolver's default keeps applying dynamically.
    func explicitActiveTabID(worktreeID: UUID) -> UUID? {
        guard let arr = tabs[worktreeID],
              let idx = activeTabIndices[worktreeID],
              arr.indices.contains(idx) else { return nil }
        return arr[idx].id
    }

    /// Re-point the stored active index at `tabID`'s CURRENT position after a
    /// mutation of `tabs[worktreeID]`. A nil `tabID` — or one that no longer
    /// exists — clears the entry rather than leaving a stale index behind, so
    /// `resolvedActiveTabIndex`'s first-non-note default takes over instead of a
    /// clamp that would land on the trailing note tab.
    ///
    /// Writes nothing when the entry already holds the right value — every
    /// write to `activeTabIndices` publishes an `AppState.objectWillChange`.
    func repointActiveTab(worktreeID: UUID, to tabID: UUID?) {
        guard let tabID,
              let newIdx = tabs[worktreeID]?.firstIndex(where: { $0.id == tabID }) else {
            if activeTabIndices[worktreeID] != nil {
                activeTabIndices.removeValue(forKey: worktreeID)
            }
            return
        }
        if activeTabIndices[worktreeID] != newIdx {
            activeTabIndices[worktreeID] = newIdx
        }
    }

    // MARK: - Tab metadata loading

    /// Fetch a worktree's persisted tab state, unless it is already hydrated, a
    /// fetch is already in flight, or the attempt budget is spent.
    ///
    /// The retry this gates exists for one narrow window: the daemon inserts a
    /// new worktree's terminal rows *before* it persists tab order / active
    /// tab, so a poll landing in between answers `[]` + nil and the worktree is
    /// stranded with no stored order and no hydrated selection. One retry
    /// always suffices in practice — the daemon writes milliseconds later and
    /// the terminal poll is ~2s.
    ///
    /// Three guards, because `reconcileTabs` (the only caller) runs on every
    /// terminal-list change and `Terminal` compares unequal whenever an agent's
    /// `activityState` flips, i.e. constantly:
    ///
    /// - **hydrated** — the success latch; nothing more to fetch.
    /// - **in flight** — overlapping reconciles must not stack `Task`s for the
    ///   same worktree.
    /// - **attempt cap** — a worktree whose tab state is legitimately and
    ///   permanently empty (bare `main` rows exist in the wild), or whose
    ///   `listTabs` fails the same way every time, would otherwise re-fire the
    ///   RPC forever, with no backoff. `loadTabStates` refunds the attempt only
    ///   for a disconnect (see its `catch`), so a persistent per-worktree error
    ///   still spends the budget and stops.
    func scheduleTabStateHydration(worktreeID: UUID) {
        guard !tabStateHydratedWorktreeIDs.contains(worktreeID),
              tabStateFetchTasks[worktreeID] == nil,
              tabStateFetchAttempts[worktreeID, default: 0] < Self.maxTabStateHydrationAttempts
        else { return }
        tabStateFetchAttempts[worktreeID, default: 0] += 1
        // The handle is stored, not discarded: it IS the in-flight marker, and
        // it lets a caller (today, only tests) await this scheduled work
        // instead of watching for a side effect. The closure is MainActor-bound
        // like its creator, so it cannot start before this assignment lands,
        // and it clears its own entry as its last act — once `value` resumes,
        // the worktree is eligible to schedule again.
        tabStateFetchTasks[worktreeID] = Task {
            await self.loadTabStates(worktreeID: worktreeID)
            self.tabStateFetchTasks.removeValue(forKey: worktreeID)
        }
    }

    /// Pull stored label overrides and tab order from the daemon for a worktree.
    /// Called the first time a worktree's tabs appear in memory.
    ///
    /// Every state write below is guarded on an actual change: this runs on a
    /// retry path, and an unconditional `@Published` write fires a full
    /// `AppState.objectWillChange` for a response that changed nothing.
    func loadTabStates(worktreeID: UUID) async {
        do {
            let response = try await tabStatesFetcher(worktreeID)
            if worktreeTabOrders[worktreeID] != response.order {
                worktreeTabOrders[worktreeID] = response.order
            }
            // Only a response that actually carried persisted state counts as
            // hydrated. A poll landing between the daemon inserting the terminal
            // rows and persisting tab order / active tab answers `[]` + nil; the
            // re-fetch gate in `scheduleTabStateHydration` keeps retrying (up to
            // its cap) until the daemon has written something, and stops once it
            // has (see `tabStateHydratedWorktreeIDs`).
            if !response.order.isEmpty || response.activeTabID != nil {
                tabStateHydratedWorktreeIDs.insert(worktreeID)
            }
            // Apply stored labels to any in-memory tabs that already exist.
            if var arr = tabs[worktreeID] {
                let labelByID = Dictionary(uniqueKeysWithValues: response.tabs.map { ($0.id, $0.label) })
                var changed = false
                for i in arr.indices {
                    guard let label = labelByID[arr[i].id], arr[i].label != label else { continue }
                    arr[i].label = label
                    changed = true
                }
                if changed {
                    tabs[worktreeID] = arr
                }
                applyStoredOrder(worktreeID: worktreeID)
            }
            // Hydrate the persisted active tab. Must run AFTER applyStoredOrder
            // so the resolved index reflects the persisted order. If the stored
            // ID no longer exists (tab was deleted), gracefully fall through and
            // leave activeTabIndices unchanged (the view layer then shows the
            // first non-note tab via `resolvedActiveTabIndex`).
            if let activeID = response.activeTabID,
               let arr = tabs[worktreeID],
               let idx = arr.firstIndex(where: { $0.id == activeID }),
               activeTabIndices[worktreeID] != idx {
                activeTabIndices[worktreeID] = idx
            }
        } catch {
            // Only a DISCONNECT is refunded. It says nothing about whether the
            // daemon has written yet, the poll that would retry is stopped
            // anyway (`handleConnectionError` clears `isConnected`), and
            // burning the budget would strand the worktree for the session.
            //
            // Every other error consumes budget, and must: a decode failure or
            // a per-worktree RPC rejection repeats deterministically while
            // `isConnected` stays set, so the ~2s poll keeps driving
            // `refreshWorktrees` -> `reconcileTabs` -> here. Refunding those
            // would re-fire `listTabs` every poll, forever, with no backoff —
            // the exact storm the cap exists to prevent.
            if Self.isDisconnectError(error),
               let spent = tabStateFetchAttempts[worktreeID], spent > 0 {
                tabStateFetchAttempts[worktreeID] = spent - 1
            }
            logger.error("loadTabStates failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            handleConnectionError(error)
        }
        // NOTE: the in-flight entry is cleared by the scheduler's own `Task`,
        // not here — this method is also called directly (initial load, tests),
        // and clearing from here would drop a marker belonging to a fetch that
        // is still running.
        //
        // Gated one-shot legacy panel import (spec C §11.2) — fires at most
        // once per launch regardless of whether this particular listTabs
        // call succeeded, since it imports from AppState's already-loaded
        // in-memory state, not from this call's response.
        triggerPanelImportIfNeeded()
    }

    // MARK: - Active tab persistence

    /// Update the in-memory active tab index for a worktree AND persist the
    /// underlying tab.id to the daemon. Use this anywhere the UI changes the
    /// active selection so the choice survives a restart. Also auto-wakes parked
    /// resumable terminals in the newly-activated tab, so the user sees them
    /// unfrozen when they click over.
    func setActiveTab(worktreeID: UUID, tabIndex: Int) {
        activeTabIndices[worktreeID] = tabIndex
        guard let arr = tabs[worktreeID], arr.indices.contains(tabIndex) else { return }
        // Activating a tab clears its unread-completion bold.
        unreadTerminals.subtract(terminalIDs(in: arr[tabIndex]))

        // Auto-wake parked terminals in the activated tab (the spawn-storm fix:
        // one terminal at a time, never a parallel fan-out).
        let toWake = terminalIDsToWakeOnTabActivation(worktreeID: worktreeID, tabIndex: tabIndex)
        Task {
            for terminalID in toWake {
                _ = await wakeTerminal(terminalID: terminalID, worktreeID: worktreeID, userInitiated: false)
            }
        }

        let tabID = arr[tabIndex].id
        Task {
            do {
                try await daemonClient.setActiveTab(worktreeID: worktreeID, tabID: tabID)
            } catch {
                logger.error("setActiveTab persist failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    /// Sort `tabs[worktreeID]` against `worktreeTabOrders[worktreeID]`. Unknown
    /// tab IDs (e.g. newly-created since last save) go to the end, preserving
    /// their current relative order.
    ///
    /// `anchor` says which tab the selection must follow. Callers that have just
    /// ADDED or REMOVED tabs pass `.pinned(id)` with the id they captured from
    /// the array BEFORE mutating it — including `.pinned(nil)` when there was no
    /// valid selection to capture. `.derive` reads the live array and is correct
    /// only for a pure reorder; using it after a mutation would read the
    /// already-mutated array, where the stored index has silently re-bound to
    /// whatever slid into that slot (with the note tab last, usually Notes).
    func applyStoredOrder(worktreeID: UUID, anchor: ActiveTabAnchor = .derive) {
        let followID: UUID?
        switch anchor {
        case .derive: followID = explicitActiveTabID(worktreeID: worktreeID)
        case .pinned(let id): followID = id
        }
        if let storedOrder = worktreeTabOrders[worktreeID], !storedOrder.isEmpty,
           let arr = tabs[worktreeID] {
            var storedIndex: [UUID: Int] = [:]
            var repairedOrder: [UUID] = []
            repairedOrder.reserveCapacity(storedOrder.count)
            for id in storedOrder where storedIndex[id] == nil {
                storedIndex[id] = repairedOrder.count
                repairedOrder.append(id)
            }
            if repairedOrder != storedOrder {
                let discardedCount = storedOrder.count - repairedOrder.count
                worktreeTabOrders[worktreeID] = repairedOrder
                logger.warning("Repaired duplicate tab order for \(worktreeID, privacy: .public); discarded \(discardedCount, privacy: .public) entries")
            }
            // Stable sort: known first (by stored position), unknown after (in input order).
            // Use enumerated original index as a tiebreaker so unknown tabs keep their input order.
            let withIndex = arr.enumerated().map { (origIdx: $0.offset, tab: $0.element) }
            let sorted = withIndex.sorted { a, b in
                switch (storedIndex[a.tab.id], storedIndex[b.tab.id]) {
                case let (ai?, bi?): return ai < bi
                case (_?, nil):      return true
                case (nil, _?):      return false
                case (nil, nil):     return a.origIdx < b.origIdx
                }
            }
            let reordered = sorted.map(\.tab)
            if arr != reordered {
                tabs[worktreeID] = reordered
            }
        }
        // Keep the active index pointing at the same tab.id — outside the sort
        // branch, because a caller that just mutated the array still needs the
        // re-point when nothing is persisted yet (the daemon writes tab order
        // after it inserts the terminal rows).
        repointActiveTab(worktreeID: worktreeID, to: followID)
    }

    // MARK: - Rename

    /// Rename a tab. Empty / whitespace-only string clears the override
    /// (tab reverts to auto-derived label). Same-as-displayed is a no-op.
    ///
    /// Synchronous so the in-memory label mutation and SwiftUI's exit-from-edit-mode
    /// re-render batch into a single frame — otherwise the tab briefly flashes the
    /// pre-rename label before the update lands. Persistence is fire-and-forget.
    func renameTab(tabID: UUID, worktreeID: UUID, newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        guard var arr = tabs[worktreeID],
              let idx = arr.firstIndex(where: { $0.id == tabID }) else { return }
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        // No-op if value is identical to what's stored.
        if arr[idx].label == newValue {
            return
        }
        arr[idx].label = newValue
        tabs[worktreeID] = arr
        Task {
            do {
                try await daemonClient.setTabLabel(tabID: tabID, worktreeID: worktreeID, label: newValue)
            } catch {
                logger.error("renameTab persist failed for \(tabID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    // MARK: - Close

    /// Close one tab and clean up resources owned by that tab. This is shared
    /// by the tab bar close button and the Cmd-W menu shortcut.
    func closeTab(worktreeID: UUID, index: Int) {
        guard var arr = tabs[worktreeID],
              arr.indices.contains(index) else { return }

        let tab = arr[index]

        // Closing a note tab hard-deletes the note row. Confirm first when
        // the note has content; an empty note closes silently as before.
        if case .note(let noteID) = tab.content,
           let note = notes[worktreeID]?.first(where: { $0.id == noteID }),
           !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !noteCloseConfirmer(note) {
            return
        }

        // Whether the tab being closed is the one on screen decides what the
        // selection does. Both captures must happen BEFORE the array is
        // mutated. Closing the ACTIVE tab moves the selection to whichever tab
        // takes its slot; closing a BACKGROUND tab must leave the user exactly
        // where they were. The call site used to clamp unconditionally, which
        // slid the selection one tab to the right on every background close —
        // onto the trailing note tab, which the resolver then honours as a
        // deliberate choice.
        let closingActiveTab = resolvedActiveTabIndex(worktreeID: worktreeID) == index
        let selectionToPreserve = closingActiveTab ? nil : explicitActiveTabID(worktreeID: worktreeID)

        let layout = layouts[tab.id] ?? .pane(tab.content)
        let terminalIDsInTab = Set(layout.allTerminalIDs())

        if focusedTabCloseContext?.worktreeID == worktreeID,
           focusedTabCloseContext?.tabID == tab.id {
            focusedTabCloseContext = nil
        }

        // Drop any pending unread-completion bold for this tab's terminals so a
        // background tab that completed and was closed without being activated
        // doesn't leak stale UUIDs into `unreadTerminals`.
        unreadTerminals.subtract(terminalIDsInTab)

        layouts.removeValue(forKey: tab.id)
        arr.remove(at: index)
        tabs[worktreeID] = arr
        worktreeTabOrders[worktreeID] = arr.map(\.id)
        prunePaneHistories()

        for terminalID in terminalIDsInTab {
            Task {
                await deleteTerminal(terminalID: terminalID, worktreeID: worktreeID)
            }
        }

        if case .note(let noteID) = tab.content {
            Task {
                await deleteNote(noteID: noteID, worktreeID: worktreeID)
            }
        }

        if closingActiveTab {
            if arr.isEmpty {
                activeTabIndices.removeValue(forKey: worktreeID)
            } else {
                activeTabIndices[worktreeID] = min(index, arr.count - 1)
            }
        } else {
            repointActiveTab(worktreeID: worktreeID, to: selectionToPreserve)
        }

        let snapshot = arr.map(\.id)
        Task {
            do {
                try await daemonClient.setTabOrder(worktreeID: worktreeID, tabIDs: snapshot)
            } catch {
                logger.error("closeTab persist order failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    func closeTab(worktreeID: UUID, tabID: UUID) {
        guard let arr = tabs[worktreeID],
              let index = arr.firstIndex(where: { $0.id == tabID }) else {
            if focusedTabCloseContext?.worktreeID == worktreeID,
               focusedTabCloseContext?.tabID == tabID {
                focusedTabCloseContext = nil
            }
            return
        }
        closeTab(worktreeID: worktreeID, index: index)
    }

    var canCloseFocusedTab: Bool {
        guard let context = resolvedFocusedTabCloseContext(),
              let arr = tabs[context.worktreeID] else { return false }
        return arr.contains(where: { $0.id == context.tabID })
    }

    func closeFocusedTab() {
        guard let context = resolvedFocusedTabCloseContext() else { return }
        closeTab(worktreeID: context.worktreeID, tabID: context.tabID)
    }

    // MARK: - Reorder

    /// Move `draggedID` to land next to `targetID`. `edge == .leading` inserts
    /// before the target; `.trailing` inserts after. Dropping a tab on itself
    /// is a no-op. Active selection follows the moved tab.
    func reorderTab(draggedID: UUID, in worktreeID: UUID,
                    relativeTo targetID: UUID, edge: DropEdge) {
        guard draggedID != targetID,
              var arr = tabs[worktreeID],
              let from = arr.firstIndex(where: { $0.id == draggedID }) else { return }
        // Capture which tab.id is currently active so we can re-point activeTabIndices.
        let activeID = explicitActiveTabID(worktreeID: worktreeID)
        let item = arr.remove(at: from)
        // Look up target's index *after* removal (it may have shifted left by 1).
        guard let targetIdx = arr.firstIndex(where: { $0.id == targetID }) else {
            // Target gone (rare race). Restore and bail.
            arr.insert(item, at: from)
            return
        }
        let insertAt = (edge == .trailing) ? targetIdx + 1 : targetIdx
        arr.insert(item, at: insertAt)
        tabs[worktreeID] = arr
        worktreeTabOrders[worktreeID] = arr.map(\.id)
        repointActiveTab(worktreeID: worktreeID, to: activeID)
        let snapshot = arr.map(\.id)
        Task {
            do {
                try await daemonClient.setTabOrder(worktreeID: worktreeID, tabIDs: snapshot)
            } catch {
                logger.error("reorderTab persist failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    // MARK: - PR tabs

    /// Where a request to show `url` should land: the index of the worktree's
    /// existing webview tab already on that URL, or nil when none is and a new
    /// tab has to be created.
    ///
    /// Pure and static so the reuse rule — the one thing that makes clicking
    /// the same PR twice idempotent instead of piling up duplicate tabs — can
    /// be asserted without a toolbar, a status bar, or a running app.
    nonisolated static func webviewTabIndex(in tabs: [TBDShared.Tab], showing url: URL) -> Int? {
        tabs.firstIndex {
            if case .webview(_, let tabURL) = $0.content { return tabURL == url }
            return false
        }
    }

    /// Open one bound PR: an in-app webview tab, reusing an existing tab for the
    /// same URL, or the default browser when ⌘ is held.
    ///
    /// The single entry point for the TOOLBAR's PR surfaces — the split
    /// button's primary action and its multi-PR dropdown rows — so those two
    /// cannot drift apart on which opens a tab and which shells out.
    ///
    /// The toolbar is the only in-app-tab surface, deliberately. The status-bar
    /// chips and the sidebar row indicator open the default browser directly
    /// (`NSWorkspace.shared.open`) and are not callers here: a click on the
    /// at-a-glance strip or on a sidebar glyph is a "take me to GitHub" gesture,
    /// while the toolbar control is where a PR gets parked as a tab in the
    /// worktree. That difference is a product decision, not an oversight.
    ///
    /// `inBrowser` defaults to the ⌘ state *at the call site* (default
    /// arguments are evaluated there), which keeps the modifier check next to
    /// the click that carries it and lets tests drive both arms without
    /// synthesizing an `NSEvent` — or launching a browser.
    func openPR(
        url: URL,
        number: Int,
        worktreeID: UUID,
        inBrowser: Bool = NSEvent.modifierFlags.contains(.command)
    ) {
        if inBrowser {
            NSWorkspace.shared.open(url)
            return
        }
        if let existingIndex = Self.webviewTabIndex(in: tabs[worktreeID] ?? [], showing: url) {
            activeTabIndices[worktreeID] = existingIndex
        } else {
            let tab = TBDShared.Tab(
                id: UUID(),
                content: .webview(id: UUID(), url: url),
                label: "PR #\(number)"
            )
            tabs[worktreeID, default: []].append(tab)
            activeTabIndices[worktreeID] = (tabs[worktreeID]?.count ?? 1) - 1
        }
    }
}
