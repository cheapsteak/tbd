import Foundation
import Testing
@testable import TBDApp

/// Tier 1. Pure layout decision — no `UserDefaults`, no filesystem.
///
/// The decision exists because a view that scrolls itself — the rendered
/// markdown `WKWebView` or the CSV/TSV table's `NSScrollView` — nested in the
/// code viewer's `ScrollView` collapses to zero height and paints nothing.
@Suite("RichViewPaneLayout")
struct RichViewPaneLayoutTests {

    @Test("a single markdown file gets the whole pane")
    func singleMarkdownTakesFullPane() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md"]
        ))
    }

    @Test("the .markdown extension qualifies, case-insensitively")
    func markdownExtensionQualifies() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/NOTES.MARKDOWN"]
        ))
    }

    @Test("source-code mode never takes the pane")
    func sourceCodeModeStaysInScrollView() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: true,
            selectedFiles: ["/repo/README.md"]
        ) == false)
    }

    @Test("a file with no rich view never takes the pane")
    func nonMarkdownStaysInScrollView() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/main.swift"]
        ) == false)
    }

    @Test("a multi-file selection falls back to the scrolling stack")
    func multiFileFallsBack() {
        // N stacked webviews would each collapse to zero height, so a
        // multi-file selection shows markdown as highlighted source.
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/README.md", "/repo/CHANGELOG.md"]
        ) == false)
    }

    @Test("an empty selection never takes the pane")
    func emptySelectionStaysInScrollView() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: []
        ) == false)
    }

    @Test("a single csv file gets the whole pane")
    func singleCsvTakesFullPane() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/data.csv"]
        ))
    }

    @Test("the tsv extension qualifies, case-insensitively")
    func uppercaseTsvTakesFullPane() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/DATA.TSV"]
        ))
    }

    @Test("a csv file in source-code mode stays in the scrolling stack")
    func csvInSourceModeStaysInScrollView() {
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: true,
            selectedFiles: ["/repo/data.csv"]
        ) == false)
    }

    @Test("a csv file in a multi-file selection falls back to the scrolling stack")
    func csvInMultiFileSelectionFallsBack() {
        // A table stacked in the scroll view would collapse to zero height
        // too, so a multi-file selection shows it as highlighted text.
        #expect(RichViewPaneLayout.usesFullPane(
            showSourceCode: false,
            selectedFiles: ["/repo/data.csv", "/repo/other.tsv"]
        ) == false)
    }
}
