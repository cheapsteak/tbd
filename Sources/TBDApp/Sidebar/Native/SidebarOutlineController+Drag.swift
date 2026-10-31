import AppKit
import os
import TBDShared

private let dragLogger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// What a drop asks `AppState.moveWorktrees(ids:newParentID:before:)` to do.
struct SidebarDropMove: Equatable {
    /// The carried rows, in top-to-bottom tree order.
    let ids: [UUID]
    /// nil: the top level of the rows' own group.
    let newParentID: UUID?
    /// nil: the end of the destination group.
    let before: UUID?
}

/// Drag and drop in the native sidebar (spec "Drag and drop"): which rows a
/// drag carries, what a drop proposal means, the feedback drawn for it, and
/// the move a drop makes.
///
/// - **Source.** `SidebarOutlineView.canDragRows(with:at:)` records the
///   mouse-down row. AppKit then asks for a writer for every selected row, or
///   for the pressed row alone, and the writer hands out one
///   `NSPasteboardItem` per row `SidebarDropPolicy.carried` names: the main
///   row, unadopted remote sessions, headers, a row of the other kind than the
///   pressed one and a selected row whose ancestor is also selected get none.
///   An unselected row never loses its writer to a selected ancestor, so a
///   child of a selected parent still drags.
/// - **Session.** From `willBeginAt` to `endedAt` the structure is held and
///   nothing expands. `endedAt` lifts the expansion veto first, then ends the
///   hold, which applies the held structure at once.
/// - **Destination.** `validateDrop` asks the policy, retargets only when its
///   answer differs from the proposal, and draws the nest highlight or the
///   insertion line. `acceptDrop` checks the decision against a fresh build
///   of `AppState` and hands it to `moveWorktrees`. The drop never sets
///   `animatesToDestination`: the rows are not in place until the hold ends.
extension SidebarOutlineController {
    // MARK: Setup

    func installDragAndDrop() {
        // The dock registers a type of its own, so rows never cross between
        // the dock and the list.
        outline.registerForDraggedTypes([.tbdSidebarWorktrees])
        // Rows move within the sidebar and never leave the app.
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        // After the selection highlight style, which can reset it. The
        // controller draws both indicators from the policy's answer.
        outline.draggingDestinationFeedbackStyle = .none
        outline.onDropFeedbackEnded = { [weak self] in self?.clearDropFeedback() }
    }

