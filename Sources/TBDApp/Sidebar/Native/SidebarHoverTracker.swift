import AppKit

/// What the pointer is over in the native sidebar, from one tracking area on
/// a list — the outline, or the pinned dock (spec "Hover").
///
/// It answers three things the SwiftUI rows each learned from their own
/// `onHover`:
/// - **the hovered row**, and the control or glyph inside it (`part`), which
///   the hovered cell reports through `SidebarHoverTarget`;
/// - **the revealed sections**, whose header shows its `+` and trailing
///   chevron. A repo section is revealed while the pointer is over its header
///   or any of its worktree and session rows, as `RepoSectionView`'s
///   `onSectionHoverChange` gathers them, and stays revealed for 80 ms after
///   the pointer leaves, its debounce; moving straight into another section
///   reveals that one at once, so for those 80 ms both are. The Scratch
///   section is revealed only while its header itself is hovered, with no
///   delay, as `ScratchSectionView` gates its `+`.
///
/// A tracking area gets no exit event when content scrolls under a still
/// pointer, so the pointer's last window position is kept and the hovered row
/// is recomputed from it on every clip-view scroll and after every apply
/// (`recompute()`); a drag clears it (`clear()`). Those recomputes always
/// report, so the owner can re-anchor what follows the row; pointer moves
/// report only a change.
///
/// The list says what each row is through a resolver: the row's ID and its
/// section, so the tracker needs to know nothing of outline items. The dock's
/// rows sit in no section, so it reveals no header.
///
/// The 80 ms wait runs on the injected clock.
@MainActor
final class SidebarHoverTracker: NSResponder {
    /// A row as the tracker sees it: its ID, and `section`, the top-level row
    /// it sits under — its section's header, or the row itself when it is
    /// one — nil in a list without sections. Nil for a row with no ID.
    typealias RowResolver = (Int) -> (id: SidebarNodeID, section: SidebarNodeID?)?

    struct State: Equatable {
        var row: SidebarNodeID?
        var part: SidebarHoverPart = .none
        var revealedSections: Set<SidebarNodeID> = []

        /// The section whose rows dim to 0.7 while its chevron is hovered.
        var dimmedSection: SidebarNodeID? { part == .chevron ? row : nil }
    }

    /// `RepoSectionView`'s hover-out debounce.
    static let sectionLinger: Duration = .milliseconds(80)

    private(set) var state = State()
    private weak var table: NSTableView?
    private let resolve: RowResolver
    private let onChange: (State) -> Void
    private let clock: any Clock<Duration>
    private var trackingArea: NSTrackingArea?
    /// The pointer's last position, in window coordinates; nil once it left.
    private var windowPoint: NSPoint?
    /// The repo section under the pointer.
    private var currentSection: SidebarNodeID?
    /// Repo sections the pointer left less than 80 ms ago, each with the
    /// token of the wait that will hide it.
    private var lingering: [SidebarNodeID: (token: Int, task: Task<Void, Never>)] = [:]
    private var lingerToken = 0

