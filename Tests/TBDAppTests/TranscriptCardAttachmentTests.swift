import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

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

    /// Regression for #129: a tall, complex card (a 2-question AskUserQuestion
    /// with three long multi-line option descriptions each + answers) must
    /// measure its TRUE height-for-width. The pre-fix `NSHostingView.fittingSize`
    /// path under-reported this card by ~150 pt (≈530 measured vs ≈686 rendered),
    /// so the next message overlapped it. `NSHostingController.sizeThatFits`
    /// honours the proposed width and reports the real height. We assert a floor
    /// comfortably above the old under-measured value.
    @Test("tall AskUserQuestion card measures its true (large) height-for-width")
    func tallAskMeasuresFullHeight() throws {
        let suiteName = "card-attach-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            appState: appState
        )

        let items = TranscriptCompareFixtures.items(for: "tallAsk")
        let askNode = try #require(
            transcriptRenderNodes(from: items).first { node in
                if case .toolCall(_, let name, _, _, _, _) = node.kind { return name == "AskUserQuestion" }
                return false
            }
        )
        let card = try #require(TranscriptCardFactory.card(for: askNode, context: context))

        let width = TranscriptCardSizing.width(forLineFragmentWidth: 680)
        let host = NSHostingView(rootView: card)
        let height = TranscriptCardSizing.fittingHeight(of: host, width: width)

        // The buggy fittingSize path returned ~530 for this card; the true
        // height is ~686. Floor of 600 fails on the old measure, passes on the fix.
        #expect(height > 600, "tall AskUserQuestion measured only \(height)pt — under-reported height regression")
    }
}

// Minimal NSTextLocation stub for constructing a provider in tests.
// Must be a class because NSTextLocation inherits from NSObjectProtocol.
private final class TestTextLocation: NSObject, NSTextLocation {
    func compare(_ location: NSTextLocation) -> ComparisonResult { .orderedSame }
}
