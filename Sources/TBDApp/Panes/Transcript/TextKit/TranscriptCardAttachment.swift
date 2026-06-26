import AppKit
import SwiftUI

/// An `NSTextAttachment` that hosts a SwiftUI card view inline within a
/// TextKit 2 document. Each attachment carries a stable `nodeID` so the
/// document can correlate attachments with `TranscriptRenderNode` values when
/// the attributed string is rebuilt during streaming. (#129)
@MainActor
final class TranscriptCardAttachment: NSTextAttachment {
    let nodeID: String
    let card: AnyView

    init(nodeID: String, card: AnyView) {
        self.nodeID = nodeID
        self.card = card
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not codable") }

    override func viewProvider(
        for parentView: NSView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        // Pass the card directly so the provider never needs to access
        // @MainActor state after construction (TextKit calls loadView on
        // the main thread, but Swift 6 can't verify that statically because
        // NSTextAttachmentViewProvider overrides are nonisolated in the SDK).
        let provider = TranscriptCardViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location,
            card: card
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

/// The `NSTextAttachmentViewProvider` that creates an `NSHostingView` for the
/// card and calculates its bounds to fill the available line-fragment width.
///
/// TextKit 2 calls `loadView()` and `attachmentBounds` on the main thread.
/// The card is captured at construction time from the `@MainActor` context of
/// `viewProvider(for:location:textContainer:)` and stored in a `_SendableBox`
/// because `NSTextAttachmentViewProvider` override methods are nonisolated in
/// the SDK — Swift 6 cannot statically verify the main-thread guarantee, even
/// when the subclass is annotated `@MainActor`. The box includes a runtime
/// precondition so any accidental off-main read traps loudly. (#129)
final class TranscriptCardViewProvider: NSTextAttachmentViewProvider {
    // Captured on the main actor at construction; only ever read on the main
    // thread by TextKit. The _SendableBox suppresses the Swift 6 Sending
    // diagnostic; the runtime precondition inside the box enforces the
    // thread constraint that the type system cannot express statically.
    private let _card: _SendableBox<AnyView>

    init(
        textAttachment: NSTextAttachment,
        parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?,
        location: NSTextLocation,
        card: AnyView
    ) {
        self._card = _SendableBox(card)
        super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
    }

    override func loadView() {
        let card = _card.mainThreadValue
        view = MainActor.assumeIsolated { NSHostingView(rootView: card) }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        if view == nil { loadView() }
        // swiftlint:disable:next force_cast
        let hostingView = view as! NSHostingView<AnyView>
        let lineWidth = proposedLineFragment.width
        return MainActor.assumeIsolated {
            let width = TranscriptCardSizing.width(forLineFragmentWidth: lineWidth)
            let height = TranscriptCardSizing.fittingHeight(of: hostingView, width: width)
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
    }
}

/// Shared layout math for card attachments: full-width minus insets, and a
/// reliable height-for-width measurement of the hosted SwiftUI card. (#129)
@MainActor
enum TranscriptCardSizing {
    static func width(forLineFragmentWidth lineWidth: CGFloat, insets: CGFloat = 8) -> CGFloat {
        max(lineWidth - insets * 2, 1)
    }

    /// Returns the height the card needs at exactly `width`.
    ///
    /// The naive `NSHostingView` path —
    /// `frame = width×10000; layoutSubtreeIfNeeded(); fittingSize.height` —
    /// UNDER-REPORTS for complex/wrapping content. `NSHostingView.fittingSize`
    /// does not reliably compute a height *for a constrained width*: a tall
    /// multi-line card (the real `AskUserQuestion` with several long option
    /// descriptions and answer bubbles) measures ~150 pt short of what it
    /// actually renders, so the next message overlaps it and the card content
    /// escapes its box. This was the same `NSHostingView` height
    /// under-reporting that defeated the earlier NSTableView virtualizer. (#129)
    ///
    /// `NSHostingController.sizeThatFits(in:)` DOES honour the proposed width:
    /// propose `(width, .greatestFiniteMagnitude)` and it returns the true
    /// height-for-width. We build a throwaway controller from the hosting view's
    /// `rootView` to measure, leaving the live hosting view untouched.
    static func fittingHeight(of view: NSHostingView<AnyView>, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.rootView)
        controller.sizingOptions = [.preferredContentSize]
        let proposed = NSSize(width: width, height: .greatestFiniteMagnitude)
        let measured = controller.sizeThatFits(in: proposed).height
        return measured > 0 ? measured : 44
    }
}

// MARK: - Private helpers

/// Wraps a value in an `@unchecked Sendable` box so it can cross the
/// concurrency boundary imposed by `NSTextAttachmentViewProvider`'s nonisolated
/// override contract. Access via `mainThreadValue` which traps if called off
/// the main thread, making a latent misuse immediately visible. (#129)
private final class _SendableBox<T>: @unchecked Sendable {
    private let value: T
    init(_ value: T) { self.value = value }

    var mainThreadValue: T {
        dispatchPrecondition(condition: .onQueue(.main))
        return value
    }
}
