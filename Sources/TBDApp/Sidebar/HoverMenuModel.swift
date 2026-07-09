import SwiftUI

/// Drives the hover-to-open worktree menu shared by the repo `+`
/// (`RepoSectionView`) and the per-row nested `+` (`WorktreeRowView`).
///
/// Owns two timings: a hover-intent delay before opening (so scrubbing the
/// pointer across the sidebar doesn't flash menus open) and a close grace that
/// bridges the pixel gap between the `+` button and its `.popover`. The popover
/// renders in a separate window, so moving the pointer into it flips the
/// button's `onHover` to false; the grace, plus a second `onHover` on the
/// popover content (`menuHover`), keeps the menu open while the pointer is over
/// EITHER surface.
@MainActor
final class HoverMenuModel: ObservableObject {
    @Published private(set) var isOpen = false

    private var overTrigger = false
    private var overMenu = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    private let openDelay: Duration
    private let closeGrace: Duration

    init(openDelay: Duration = .milliseconds(200), closeGrace: Duration = .milliseconds(100)) {
        self.openDelay = openDelay
        self.closeGrace = closeGrace
    }

    private var pointerInside: Bool { overTrigger || overMenu }

    /// Pointer entered/left the `+` button.
    func triggerHover(_ inside: Bool) {
        overTrigger = inside
        reconcile()
    }

    /// Pointer entered/left the popover content.
    func menuHover(_ inside: Bool) {
        overMenu = inside
        reconcile()
    }

    /// ⌥-click: open immediately, skipping the hover-intent delay.
    func openImmediately() {
        cancelTasks()
        isOpen = true
    }

    /// A row was chosen, or the popover was dismissed by an outside click.
    func closeNow() {
        cancelTasks()
        overTrigger = false
        overMenu = false
        isOpen = false
    }

    /// Binding for `.popover(isPresented:)`. SwiftUI sets it false on an outside
    /// click or `dismiss()`; we route that through `closeNow()`. We never drive
    /// it true from here (opening happens via the hover/⌥-click methods).
    var isOpenBinding: Binding<Bool> {
        Binding(get: { self.isOpen }, set: { newValue in if !newValue { self.closeNow() } })
    }

    private func cancelTasks() {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
    }

    private func reconcile() {
        if pointerInside {
            closeTask?.cancel(); closeTask = nil
            guard !isOpen, openTask == nil else { return }
            openTask = Task { [weak self] in
                try? await Task.sleep(for: self?.openDelay ?? .zero)
                guard let self else { return }
                self.openTask = nil
                guard !Task.isCancelled, self.pointerInside else { return }
                self.isOpen = true
            }
        } else {
            openTask?.cancel(); openTask = nil
            guard isOpen, closeTask == nil else { return }
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: self?.closeGrace ?? .zero)
                guard let self else { return }
                self.closeTask = nil
                guard !Task.isCancelled, !self.pointerInside else { return }
                self.isOpen = false
            }
        }
    }

    // MARK: - Pure decision helpers (unit-tested; document the gating branches)

    enum PlusButtonOutcome: Equatable {
        case createDefault  // plain click
        case openMenu       // ⌥-click
    }

    /// A plain click on the `+` creates a default worktree; ⌥-click opens the
    /// profile-picker menu without waiting for the hover-intent delay.
    static func plusOutcome(optionHeld: Bool) -> PlusButtonOutcome {
        optionHeld ? .openMenu : .createDefault
    }

    /// The `+` shows while its section/row is hovered OR its menu is open — so
    /// moving the pointer into the popover (which drops the row/section hover)
    /// doesn't unmount the popover's own anchor and slam it shut.
    static func shouldShowPlus(hovered: Bool, menuOpen: Bool) -> Bool {
        hovered || menuOpen
    }

    // MARK: - Testing

    /// Await any in-flight open/close transition so tests can assert final state
    /// deterministically. Construct the model with `.zero` delays first.
    func _drainForTesting() async {
        await openTask?.value
        await closeTask?.value
    }
}
