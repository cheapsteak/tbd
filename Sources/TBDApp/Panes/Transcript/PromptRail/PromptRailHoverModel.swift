import AppKit
import Observation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// Opens and closes the prompt rail's card. Both renderers feed it hover and
/// read it back: the SwiftUI card reads `isOpen`, the AppKit card listens on
/// `onOpenChange`.
///
/// - **Opening** – `openDelay` after the pointer enters the rail, so sweeping
///   the pointer across the pane's edge does not flash the card open.
/// - **Closing** – `closeGrace` after the pointer has left both the rail and
///   the card. The grace bridges the move from rail to card, and a jittery
///   pointer, without snapping the card shut.
/// - **Dismissal** – Escape and a row click close the card at once. While the
///   pointer stays on the rail the card does not reopen: hovering the rail is
///   what opened it, so without the suppression it would reopen `openDelay`
///   after being dismissed. Leaving the rail lifts the suppression.
/// - **App deactivation** – closes the card at once. `.onHover` and
///   `NSTrackingArea` are active-app concepts: Cmd-Tab moves no pointer, so no
///   exit event arrives and hover alone would leave the card up.
///
/// The timers sleep on the injected `clock` and are cancel-and-replace, so a
/// test drives them in virtual time.
@MainActor
@Observable
final class PromptRailHoverModel {
    enum Dismissal: String {
        case escape
        case click
    }

    private(set) var isOpen = false

    /// Called on every change of `isOpen`, and only on a change. The AppKit
    /// renderer's hook; the SwiftUI renderer observes `isOpen` instead.
    @ObservationIgnored var onOpenChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private var isRailHovered = false
    @ObservationIgnored private var isCardHovered = false
    /// Set by `dismiss` while the pointer is on the rail; cleared when it
    /// leaves. While set, rail hover does not open the card.
    @ObservationIgnored private var suppressed = false

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    // Monotonic counters let a task verify, after its sleep resumes, that it
    // is still the current open/close task before nil-ing the ivar. Without
    // them a cancelled task resuming after a newer task was assigned would nil
    // out the newer, still-live one.
    @ObservationIgnored private var openTaskGeneration = 0
    @ObservationIgnored private var closeTaskGeneration = 0

    private let openDelay: Duration
    private let closeGrace: Duration
    private let clock: any Clock<Duration>

    // NotificationCenter is Sendable and this is an immutable `let`, so deinit
    // (nonisolated under Swift 6) can read it without hopping.
    private let notificationCenter: NotificationCenter
    // nonisolated(unsafe): written in `init` on the main actor and read in
    // `deinit`, which is nonisolated and runs wherever ARC drops the last
    // strong reference. What keeps that single-threaded is an ownership
    // invariant, not a language guarantee: the renderers own the model from
    // the main actor (a SwiftUI `@State`, an AppKit view), and release it
    // there. Releasing it off the main actor would break that. Same precedent,
    // and same caveat, as `HoverMenuModel`.
    @ObservationIgnored nonisolated(unsafe) private var deactivationObserver: (any NSObjectProtocol)?

