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
        // the main thread, but Swift 6 can't verify that statically).
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
/// `viewProvider(for:location:textContainer:)` so that the provider's own
/// nonisolated methods never need to reach back into `@MainActor` state. (#129)
final class TranscriptCardViewProvider: NSTextAttachmentViewProvider {
    // Captured on the main actor at construction; only ever read on the main
    // thread by TextKit. Using @unchecked Sendable on the wrapper avoids the
    // Swift 6 Sending diagnostic while preserving the real guarantee.
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
        view = NSHostingView(rootView: _card.value)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let width = TranscriptCardSizing.width(forLineFragmentWidth: proposedLineFragment.width)
        let hostingView: NSHostingView<AnyView>
        if let existing = view as? NSHostingView<AnyView> {
            hostingView = existing
        } else {
            loadView()
            // swiftlint:disable:next force_cast
            hostingView = view as! NSHostingView<AnyView>
        }
        let height = TranscriptCardSizing.fittingHeight(of: hostingView, width: width)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Shared layout math for card attachments: full-width minus insets, and
/// fitting-height with a 44 pt fallback when SwiftUI reports zero. (#129)
enum TranscriptCardSizing {
    static func width(forLineFragmentWidth lineWidth: CGFloat, insets: CGFloat = 8) -> CGFloat {
        max(lineWidth - insets * 2, 1)
    }

    static func fittingHeight(of view: NSHostingView<AnyView>, width: CGFloat) -> CGFloat {
        view.frame = CGRect(x: 0, y: 0, width: width, height: 10_000)
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        return height > 0 ? height : 44
    }
}

// MARK: - Private helpers

/// Wraps a value in an `@unchecked Sendable` box so it can cross concurrency
/// domains within the TextKit provider pattern. The caller is responsible for
/// ensuring accesses are on the appropriate thread (main thread for all
/// NSTextAttachmentViewProvider callbacks). (#129)
private final class _SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
