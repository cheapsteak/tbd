import AppKit
import SwiftUI

// MARK: - Content model

/// Text treatment for a hover-card title or row value.
enum HoverCardTextStyle: Equatable {
    case plain
    /// Muted + italic — for "ambient (terminal login)" style de-emphasis.
    case mutedItalic
}

/// Color treatment for a row value. Calm by default: color appears ONLY for
/// caution/warning/critical states, never as decoration. The four-tier hierarchy
/// aligns with `ProfileUsagePresentation.FillLevel`.
enum HoverCardTint: Equatable {
    case normal
    /// Yellow: pace-aware caution tier (on track to warm but not yet alarmingly so).
    case caution
    case warning
    case critical
}

/// One structured line in a hover card: an optional muted label column and a
/// value, with optional profile-name chip and a small caption underneath.
struct HoverCardRow: Equatable {
    var label: String?
    var value: String
    /// Small rounded chip rendered after the value (e.g. the profile name).
    var chip: String?
    var valueStyle: HoverCardTextStyle
    /// Render the value with monospaced digits (usage percentages, timestamps).
    var monospacedDigits: Bool
    var tint: HoverCardTint
    /// Muted caption line under the value (drift warnings, staleness notes).
    var caption: String?
    /// Another string this row's `value` may swap to while the card is up.
    ///
    /// Drawn **hidden but laid out**, so the row reserves the larger of the two
    /// in both axes and the card is exactly the same size whichever is showing.
    /// A card that resized on a swap would jump under the pointer that summoned
    /// it — the jitter a live-updating row exists to avoid, not to cause. Set it
    /// on both states of a swapping row, each naming the other.
    var alternateValue: String?

    init(label: String? = nil,
         value: String,
         chip: String? = nil,
         valueStyle: HoverCardTextStyle = .plain,
         monospacedDigits: Bool = false,
         tint: HoverCardTint = .normal,
         caption: String? = nil,
         alternateValue: String? = nil) {
        self.label = label
        self.value = value
        self.chip = chip
        self.valueStyle = valueStyle
        self.monospacedDigits = monospacedDigits
        self.tint = tint
        self.caption = caption
        self.alternateValue = alternateValue
    }
}

/// The full content of a hover card: a title slot plus structured rows.
/// Pure data — composition is unit-testable without any AppKit machinery.
struct HoverCardModel: Equatable {
    var title: String?
    var titleStyle: HoverCardTextStyle
    /// Muted caption line directly under the title.
    var titleCaption: String?
    var rows: [HoverCardRow]

    init(title: String? = nil,
         titleStyle: HoverCardTextStyle = .plain,
         titleCaption: String? = nil,
         rows: [HoverCardRow] = []) {
        self.title = title
        self.titleStyle = titleStyle
        self.titleCaption = titleCaption
        self.rows = rows
    }
}

// MARK: - Timing

