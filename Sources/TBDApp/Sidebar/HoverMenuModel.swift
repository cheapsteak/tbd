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

    @Published private(set) var isTriggerHovered = false
    private var overMenu = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    // Monotonic counters let a task's continuation verify — after its
    // `Task.sleep` resumes — that it is still the current open/close task
    // before nil-ing the ivar. Without this, a cancelled task whose
    // continuation resumes after a newer task has already been assigned to
    // the same ivar would nil out that newer, still-live task.
    private var openTaskGeneration = 0
    private var closeTaskGeneration = 0

    private let openDelay: Duration
    private let closeGrace: Duration

    init(openDelay: Duration = .milliseconds(400), closeGrace: Duration = .milliseconds(100)) {
        self.openDelay = openDelay
        self.closeGrace = closeGrace
    }

    private var pointerInside: Bool { isTriggerHovered || overMenu }

    /// Pointer entered/left the `+` button.
    func triggerHover(_ inside: Bool) {
        isTriggerHovered = inside
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
        setOpen(true)
    }

    /// A row was chosen, or the popover was dismissed by an outside click.
    func closeNow() {
        cancelTasks()
        isTriggerHovered = false
        overMenu = false
        setOpen(false)
    }

    /// Flip `isOpen` without the popover's present/dismiss animation — the menu
    /// should snap in and out, not fade/scale. SwiftUI's `.popover` (AppKit
    /// `NSPopover`) animates by default; a transaction with `disablesAnimations`
    /// around the state change is the public lever to turn that off.
    private func setOpen(_ value: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isOpen = value }
    }

    private func cancelTasks() {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
    }

    private func reconcile() {
        if pointerInside {
            closeTask?.cancel(); closeTask = nil
            guard !isOpen, openTask == nil else { return }
            openTaskGeneration += 1
            let generation = openTaskGeneration
            openTask = Task { [weak self] in
                // swiftlint:disable:next no_raw_task_sleep - already seamed: `openDelay` is an `init(openDelay:closeGrace:)` parameter and `_drainForTesting()` joins the in-flight task, exercised by Tests/TBDAppTests/HoverMenuModelTests.swift at .zero; see docs/specs/2026-07-24-test-hardening-design.md
                try? await Task.sleep(for: self?.openDelay ?? .zero)
                guard let self else { return }
                if self.openTaskGeneration == generation { self.openTask = nil }
                guard !Task.isCancelled, self.pointerInside else { return }
                self.setOpen(true)
            }
        } else {
            openTask?.cancel(); openTask = nil
            guard isOpen, closeTask == nil else { return }
            closeTaskGeneration += 1
            let generation = closeTaskGeneration
            closeTask = Task { [weak self] in
                // swiftlint:disable:next no_raw_task_sleep - already seamed: `closeGrace` is an `init(openDelay:closeGrace:)` parameter and `_drainForTesting()` joins the in-flight task, exercised by Tests/TBDAppTests/HoverMenuModelTests.swift at .zero; see docs/specs/2026-07-24-test-hardening-design.md
                try? await Task.sleep(for: self?.closeGrace ?? .zero)
                guard let self else { return }
                if self.closeTaskGeneration == generation { self.closeTask = nil }
                guard !Task.isCancelled, !self.pointerInside else { return }
                self.setOpen(false)
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