    // MARK: Source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? SidebarItem, item !== Self.orphan,
              case .worktree(let worktreeID) = item.id, let origin = dragOriginID else { return nil }
        let carried = SidebarDropPolicy.carried(selection: selectedNodeIDs, origin: origin, index: dropIndex)
        guard carried.contains(worktreeID) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(worktreeID.uuidString, forType: .tbdSidebarWorktrees)
        return pasteboardItem
    }

    /// The row the drag's mouse-down landed on; the clicked row if AppKit
    /// asked for writers before `canDragRows(with:at:)` recorded it.
    private var dragOriginID: SidebarNodeID? {
        if let origin = outline.dragOrigin { return origin }
        let row = outline.clickedRow
        return row >= 0 ? (outline.item(atRow: row) as? SidebarItem)?.id : nil
    }

    /// The selected rows, top to bottom.
    private var selectedNodeIDs: [SidebarNodeID] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
    }

    // MARK: Session

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        isDragSessionActive = true
        // Clears the hover too: nothing is hovered under a drag.
        beginHold(.drag)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The veto lifts first: the held structure about to replay expands
        // rows, and the veto refuses the controller's own `expandItem`.
        isDragSessionActive = false
        outline.dragOrigin = nil
        dropPayloadCache = nil
        clearDropFeedback()
        // The last hold ending applies the held structure now, not on the
        // next main-loop turn, so a drop's rows land as the drag ends.
        endHold(.drag)
    }

    // MARK: Destination

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard isProposable(item), let carried = cachedPayload(of: info) else {
            clearDropFeedback()
            return []
        }
        let proposal: SidebarDropPolicy.Retarget = ((item as? SidebarItem)?.id, index)
        let answer = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: proposal.parent, childIndex: proposal.childIndex,
            pointerDepth: pointerDepth(of: info), index: dropIndex)
        if case .reject = answer.decision {
            clearDropFeedback()
            return []
        }
        var shown = proposal
        if let retarget = answer.retarget {
            let parentItem = retarget.parent.flatMap { items.existing($0) }
            // A parent the outline has made no item for cannot be shown.
            if retarget.parent != nil, parentItem == nil {
                clearDropFeedback()
                return []
            }
            outline.setDropItem(parentItem, dropChildIndex: retarget.childIndex)
            shown = retarget
        }
        showDropFeedback(answer.decision, at: shown)
        return .move
    }

    /// The drop: the decision `validateDrop` showed, checked against
    /// `AppState` as it stands now, goes to `moveWorktrees`. A nest becomes
    /// `newParentID: id, before: nil`; a place maps field for field.
    ///
    /// AppKit hands over the position `validateDrop` last showed, retargets
    /// included, so the pointer is not read again: the gap's depth is pinned
    /// to the proposed parent's children, which names exactly that position.
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        defer { clearDropFeedback() }
        guard isProposable(item),
              let carried = Self.dragPayload(from: info.draggingPasteboard)?.worktreeIDs else { return false }
        let proposal: SidebarDropPolicy.Retarget = ((item as? SidebarItem)?.id, index)
        let pinnedDepth = proposal.parent.flatMap { dropIndex.entry($0)?.level } ?? 0
        let shown = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: proposal.parent, childIndex: proposal.childIndex,
            pointerDepth: pinnedDepth, index: dropIndex)
        if case .reject = shown.decision { return false }
        guard let move = confirmedMove(shown.decision, at: shown.retarget ?? proposal, carried: carried) else {
            dragLogger.info(
                "Native sidebar drop of \(carried.count, privacy: .public) row(s) rejected: the rows or the destination changed during the drag")
            return false
        }
        appState.moveWorktrees(ids: move.ids, newParentID: move.newParentID, before: move.before)
        return true
    }

    /// The move `decision` makes, checked against a fresh build of
    /// `AppState`; nil when the drop must not go ahead.
    ///
    /// A drag holds the shown structure, so a row the daemon archived during
    /// the drag is still in the shown tree. The decision's destination is
    /// therefore pinned by ID — the nest target, or the parent and the row
    /// the rows go before — and asked of the current tree; the drop goes
    /// ahead only when the answer there is the same decision. A carried row
    /// or a destination that left, or a destination that no longer takes the
    /// rows, rejects it, and nothing moves.
    func confirmedMove(_ decision: SidebarDropDecision, at position: SidebarDropPolicy.Retarget,
                       carried: [UUID]) -> SidebarDropMove? {
        let current = SidebarDropIndex(tree: currentTree())
        guard let anchor = Self.anchor(of: decision, at: position, in: current) else { return nil }
        let answer = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: anchor.parent, childIndex: anchor.childIndex,
            pointerDepth: anchor.depth, index: current)
        guard answer.decision == decision, let ordered = Self.treeOrder(carried, in: current) else { return nil }
        switch decision {
        case .nest(let parent):
            return SidebarDropMove(ids: ordered, newParentID: parent, before: nil)
        case .place(let parent, let before):
            return SidebarDropMove(ids: ordered, newParentID: parent, before: before)
        case .reject:
            return nil
        }
    }

    /// The proposal that names `decision`'s destination in `index`'s tree:
    /// onto the nest target, or the gap before `before` — the end of the
    /// worktree rows when there is none — under the shown position's parent.
    /// The depth is that parent's children's own, which pins the gap to it:
    /// neither into the subtree above the gap nor out to a shallower level.
    private static func anchor(of decision: SidebarDropDecision, at position: SidebarDropPolicy.Retarget,
                               in index: SidebarDropIndex) -> (parent: SidebarNodeID, childIndex: Int, depth: Int)? {
        switch decision {
        case .reject:
            return nil
        case .nest(let target):
            return (SidebarNodeID.worktree(target), SidebarDropPolicy.dropOnItemIndex, 0)
        case .place(_, let before):
            guard let parentID = position.parent, let entry = index.entry(parentID) else { return nil }
            let childIndex: Int
            if let before {
                guard let found = entry.node.children.firstIndex(where: { $0.id == .worktree(before) }) else {
                    return nil
                }
                childIndex = found
            } else {
                childIndex = entry.rowGaps.upperBound
            }
            return (parentID, childIndex, entry.level)
        }
    }

    /// `ids` in top-to-bottom tree order, each once; nil when the tree lacks
    /// one.
    static func treeOrder(_ ids: [UUID], in index: SidebarDropIndex) -> [UUID]? {
        var seen: Set<UUID> = []
        var placed: [(id: UUID, path: [Int])] = []
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            guard let path = index.path(to: .worktree(id)) else { return nil }
            placed.append((id: id, path: path))
        }
        return placed.sorted { $0.path.lexicographicallyPrecedes($1.path) }.map { $0.id }
    }

    /// Whether a proposal's item is the roots (nil) or one of the outline's.
    private func isProposable(_ item: Any?) -> Bool {
        guard let item else { return true }
        guard let sidebarItem = item as? SidebarItem else { return false }
        return sidebarItem !== Self.orphan
    }

    // MARK: Payload

    /// The rows a drag carries: the ID in every pasteboard item under the
    /// sidebar's type, in pasteboard order, each once. Every item is read —
    /// `propertyList(forType:)` would read only the first. Nil when there is
    /// none, as for the dock's own type.
    static func dragPayload(from pasteboard: NSPasteboard) -> SidebarDragPayload? {
        var seen: Set<UUID> = []
        var ids: [UUID] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let string = item.string(forType: .tbdSidebarWorktrees),
                  let id = UUID(uuidString: string), seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids.isEmpty ? nil : SidebarDragPayload(worktreeIDs: ids)
    }

    /// `dragPayload`, read once per drag: `validateDrop` runs on every
    /// pointer move.
    private func cachedPayload(of info: any NSDraggingInfo) -> [UUID]? {
        let sequence = info.draggingSequenceNumber
        if let cache = dropPayloadCache, cache.sequence == sequence {
            return cache.ids.isEmpty ? nil : cache.ids
        }
        let ids = Self.dragPayload(from: info.draggingPasteboard)?.worktreeIDs ?? []
        dropPayloadCache = (sequence: sequence, ids: ids)
        return ids.isEmpty ? nil : ids
    }

    // MARK: Pointer

    /// The visual depth the pointer names, counted from where a depth-0
    /// row's content starts.
    func pointerDepth(of info: any NSDraggingInfo) -> Int {
        let point = outline.convert(info.draggingLocation, from: nil)
        return SidebarDropPolicy.pointerDepth(x: point.x, inset: dropDepthInset)
    }

    /// Where a depth-0 row's content starts, in the outline's coordinates:
    /// the column's edge plus the row inset every row under a section title
    /// carries.
    var dropDepthInset: CGFloat {
        let columnX = outline.numberOfColumns > 0 ? outline.rect(ofColumn: 0).minX : 0
        return columnX + SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: chevronBeforeTitle)
    }

    // MARK: Feedback

    /// A nest highlights its target row; a place draws the insertion line at
    /// `position`.
    private func showDropFeedback(_ decision: SidebarDropDecision, at position: SidebarDropPolicy.Retarget) {
        switch decision {
        case .nest(let target):
            dropIndicator.hide()
            setNestTarget(.worktree(target))
        case .place:
            setNestTarget(nil)
            if let line = insertionLine(at: position) {
                dropIndicator.show(line)
            } else {
                dropIndicator.hide()
            }
        case .reject:
            clearDropFeedback()
        }
    }

    /// Takes down the insertion line and the nest highlight: a rejected
    /// proposal, and a drag that left the outline, concluded or ended.
    func clearDropFeedback() {
        dropIndicator.hide()
        setNestTarget(nil)
    }

    /// Moves the nest highlight. A row view made later takes it from
    /// `nestTargetID` when it is configured.
    private func setNestTarget(_ id: SidebarNodeID?) {
        guard id != nestTargetID else { return }
        let previous = nestTargetID
        nestTargetID = id
        for changed in [previous, id].compactMap({ $0 }) {
            guard let item = items.existing(changed), let node = tree.node(changed) else { continue }
            let row = outline.row(forItem: item)
            guard row >= 0, let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView
            else { continue }
            configure(rowView, node: node)
        }
    }

    /// The insertion line for rows landing at child `position.childIndex` of
    /// `position.parent`, in the indicator's coordinates: across the top of
    /// the row now at that index, or under the last row the outline shows
    /// above the gap. It starts on the parent's guide line, one indentation
    /// step per level of the children's visual depth.
    private func insertionLine(at position: SidebarDropPolicy.Retarget) -> SidebarDropIndicatorView.Line? {
        guard let parentID = position.parent, let entry = dropIndex.entry(parentID) else { return nil }
        let children = entry.node.showsChildren ? entry.node.children : []
        let childIndex = position.childIndex
        guard childIndex >= 0, childIndex <= children.count else { return nil }
        let y: CGFloat
        if childIndex < children.count {
            guard let rect = rowRect(children[childIndex].id) else { return nil }
            y = rect.minY
        } else {
            let above = childIndex > 0 ? Self.lastShown(in: children[childIndex - 1]) : entry.node
            guard let rect = rowRect(above.id) else { return nil }
            y = rect.maxY
        }
        // The children's visual depth is the parent's outline level.
        let x = dropDepthInset + CGFloat(entry.level) * SidebarNativeMetrics.indentation
            - SidebarNativeMetrics.guideLineOffset
        let point = dropIndicator.convert(NSPoint(x: x, y: y), from: outline)
        return SidebarDropIndicatorView.Line(x: point.x, y: point.y)
    }

    /// The last row the outline shows in `node`'s subtree.
    private static func lastShown(in node: SidebarNode) -> SidebarNode {
        var current = node
        while current.showsChildren, let last = current.children.last {
            current = last
        }
        return current
    }

    /// The outline's rect for `id`'s row, when it shows one.
    private func rowRect(_ id: SidebarNodeID) -> NSRect? {
        guard let item = items.existing(id) else { return nil }
        let row = outline.row(forItem: item)
        return row >= 0 ? outline.rect(ofRow: row) : nil
    }
}
