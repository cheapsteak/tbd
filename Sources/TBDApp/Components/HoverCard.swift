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
/// warning/critical states, never as decoration.
enum HoverCardTint: Equatable {
    case normal
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

    init(label: String? = nil,
         value: String,
         chip: String? = nil,
         valueStyle: HoverCardTextStyle = .plain,
         monospacedDigits: Bool = false,
         tint: HoverCardTint = .normal,
         caption: String? = nil) {
        self.label = label
        self.value = value
        self.chip = chip
        self.valueStyle = valueStyle
        self.monospacedDigits = monospacedDigits
        self.tint = tint
        self.caption = caption
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

/// Hover timing knobs, injectable for tests. The show-delay decision is a
/// pure function so the "warm" fast-path is testable without a panel.
struct HoverCardTiming: Equatable {
    /// Delay before a card appears on a cold hover. Snappier than the
    /// system tooltip default, but slow enough not to flicker on drive-by
    /// mouse moves.
    var showDelay: TimeInterval
    /// After a card hides, hovers within this window skip the show delay —
    /// moving between sibling rows swaps content instantly (menu-like feel).
    var warmGrace: TimeInterval
    /// Fade-out duration when the pointer leaves.
    var fadeOutDuration: TimeInterval

    init(showDelay: TimeInterval = 0.35,
         warmGrace: TimeInterval = 0.35,
         fadeOutDuration: TimeInterval = 0.12) {
        self.showDelay = showDelay
        self.warmGrace = warmGrace
        self.fadeOutDuration = fadeOutDuration
    }

    static let standard = HoverCardTiming()

    /// 0 when a card is already up (swap instantly) or one hid moments ago
    /// (warm), otherwise the full show delay.
    func effectiveShowDelay(now: Date, lastDismissedAt: Date?, isCardVisible: Bool) -> TimeInterval {
        if isCardVisible { return 0 }
        if let lastDismissedAt, now.timeIntervalSince(lastDismissedAt) < warmGrace { return 0 }
        return showDelay
    }
}

// MARK: - Card view

/// Renders a `HoverCardModel`: calm neutrals, type hierarchy, color only for
/// state. Material background + hairline border; the hosting panel's window
/// shadow provides the elevation.
struct HoverCardView: View {
    let model: HoverCardModel

    private static let maxWidth: CGFloat = 320
    private static let cornerRadius: CGFloat = 9

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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func valueCell(_ row: HoverCardRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                styledText(row.value, style: row.valueStyle, monospacedDigits: row.monospacedDigits)
                    .font(.system(size: 12))
                    .foregroundStyle(valueColor(row))
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

    private func styledText(_ string: String, style: HoverCardTextStyle, monospacedDigits: Bool) -> Text {
        var text = Text(string)
        if style == .mutedItalic { text = text.italic() }
        if monospacedDigits { text = text.monospacedDigit() }
        return text
    }

    private func valueColor(_ row: HoverCardRow) -> Color {
        switch row.tint {
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
        hasShadow = true
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
/// spans anchors: once any card is up (or just hid), hovering a sibling swaps
/// content with no re-delay.
@MainActor
final class HoverCardController {
    static let shared = HoverCardController()

    private let timing: HoverCardTiming
    private var panel: HoverCardPanel?
    private weak var currentAnchor: NSView?
    private weak var pendingAnchor: NSView?
    private var pendingShow: Task<Void, Never>?
    private var lastDismissedAt: Date?
    private var lastModel: HoverCardModel?
    /// Bumped on every show/hide; an in-flight fade-out completion only
    /// orders the panel out if no newer show/hide superseded it.
    private var fadeGeneration = 0

    /// Gap between the anchor's edge and the card.
    private static let anchorGap: CGFloat = 5

    init(timing: HoverCardTiming = .standard) {
        self.timing = timing
    }

    private var isCardVisible: Bool {
        panel?.isVisible == true && currentAnchor != nil
    }

    func hoverBegan(anchor: NSView, model: HoverCardModel) {
        cancelPendingShow()
        let delay = timing.effectiveShowDelay(
            now: Date(), lastDismissedAt: lastDismissedAt, isCardVisible: isCardVisible
        )
        guard delay > 0 else {
            show(anchor: anchor, model: model)
            return
        }
        pendingAnchor = anchor
        pendingShow = Task { [weak self, weak anchor] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let anchor else { return }
            self.show(anchor: anchor, model: model)
        }
    }

    func hoverEnded(anchor: NSView) {
        if pendingAnchor === anchor {
            cancelPendingShow()
        }
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

    private func cancelPendingShow() {
        pendingShow?.cancel()
        pendingShow = nil
        pendingAnchor = nil
    }

    private func show(anchor: NSView, model: HoverCardModel) {
        cancelPendingShow()
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

    /// Below the anchor, leading-aligned; flips above when there is no room
    /// underneath, and clamps horizontally into the screen's visible frame.
    private func position(panel: HoverCardPanel, relativeTo anchor: NSView) {
        guard let window = anchor.window else { return }
        let anchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorFrame = window.convertToScreen(anchorFrameInWindow)
        let size = panel.hostingView.fittingSize

        var origin = NSPoint(
            x: anchorFrame.minX,
            y: anchorFrame.minY - size.height - Self.anchorGap
        )
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = anchorFrame.maxY + Self.anchorGap
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
            guard let self, self.fadeGeneration == generation else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }
}

// MARK: - Anchor plumbing

/// Invisible tracking view laid under the modified SwiftUI view. `hitTest`
/// returns nil so clicks pass straight through; the tracking area still
/// delivers enter/exit (tracking is owner-routed, not hit-test-routed).
private final class HoverCardAnchorNSView: NSView {
    var model: HoverCardModel?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let model else { return }
        HoverCardController.shared.hoverBegan(anchor: self, model: model)
    }

    override func mouseExited(with event: NSEvent) {
        HoverCardController.shared.hoverEnded(anchor: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            HoverCardController.shared.hoverEnded(anchor: self)
        }
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
    /// the empty-string `.help()` idiom). Fast: ~0.35s cold show delay,
    /// instant swap while a card is up or just after one hid, quick fade-out.
    /// Never steals keyboard focus (non-activating borderless panel).
    func hoverCard(_ model: HoverCardModel?) -> some View {
        background(HoverCardAnchor(model: model))
    }
}
