import AppKit

/// What the pointer is over in the native sidebar, from one tracking area on
/// the outline (spec "Hover").
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
/// The 80 ms wait runs on the injected clock.
@MainActor
final class SidebarHoverTracker: NSResponder {
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
    private weak var outline: NSOutlineView?
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

    init(
        outline: NSOutlineView,
        onChange: @escaping (State) -> Void,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.outline = outline
        self.onChange = onChange
        self.clock = clock
        super.init()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        outline.addTrackingArea(area)
        trackingArea = area
        if let clip = outline.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewScrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A tracking area does not retain its owner, so one left behind on an
    /// outline that outlives the tracker would message a freed object. The
    /// tracker is made and released on the main thread — by the outline that
    /// holds it, or by a test.
    deinit {
        MainActor.assumeIsolated { invalidate() }
    }

    /// Takes the tracking area off the outline, stops listening for scrolls
    /// and cancels pending debounces. Idempotent.
    func invalidate() {
        if let trackingArea {
            outline?.removeTrackingArea(trackingArea)
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

    /// The pointer is at `point` in the outline's window.
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
        guard let outline, outline.window != nil, let windowPoint else { return (nil, .none, nil, nil) }
        let point = outline.convert(windowPoint, from: nil)
        guard outline.visibleRect.contains(point) else { return (nil, .none, nil, nil) }
        let index = outline.row(at: point)
        guard index >= 0, let item = outline.item(atRow: index) as? SidebarItem else { return (nil, .none, nil, nil) }

        var part = SidebarHoverPart.none
        if let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSView & SidebarHoverTarget {
            part = cell.hoverPart(at: cell.convert(point, from: outline))
        }

        var top: Any = item
        while let parent = outline.parent(forItem: top) { top = parent }
        let header = (top as? SidebarItem)?.id

        var section: SidebarNodeID?
        switch item.id {
        case .repoHeader:
            section = item.id
        case .worktree, .remoteSession:
            if case .repoHeader? = header { section = header }
        case .scratchHeader, .scratchPrompt, .providerHeader, .group:
            break
        }
        let scratch: SidebarNodeID? = item.id == .scratchHeader ? item.id : nil
        return (item.id, part, section, scratch)
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