/// Hover timing knobs, injectable for tests.
///
/// ## Adopted hover-card timing rules (research-backed)
///
/// Distilled from Apple HIG "Offering help" (help-tag display speed is a
/// deliberate, preference-tunable delay — default ~1.5s), Microsoft Fluent
/// (~300ms entrance delay, reduced for adjacent items), NN/g's hover-reveal
/// pattern, and the classic "hover intent" / safe-triangle work:
///
/// 1. INTENT, NOT PROXIMITY. Show only when the pointer signals it wants the
///    card — never merely because it crossed the anchor. A cursor sweeping to
///    another row must show nothing.
/// 2. DWELL-GATE THE SHOW. Require the pointer to come to REST over the anchor
///    (movement below a small threshold for a rest window, ~150–250ms) — this
///    is the "pointer at rest" signal. Any significant movement RESETS the rest
///    timer (movement-resets-timer / hover-intent).
/// 3. MINIMUM COLD DELAY. Independently, hold for a floor delay (~0.5s, the
///    upper end of the 300–500ms consensus) before a cold card can appear, so a
///    momentary pause mid-traversal is not enough. Show = floor elapsed AND at
///    rest.
/// 4. REDUCED (not zero) DELAY FOR ADJACENT ITEMS. Once a card is up, swapping
///    to a sibling should feel responsive but must NOT chase the cursor: still
///    require a short at-rest dwell (~150ms) before swapping. Deliberate
///    row-to-row comparison stays fluid; a sweep reveals nothing.
/// 5. WARM GRACE. Briefly after a card hides, a re-hover is still "warm" and
///    uses the short warm dwell instead of the full cold floor — but it, too,
///    requires the pointer to settle (no instant chase).
/// 6. QUICK, ASYMMETRIC FADE-OUT. Dismiss faster than we show (fade < show
///    delay) so leaving feels immediate while entering feels intentional.
///
/// The show decision is factored into a pure `HoverDwellReducer` so the whole
/// state machine (rest gating, floor delay, warm swap) is unit-testable
/// without a panel or any NSEvent plumbing.
struct HoverCardTiming: Equatable {
    /// Minimum cold-hover floor: a fresh card cannot appear before this
    /// elapses since the pointer entered, even if it settles sooner. Upper end
    /// of the 300–500ms industry consensus (rule 3).
    var showDelay: TimeInterval
    /// The pointer must stay below `movementThreshold` for this long — "at
    /// rest" — before a cold card shows (rule 2). Any larger move resets it.
    var restWindow: TimeInterval
    /// Per-move distance (in points) under which the pointer counts as "at
    /// rest". Small jitter does not reset the dwell; a real traversal does.
    var movementThreshold: CGFloat
    /// At-rest dwell required before swapping the visible card to a sibling, or
    /// re-showing during the warm grace. Short enough to feel responsive,
    /// long enough that a sweep never triggers a swap (rule 4/5).
    var warmDwell: TimeInterval
    /// After a card hides, re-hovers within this window are "warm": they use
    /// `warmDwell` instead of the full cold floor (rule 5).
    var warmGrace: TimeInterval
    /// Fade-out duration when the pointer leaves. Kept below `showDelay` so
    /// dismissal feels quicker than appearance (rule 6).
    var fadeOutDuration: TimeInterval

    init(showDelay: TimeInterval = 0.55,
         restWindow: TimeInterval = 0.18,
         movementThreshold: CGFloat = 3,
         warmDwell: TimeInterval = 0.15,
         warmGrace: TimeInterval = 0.4,
         fadeOutDuration: TimeInterval = 0.12) {
        self.showDelay = showDelay
        self.restWindow = restWindow
        self.movementThreshold = movementThreshold
        self.warmDwell = warmDwell
        self.warmGrace = warmGrace
        self.fadeOutDuration = fadeOutDuration
    }

    static let standard = HoverCardTiming()
}

// MARK: - Dwell reducer

/// Pure, panel-free state machine deciding WHEN a hover card should show for
/// one anchor. Fed pointer events (enter / move / a periodic tick) plus the
/// ambient warm-state (is a card already visible, when one last hid); returns
/// `true` from `shouldShow` exactly once the dwell gate opens.
///
/// Two independent gates must both pass before a cold card shows:
///  - FLOOR: at least `showDelay` has elapsed since the pointer entered.
///  - REST: the pointer has stayed below `movementThreshold` for `restWindow`.
///
/// When a card is already visible (swap) or one hid within `warmGrace` (warm),
/// the floor collapses to 0 and only a short `warmDwell` at-rest is required —
/// responsive row-to-row comparison without chasing the cursor.
///
/// Entirely value-typed and clock-injected (`now` is passed in), so tests drive
/// it with synthetic timestamps — no NSEvent, no timers, no AppKit.
struct HoverDwellReducer: Equatable {
    private let timing: HoverCardTiming
    /// When the pointer entered this anchor. nil once exited.
    private(set) var enteredAt: Date?
    /// When the pointer last came to rest (last move, or entry). The rest
    /// window is measured from here; any significant move pushes it forward.
    private(set) var restingSince: Date?
    /// Set once we decide to show, so a satisfied gate fires exactly once.
    private(set) var didShow = false

    init(timing: HoverCardTiming) {
        self.timing = timing
    }

    /// Pointer entered the anchor. `now` is the entry timestamp.
    mutating func entered(now: Date) {
        enteredAt = now
        restingSince = now
        didShow = false
    }

