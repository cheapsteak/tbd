import Foundation
import Testing
@testable import TBDApp

/// Tier 1. Pure layout decision — no `UserDefaults`, no filesystem.
///
/// The decision exists because a `WKWebView` nested in the code viewer's
/// `ScrollView` collapses to zero height and paints nothing.
@Suite("MarkdownPaneLayout")
struct MarkdownPaneLayoutTests {

    @Test("flag off keeps a single markdown file in the scrolling stack")
    func flagOffStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md"],
            useWebView: false
        ) == false)
    }

    @Test("flag on gives a single markdown file the whole pane")
    func flagOnTakesFullPane() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md"],
            useWebView: true
        ))
    }

    @Test("the .markdown extension qualifies, case-insensitively")
    func markdownExtensionQualifies() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/NOTES.MARKDOWN"],
            useWebView: true
        ))
    }

    @Test("source-code mode never takes the pane")
    func sourceCodeModeStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: true,
            selectedFiles: ["/repo/README.md"],
            useWebView: true
        ) == false)
    }

    @Test("a non-markdown file never takes the pane")
    func nonMarkdownStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/main.swift"],
            useWebView: true
        ) == false)
    }

    @Test("a multi-file selection falls back to the scrolling stack")
    func multiFileFallsBack() {
        // Known limitation of the soak: N stacked webviews would each collapse
        // to zero height, so multi-select keeps the MarkdownUI rendering.
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md", "/repo/CHANGELOG.md"],
            useWebView: true
        ) == false)
    }

    @Test("an empty selection never takes the pane")
    func emptySelectionStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: [],
            useWebView: true
        ) == false)
    }
}