    /// - Parameters:
    ///   - table: the list, already the document view of its scroll view.
    ///   - resolve: what each of `table`'s rows is. Called on every pointer
    ///     move, so it must be cheap.
    init(
        table: NSTableView,
        resolve: @escaping RowResolver,
        onChange: @escaping (State) -> Void,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.table = table
        self.resolve = resolve
        self.onChange = onChange
        self.clock = clock
        super.init()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        table.addTrackingArea(area)
        trackingArea = area
        if let clip = table.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewScrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    /// The outline's tracker: each row's section is its top-level ancestor,
    /// found by walking the outline's parents.
    convenience init(
        outline: NSOutlineView,
        onChange: @escaping (State) -> Void,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(
            table: outline,
            resolve: { [weak outline] row in
                guard let outline, let item = outline.item(atRow: row) as? SidebarItem else { return nil }
                var top: Any = item
                while let parent = outline.parent(forItem: top) { top = parent }
                return (id: item.id, section: (top as? SidebarItem)?.id)
            },
            onChange: onChange,
            clock: clock)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A tracking area does not retain its owner, so one left behind on a
    /// list that outlives the tracker would message a freed object. The
    /// tracker is made and released on the main thread — by the list that
    /// holds it, or by a test.
    deinit {
        MainActor.assumeIsolated { invalidate() }
    }

    /// Takes the tracking area off the list, stops listening for scrolls
    /// and cancels pending debounces. Idempotent.
    func invalidate() {
        if let trackingArea {
            table?.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        for entry in lingering.values { entry.task.cancel() }
        lingering.removeAll()
    }

    // MARK: Events

    override func mouseEntered(with event: NSEvent) {
        pointerMoved(toWindowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(toWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        pointerExited()
    }

    @objc private func clipViewScrolled(_ notification: Notification) {
        recompute()
    }

    /// The pointer is at `point` in the list's window.
    func pointerMoved(toWindowPoint point: NSPoint) {
        windowPoint = point
        update(force: false)
    }

    func pointerExited() {
        windowPoint = nil
        update(force: false)
    }

    /// The rows moved under a still pointer: a scroll or an apply.
    func recompute() {
        update(force: true)
    }

    /// A drag started: nothing is hovered until the pointer moves again.
    func clear() {
        windowPoint = nil
        currentSection = nil
        for entry in lingering.values { entry.task.cancel() }
        lingering.removeAll()
        update(force: true)
    }

    // MARK: Computing the state

    private func update(force: Bool) {
        let (row, part, section, scratch) = hitTest()
        if section != currentSection {
            if let old = currentSection { beginLinger(old) }
            if let section { endLinger(section) }
            currentSection = section
        }
        var revealed = Set(lingering.keys)
        if let section = currentSection { revealed.insert(section) }
        if let scratch { revealed.insert(scratch) }
        publish(State(row: row, part: part, revealedSections: revealed), force: force)
    }

    private func publish(_ new: State, force: Bool) {
        guard force || new != state else { return }
        state = new
        onChange(new)
    }

    /// The row under the pointer, the part of it, the repo section it
    /// reveals, and the Scratch header when that is the row.
    private func hitTest() -> (SidebarNodeID?, SidebarHoverPart, SidebarNodeID?, SidebarNodeID?) {
        guard let table, table.window != nil, let windowPoint else { return (nil, .none, nil, nil) }
        let point = table.convert(windowPoint, from: nil)
        guard table.visibleRect.contains(point) else { return (nil, .none, nil, nil) }
        let index = table.row(at: point)
        guard index >= 0, let row = resolve(index) else { return (nil, .none, nil, nil) }

        var part = SidebarHoverPart.none
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSView & SidebarHoverTarget {
            part = cell.hoverPart(at: cell.convert(point, from: table))
        }

        var section: SidebarNodeID?
        switch row.id {
        case .repoHeader:
            section = row.id
        case .worktree, .remoteSession:
            if case .repoHeader? = row.section { section = row.section }
        case .scratchHeader, .scratchPrompt, .providerHeader, .group:
            break
        }
        let scratch: SidebarNodeID? = row.id == .scratchHeader ? row.id : nil
        return (row.id, part, section, scratch)
    }

    // MARK: The 80 ms debounce

    private func beginLinger(_ id: SidebarNodeID) {
        lingering[id]?.task.cancel()
        lingerToken += 1
        let token = lingerToken
        let clock = self.clock
        let linger = Self.sectionLinger
        let task = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: linger)
            } catch {
                return
            }
            self?.lingerEnded(id, token: token)
        }
        lingering[id] = (token: token, task: task)
    }

    private func endLinger(_ id: SidebarNodeID) {
        lingering.removeValue(forKey: id)?.task.cancel()
    }

    private func lingerEnded(_ id: SidebarNodeID, token: Int) {
        guard lingering[id]?.token == token else { return }
        lingering[id] = nil
        update(force: false)
    }
}