    /// Pointer moved by `distance` points since the last position. A move at or
    /// above the threshold resets the rest clock; sub-threshold jitter does not.
    mutating func moved(distance: CGFloat, now: Date) {
        guard enteredAt != nil else { return }
        if distance >= timing.movementThreshold {
            restingSince = now
        }
    }

    /// Pointer left the anchor — clears all state.
    mutating func exited() {
        enteredAt = nil
        restingSince = nil
        didShow = false
    }

    /// Evaluate the gates at `now`. Returns true the first tick both the floor
    /// and rest gates are open (latched via `didShow` so it fires once). The
    /// caller passes the ambient warm state; the reducer owns only the dwell.
    mutating func shouldShow(now: Date, lastDismissedAt: Date?, isCardVisible: Bool) -> Bool {
        guard !didShow, let enteredAt, let restingSince else { return false }

        let isWarm = isCardVisible
            || (lastDismissedAt.map { now.timeIntervalSince($0) < timing.warmGrace } ?? false)
        let floor = isWarm ? 0 : timing.showDelay
        let requiredRest = isWarm ? timing.warmDwell : timing.restWindow

        let floorElapsed = now.timeIntervalSince(enteredAt) >= floor
        let atRest = now.timeIntervalSince(restingSince) >= requiredRest
        guard floorElapsed, atRest else { return false }
        didShow = true
        return true
    }
}

// MARK: - Placement

/// Where a card's panel goes for a given anchor.
///
/// Pure geometry in AppKit screen coordinates (y grows upward), so the whole
/// rule is unit-testable without a window, a panel or a screen.
///
/// The rule is *below the anchor, leading-aligned, unless the card would leave
/// the anchor's own window* — then above. Screen room alone is the wrong test:
/// a card anchored to the status bar at the bottom of the window has plenty of
/// desktop beneath it, and placing it there drops it out of the window
/// altogether, right onto the strip it describes. Bounding it by the window
/// keeps every card over the surface that summoned it, and leaves anchors with
/// room beneath them — tab-bar items, sidebar rows — exactly where they were.
///
/// The window is a *preference*, not a hard constraint: when neither side fits
/// inside it (a small floating panel, a short window), the screen decides, so
/// this can never place a card worse than the screen rule alone would.
/// The two clearances are deliberately asymmetric — see `anchorGap` and
/// `flippedBarClearance`.
enum HoverCardPlacement {
    /// Gap under the anchor for a card in its preferred, below position.
    ///
    /// Small on purpose: a card hanging under the control that summoned it
    /// should read as *attached* to it, the way a menu hangs off its button.
    static let anchorGap: CGFloat = 8

    /// Clearance above the anchor for a card that had to **flip**, sized to
    /// clear the whole bar the anchor sits in plus visible breathing room.
    ///
    /// A flip only happens because the card ran out of room on the side it
    /// wanted — it is escaping the edge of a window, and in practice that edge
    /// is a bar: the anchor is a chip or a label a few points tall sitting
    /// inside a strip with its own padding, its own background and its own top
    /// edge. Clearing the *anchor* by a hair leaves the card sitting on that
    /// strip, covering the very row the reader is looking at, which is why this
    /// cannot be the same constant as `anchorGap` — the below case wants to
    /// hug, and this one must not.
    ///
    /// It is a constant rather than the container's measured frame because the
    /// anchor has no container to measure. The anchor is an AppKit view
    /// SwiftUI hosts as a `background`, and the bar around it is SwiftUI
    /// padding and a material — no enclosing `NSView` whose frame could be
    /// read, so recovering one would mean either sniffing the private hosting
    /// hierarchy for a visual-effect view or making every adopter of
    /// `.hoverCard` pass its container's frame, which fails silently for
    /// whoever forgets. So the constant carries the container's height itself:
    /// the tallest bar in this app plus a gap wide enough to read as a gap.
    ///
    /// Above a status-bar chip that leaves roughly 24pt of untouched window
    /// content between the top of the strip and the bottom of the card — a band
    /// wide enough to be unmistakable rather than merely measurable, while the
    /// card stays near enough to the chip to read as belonging to it. It costs
    /// nothing in fit: a flip is only chosen when the card had a whole window's
    /// height above the anchor to sit in.
    static let flippedBarClearance: CGFloat = 32

