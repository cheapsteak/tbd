import Foundation
import Testing
@testable import TBDApp

/// Tier 1. Pure layout decision — no `UserDefaults`, no filesystem.
///
/// The decision exists because a `WKWebView` nested in the code viewer's
/// `ScrollView` collapses to zero height and paints nothing.
@Suite("MarkdownPaneLayout")
struct MarkdownPaneLayoutTests {

    @Test("a single markdown file gets the whole pane")
    func singleMarkdownTakesFullPane() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md"]
        ))
    }

    @Test("the .markdown extension qualifies, case-insensitively")
    func markdownExtensionQualifies() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/NOTES.MARKDOWN"]
        ))
    }

    @Test("source-code mode never takes the pane")
    func sourceCodeModeStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: true,
            selectedFiles: ["/repo/README.md"]
        ) == false)
    }

    @Test("a non-markdown file never takes the pane")
    func nonMarkdownStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/main.swift"]
        ) == false)
    }

    @Test("a multi-file selection falls back to the scrolling stack")
    func multiFileFallsBack() {
        // N stacked webviews would each collapse to zero height, so a
        // multi-file selection shows markdown as highlighted source.
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md", "/repo/CHANGELOG.md"]
        ) == false)
    }

    @Test("an empty selection never takes the pane")
    func emptySelectionStaysInScrollView() {
        #expect(MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: false,
            selectedFiles: []
        ) == false)
    }
}
