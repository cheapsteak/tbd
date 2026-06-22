import AppKit
import SwiftUI
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript card attachment")
struct TranscriptCardAttachmentTests {
    @Test("attachment carries node id and enables a hosted view")
    func attachmentMetadata() {
        let card = AnyView(Text("hi").frame(width: 300, height: 40))
        let att = TranscriptCardAttachment(nodeID: "t1", card: card)
        #expect(att.nodeID == "t1")
        #expect(att.allowsTextAttachmentView)
    }

    @Test("width policy fills the line fragment minus insets")
    func widthPolicy() {
        #expect(TranscriptCardSizing.width(forLineFragmentWidth: 600, insets: 8) == 584)
    }

    @Test("provider hosts the card and reports a positive height")
    func providerHeight() {
        let card = AnyView(Text("two\nlines").frame(width: 200))
        let att = TranscriptCardAttachment(nodeID: "t2", card: card)
        let provider = TranscriptCardViewProvider(textAttachment: att, parentView: nil, textLayoutManager: nil, location: TestTextLocation(), card: card)
        provider.loadView()
        #expect(provider.view is NSHostingView<AnyView>)
        let h = TranscriptCardSizing.fittingHeight(of: provider.view as! NSHostingView<AnyView>, width: 300)
        #expect(h > 0)
    }
}

// Minimal NSTextLocation stub for constructing a provider in tests.
// Must be a class because NSTextLocation inherits from NSObjectProtocol.
private final class TestTextLocation: NSObject, NSTextLocation {
    func compare(_ location: NSTextLocation) -> ComparisonResult { .orderedSame }
}