    /// Keep-out from the edge of the screen's visible frame.
    static let screenMargin: CGFloat = 4

    /// The panel frame for one card.
    ///
    /// `panelSize` is the whole hosted size — the card plus the transparent
    /// `shadowInset` margin its shadow draws into on every side — while the
    /// gap, the alignment and the clamping all apply to the *visible* card
    /// inside it. Anything else would leave the card floating a shadow's width
    /// away from what it describes.
    static func panelFrame(anchor: CGRect,
                           panelSize: CGSize,
                           shadowInset: CGFloat,
                           window: CGRect?,
                           screenVisibleFrame: CGRect?) -> CGRect {
        let card = CGSize(width: panelSize.width - shadowInset * 2,
                          height: panelSize.height - shadowInset * 2)

        let below = anchor.minY - anchorGap - card.height
        let above = anchor.maxY + flippedBarClearance

        let screenLower = screenVisibleFrame.map { $0.minY + screenMargin }
        let screenUpper = screenVisibleFrame.map { $0.maxY - screenMargin }
        let fitsScreenBelow = screenLower.map { below >= $0 } ?? true
        let fitsScreenAbove = screenUpper.map { above + card.height <= $0 } ?? true
        let fitsWindowBelow = (window.map { below >= $0.minY } ?? true) && fitsScreenBelow
        let fitsWindowAbove = (window.map { above + card.height <= $0.maxY } ?? true) && fitsScreenAbove

        var y: CGFloat
        if fitsWindowBelow {
            y = below
        } else if fitsWindowAbove {
            y = above
        } else if fitsScreenBelow {
            y = below
        } else if fitsScreenAbove {
            y = above
        } else {
            y = below
        }
        if let screenLower, let screenUpper {
            y = min(max(y, screenLower), max(screenLower, screenUpper - card.height))
        }

        var x = anchor.minX
        if let screenVisibleFrame {
            let leftmost = screenVisibleFrame.minX + screenMargin
            let rightmost = screenVisibleFrame.maxX - screenMargin - card.width
            x = min(max(x, leftmost), max(leftmost, rightmost))
        }

        return CGRect(x: x - shadowInset,
                      y: y - shadowInset,
                      width: panelSize.width,
                      height: panelSize.height)
    }
}

// MARK: - Card view

/// Renders a `HoverCardModel`: calm neutrals, type hierarchy, color only for
/// state.
///
/// Elevation is a material fill plus a **small shadow this view draws itself**,
/// the way a menu or a popover separates from what is behind it — no border.
/// The hosting panel's own window shadow is deliberately off: it is sized for a
/// window rather than for a tooltip, so on a card a few dozen points tall it
/// reads as a thick gray edge, and it spills far enough past the card to wash
/// out whatever the card is anchored to. Drawing the shadow here bounds it to a
/// radius chosen for this box, and makes it recomputed with the content rather
/// than by the window server from a shape that may still be the previous card's.
///
/// The price is a transparent margin: a shadow drawn inside the hosting view
/// needs somewhere to fall, and the panel is sized to fit its content exactly.
/// So the card carries `shadowInset` points of clear padding on every side, and
/// `HoverCardPlacement` positions the *card* inside that margin rather than the
/// panel.
struct HoverCardView: View {
    let model: HoverCardModel

    private static let maxWidth: CGFloat = 320
    private static let cornerRadius: CGFloat = 9
    /// Transparent margin around the card, so its own shadow has room to draw
    /// inside a panel that is otherwise sized exactly to the card.
    ///
    /// `nonisolated` because `View` conformance infers whole-type `@MainActor`
    /// isolation onto even a constant, and the placement geometry that reads it
    /// is a pure function with no actor of its own.
    nonisolated static let shadowInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = model.title {
                VStack(alignment: .leading, spacing: 2) {
                    styledText(title,
                               style: model.titleStyle,
                               monospacedDigits: false)
                        .font(.system(size: 12,
                                      weight: model.titleStyle == .mutedItalic ? .regular : .semibold))
                        .foregroundStyle(model.titleStyle == .mutedItalic ? Color.secondary : Color.primary)
                    if let caption = model.titleCaption {
                        captionText(caption)
                    }
                }
            }
            if !model.rows.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            if let label = row.label {
                                Text(label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.leading)
                                valueCell(row)
                            } else {
                                valueCell(row)
                                    .gridCellColumns(2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // The shadow rides on the background shape rather than on the
            // composed card, so it traces the rounded rect instead of haloing
            // every glyph. Dark and soft in both appearances: over a
            // user-themed terminal the material alone can land too close to
            // whatever is behind it, and this is the only thing separating
            // them now that there is no border.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 2)
        }
        .padding(Self.shadowInset)
    }