    /// The notification center is injected so tests can post
    /// `NSApplication.didResignActiveNotification` without disturbing
    /// `.default` and every other observer in the test process.
    init(
        openDelay: Duration = .milliseconds(80),
        closeGrace: Duration = .milliseconds(100),
        notificationCenter: NotificationCenter = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.openDelay = openDelay
        self.closeGrace = closeGrace
        self.notificationCenter = notificationCenter
        self.clock = clock
        deactivationObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeNow()
            }
        }
    }

    deinit {
        if let deactivationObserver {
            notificationCenter.removeObserver(deactivationObserver)
        }
    }

    /// The pointer entered or left the rail. The rail is its whole column,
    /// including the part the open card covers: the card's dash column sits
    /// over the rail's notches, and a pointer there is still on the rail for
    /// Escape and click suppression.
    func railHoverChanged(_ hovering: Bool) {
        isRailHovered = hovering
        if !hovering { suppressed = false }
        reconcile()
    }

    /// The pointer entered or left the card.
    func cardHoverChanged(_ hovering: Bool) {
        isCardHovered = hovering
        reconcile()
    }

    /// Escape or a row click: close now, and suppress reopening while the
    /// pointer stays on the rail.
    func dismiss(_ reason: Dismissal) {
        logger.debug("card dismissed by \(reason.rawValue, privacy: .public)")
        cancelTasks()
        // The card is gone, so the pointer is no longer over it. A hidden view
        // sends no exit event, and a stale flag would keep the next card open
        // after the pointer leaves the rail.
        isCardHovered = false
        suppressed = isRailHovered
        setOpen(false)
    }

    /// Close at once and forget the hover state: app deactivation, teardown.
    /// No exit events follow a deactivation, so the flags are cleared rather
    /// than trusted; a stale one would let the next hover event of any kind
    /// reopen the card from it.
    func closeNow() {
        cancelTasks()
        isRailHovered = false
        isCardHovered = false
        suppressed = false
        setOpen(false)
    }

    private func setOpen(_ value: Bool) {
        guard isOpen != value else { return }
        isOpen = value
        logger.debug("card \(value ? "opened" : "closed", privacy: .public)")
        onOpenChange?(value)
    }

    private func cancelTasks() {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
    }

    private func reconcile() {
        if isOpen {
            openTask?.cancel(); openTask = nil
            if isRailHovered || isCardHovered {
                closeTask?.cancel(); closeTask = nil
            } else if closeTask == nil {
                scheduleClose()
            }
        } else {
            closeTask?.cancel(); closeTask = nil
            if isRailHovered && !suppressed {
                if openTask == nil { scheduleOpen() }
            } else {
                openTask?.cancel(); openTask = nil
            }
        }
    }

    private func scheduleOpen() {
        openTaskGeneration += 1
        let generation = openTaskGeneration
        let clock = self.clock
        let delay = openDelay
        openTask = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard let self else { return }
            if self.openTaskGeneration == generation { self.openTask = nil }
            guard !Task.isCancelled, self.isRailHovered, !self.suppressed else { return }
            self.setOpen(true)
        }
    }

    private func scheduleClose() {
        closeTaskGeneration += 1
        let generation = closeTaskGeneration
        let clock = self.clock
        let grace = closeGrace
        closeTask = Task { [weak self] in
            try? await clock.sleep(for: grace)
            guard let self else { return }
            if self.closeTaskGeneration == generation { self.closeTask = nil }
            guard !Task.isCancelled, !self.isRailHovered, !self.isCardHovered else { return }
            self.setOpen(false)
        }
    }

    // MARK: - Testing

    /// Await the in-flight open or close task, so a test asserts on the state
    /// it left rather than racing it.
    func _drainForTesting() async {
        await openTask?.value
        await closeTask?.value
    }
}

/// Installs an `NSEvent` local keyDown monitor while started; Escape (keyCode 53)
/// calls `onEscape` and is consumed. Used by both renderers while the card is open.
///
/// A local monitor sees every key-down the app dispatches, whichever view has
/// focus, so the card needs no first responder of its own; it is also why the
/// monitor must exist only while the card is open, and why `start` replaces
/// rather than adds and `deinit` removes a monitor still installed.
@MainActor
final class PromptRailEscapeMonitor {
    /// `kVK_Escape`.
    nonisolated static let escapeKeyCode: UInt16 = 53

    typealias Install = @MainActor (@escaping (NSEvent) -> NSEvent?) -> Any?
    typealias Remove = @Sendable (Any) -> Void

    private let install: Install
    private let remove: Remove
    // nonisolated(unsafe): written on the main actor by `start` and `stop`,
    // read by the nonisolated `deinit`; single-threaded by the same ownership
    // invariant as `PromptRailHoverModel.deactivationObserver`.
    nonisolated(unsafe) private var monitor: Any?

    /// The seams default to AppKit's monitor table. Tests substitute their own
    /// to drive the handler with synthesized events and count installs.
    init(
        install: @escaping Install = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        remove: @escaping Remove = { NSEvent.removeMonitor($0) }
    ) {
        self.install = install
        self.remove = remove
    }

    deinit {
        if let monitor { remove(monitor) }
    }

    /// Installs the monitor, replacing one already installed.
    func start(onEscape: @escaping @MainActor () -> Void) {
        stop()
        monitor = install { event in
            guard event.keyCode == PromptRailEscapeMonitor.escapeKeyCode else { return event }
            MainActor.assumeIsolated { onEscape() }
            return nil
        }
    }

    /// Removes the monitor. A no-op when none is installed.
    func stop() {
        guard let monitor else { return }
        self.monitor = nil
        remove(monitor)
    }
}