    @ViewBuilder
    private func valueCell(_ row: HoverCardRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                valueText(row)
                if let chip = row.chip {
                    Text(chip)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
            }
            if let caption = row.caption {
                captionText(caption)
            }
        }
    }

    /// The value, over an invisible copy of whatever it may swap to. `.hidden()`
    /// removes the peer from the drawing but not from the layout, so the row is
    /// sized for both strings at once and a swap moves no pixel but the text.
    @ViewBuilder
    private func valueText(_ row: HoverCardRow) -> some View {
        if let alternate = row.alternateValue {
            ZStack(alignment: .topLeading) {
                styledText(alternate, style: row.valueStyle, monospacedDigits: row.monospacedDigits)
                    .font(.system(size: 12))
                    .hidden()
                    .accessibilityHidden(true)
                visibleValue(row)
            }
        } else {
            visibleValue(row)
        }
    }

    private func visibleValue(_ row: HoverCardRow) -> some View {
        styledText(row.value, style: row.valueStyle, monospacedDigits: row.monospacedDigits)
            .font(.system(size: 12))
            .foregroundStyle(valueColor(row))
    }

    private func styledText(_ string: String, style: HoverCardTextStyle, monospacedDigits: Bool) -> Text {
        var text = Text(string)
        if style == .mutedItalic { text = text.italic() }
        if monospacedDigits { text = text.monospacedDigit() }
        return text
    }

    private func valueColor(_ row: HoverCardRow) -> Color {
        switch row.tint {
        case .caution: return .orange  // matches warning: tracker's bars have no yellow tier
        case .warning: return .orange
        case .critical: return .red
        case .normal: return row.valueStyle == .mutedItalic ? Color.secondary : Color.primary
        }
    }

    private func captionText(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Panel

/// Borderless, non-activating panel hosting the card. Never becomes key or
/// main (the terminal keeps keyboard focus) and ignores mouse events so the
/// views underneath keep receiving hover/clicks.
private final class HoverCardPanel: NSPanel {
    let hostingView: NSHostingView<HoverCardView>

    init(model: HoverCardModel) {
        hostingView = NSHostingView(rootView: HoverCardView(model: model))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        // The card draws its own shadow (see `HoverCardView`). AppKit's window
        // shadow is sized for a window, so on a tooltip-sized panel it reads as
        // a thick gray edge — and it is computed by the window server from the
        // window's alpha mask, which on this shared, resized, SwiftUI-hosted
        // panel is whatever the *previous* card left behind.
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// One shared panel + the timing state machine. Shared so the "warm" state
/// spans anchors: once any card is up (or just hid), hovering a sibling can
/// swap content on a short dwell instead of the full cold floor.
///
/// The per-anchor dwell (rest gating + floor delay) lives in each
/// `HoverCardAnchorNSView`'s `HoverDwellReducer`; the anchor drives it from
/// real `mouseMoved` events plus a periodic tick, and calls `requestShow`
/// only once its gate opens. The controller owns the shared warm state
/// (`lastDismissedAt`, `isCardVisible`) that the reducer reads.
@MainActor
final class HoverCardController {
    static let shared = HoverCardController()

    let timing: HoverCardTiming
    private var panel: HoverCardPanel?
    private weak var currentAnchor: NSView?
    private var lastDismissedAt: Date?
    private var lastModel: HoverCardModel?
    /// Bumped on every show/hide; an in-flight fade-out completion only
    /// orders the panel out if no newer show/hide superseded it.
    private var fadeGeneration = 0
    /// After an interaction dismissal (a menu opened, or the row/buttons were
    /// clicked), suppress the warm instant-reshow until this instant so the
    /// tooltip can't pop back over an open menu.
    private var suppressUntil: Date?
    /// Guards `installInteractionHooks()` so the notification observer and local
    /// event monitor register exactly once for the app lifetime.
    private var interactionHooksInstalled = false
    private var menuObserver: NSObjectProtocol?
    private var mouseMonitor: Any?

    /// How long a click / menu-open suppresses the tooltip's warm reshow.
    /// Comfortably longer than the warm-grace window so a click can't be
    /// immediately undone by a lingering warm hover.
    private static let interactionSuppression: TimeInterval = 0.4

    init(timing: HoverCardTiming = .standard) {
        self.timing = timing
        installInteractionHooks()
    }

    /// Register the global dismissal hooks once. `NSMenu.didBeginTracking`
    /// covers every menu (right-click contextMenu, the "…" Menu, the "Switch
    /// account" submenu). A local mouse-down monitor covers plain row-selection
    /// and button clicks, which post no menu notification. Both hop to the main
    /// actor and dismiss the card immediately.
    private func installInteractionHooks() {
        guard !interactionHooksInstalled else { return }
        interactionHooksInstalled = true

        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissForInteraction()
            }
        }

        // Local monitor fires on the main thread for clicks inside the app.
        // Only act when a card is up to avoid per-click overhead; return the
        // event unchanged so selection/button clicks still work.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.isCardVisible {
                    self.dismissForInteraction()
                }
            }
            return event
        }
    }

    /// Immediately hide the current card, then suppress the warm reshow briefly
    /// so the tooltip does not pop back while a menu is open. Central hook:
    /// every `.hoverCard` adopter inherits it.
    func dismissForInteraction() {
        suppressUntil = Date().addingTimeInterval(Self.interactionSuppression)
        hide()
    }

    var isCardVisible: Bool {
        panel?.isVisible == true && currentAnchor != nil
    }

    /// Ambient state an anchor's `HoverDwellReducer` needs to decide warm vs.
    /// cold: is a card up, and when did one last hide. `nil` `lastDismissedAt`
    /// while suppression is active so a warm reshow can't jump an open menu.
    func warmState(now: Date = Date()) -> (lastDismissedAt: Date?, isCardVisible: Bool, suppressed: Bool) {
        let suppressed = suppressUntil.map { now < $0 } ?? false
        return (suppressed ? nil : lastDismissedAt, isCardVisible, suppressed)
    }

    /// An anchor's dwell gate has opened — show its card now. No-op while an
    /// interaction dismissal is still suppressing reshow.
    func requestShow(anchor: NSView, model: HoverCardModel) {
        if let suppressUntil, Date() < suppressUntil { return }
        show(anchor: anchor, model: model)
    }

    func hoverEnded(anchor: NSView) {
        if currentAnchor === anchor {
            hide()
        }
    }

    /// Live content refresh: if the card is up for this anchor, re-render (and
    /// re-fit) in place — usage numbers stay current while the card is shown.
    func modelChanged(anchor: NSView, model: HoverCardModel?) {
        guard currentAnchor === anchor, let panel, panel.isVisible else { return }
        guard let model else {
            hide()
            return
        }
        guard model != lastModel else { return }
        apply(model: model, to: panel, anchor: anchor)
    }

    private func show(anchor: NSView, model: HoverCardModel) {
        guard anchor.window != nil else { return }
        fadeGeneration += 1
        let panel = self.panel ?? HoverCardPanel(model: model)
        self.panel = panel
        currentAnchor = anchor
        panel.alphaValue = 1
        apply(model: model, to: panel, anchor: anchor)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func apply(model: HoverCardModel, to panel: HoverCardPanel, anchor: NSView) {
        lastModel = model
        panel.appearance = anchor.effectiveAppearance
        panel.hostingView.rootView = HoverCardView(model: model)
        panel.hostingView.invalidateIntrinsicContentSize()
        position(panel: panel, relativeTo: anchor)
    }

    /// Hands the anchor's geometry to `HoverCardPlacement`, which owns the rule.
    private func position(panel: HoverCardPanel, relativeTo anchor: NSView) {
        guard let window = anchor.window else { return }
        let anchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorFrame = window.convertToScreen(anchorFrameInWindow)
        let frame = HoverCardPlacement.panelFrame(
            anchor: anchorFrame,
            panelSize: panel.hostingView.fittingSize,
            shadowInset: HoverCardView.shadowInset,
            window: window.frame,
            screenVisibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    private func hide() {
        currentAnchor = nil
        lastModel = nil
        lastDismissedAt = Date()
        guard let panel, panel.isVisible else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { [timing] context in
            context.duration = timing.fadeOutDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit delivers this completion on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }
}

// MARK: - Anchor plumbing

/// Invisible tracking view laid under the modified SwiftUI view. `hitTest`
/// returns nil so clicks pass straight through; the tracking area still
/// delivers enter/exit/moved (tracking is owner-routed, not hit-test-routed).
///
/// Owns a per-anchor `HoverDwellReducer`: `mouseMoved` feeds it real cursor
/// deltas (movement resets the rest clock), and a lightweight repeating timer
/// polls the gate while the pointer is inside so a card appears the moment the
/// pointer settles AND the floor delay has passed — never on a drive-by sweep.
private final class HoverCardAnchorNSView: NSView {
    var model: HoverCardModel?

    private var reducer = HoverDwellReducer(timing: HoverCardController.shared.timing)
    private var dwellTimer: Timer?
    private var lastMouseLocation: NSPoint?
    /// Poll cadence for the dwell gate — fine enough that the rest window and
    /// floor delay feel crisp, coarse enough to stay cheap while hovering.
    private static let pollInterval: TimeInterval = 1.0 / 30.0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard model != nil else { return }
        lastMouseLocation = event.locationInWindow
        reducer.entered(now: Date())
        startDwellTimer()
    }

    override func mouseMoved(with event: NSEvent) {
        guard model != nil else { return }
        let location = event.locationInWindow
        let distance: CGFloat
        if let last = lastMouseLocation {
            distance = hypot(location.x - last.x, location.y - last.y)
        } else {
            distance = 0
        }
        lastMouseLocation = location
        reducer.moved(distance: distance, now: Date())
    }

    override func mouseExited(with event: NSEvent) {
        endHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            endHover()
        }
    }

    /// Poll the dwell gate; once it opens, show the card and stop the timer
    /// (the reducer latches, so it won't re-fire until the next enter).
    private func startDwellTimer() {
        dwellTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateDwell()
            }
        }
        // Common mode so the poll keeps ticking during scrolls/tracking loops.
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func evaluateDwell() {
        guard let model else {
            endHover()
            return
        }
        let controller = HoverCardController.shared
        let warm = controller.warmState()
        if reducer.shouldShow(now: Date(),
                              lastDismissedAt: warm.lastDismissedAt,
                              isCardVisible: warm.isCardVisible) {
            controller.requestShow(anchor: self, model: model)
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
    }

    private func endHover() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        lastMouseLocation = nil
        reducer.exited()
        HoverCardController.shared.hoverEnded(anchor: self)
    }
}

private struct HoverCardAnchor: NSViewRepresentable {
    let model: HoverCardModel?

    func makeNSView(context: Context) -> HoverCardAnchorNSView {
        let view = HoverCardAnchorNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: HoverCardAnchorNSView, context: Context) {
        nsView.model = model
        HoverCardController.shared.modelChanged(anchor: nsView, model: model)
    }
}

extension View {
    /// Attach a styled hover card to this view. nil model = no card (mirrors
    /// the empty-string `.help()` idiom). Dwell-gated: a cold card appears only
    /// once the pointer has settled over the anchor AND the ~0.55s floor delay
    /// has passed, so a cursor merely sweeping past shows nothing. While a card
    /// is up (or one hid moments ago), swapping to a sibling needs only a short
    /// at-rest dwell — fluid comparison without chasing the cursor. Quick
    /// fade-out; never steals keyboard focus (non-activating borderless panel).
    func hoverCard(_ model: HoverCardModel?) -> some View {
        background(HoverCardAnchor(model: model))
    }
}
