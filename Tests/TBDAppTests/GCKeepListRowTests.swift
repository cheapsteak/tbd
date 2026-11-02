import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Captions and the Customize gate for the keep-list Settings row.
@Suite("GC keep-list row")
struct GCKeepListRowTests {
    // Discriminates: the default state must point at Customize, which the other states never do.
    @Test func shippedDefaultsCaptionOffersCustomize() {
        let text = GCKeepListRow.caption(for: .list(.shipped, .shippedDefaults))
        #expect(text.contains("shipped list"))
        #expect(text.contains("Customize"))
    }

    // Discriminates: pattern count (2) appears and the file is called "your file", not "shipped".
    @Test func fileCaptionNamesYourFileAndCount() {
        let text = GCKeepListRow.caption(for: .list(GCKeepList(patterns: ["a", "b"]), .file))
        #expect(text.contains("your file"))
        #expect(text.contains("2 pattern"))
        #expect(!text.contains("shipped"))
        #expect(!text.contains("Customize"))
    }

    // Discriminates: the reason is shown and the skip consequence is stated.
    @Test func unreadableCaptionGivesReasonAndConsequence() {
        let text = GCKeepListRow.caption(for: .unreadable(reason: "Permission denied"))
        #expect(text.contains("Permission denied"))
        #expect(text.contains("skipped"))
        #expect(!text.contains("Customize"))
    }

    // Discriminates: true only for the absent-file state; inverting or always-true fails.
    @Test func customizeIsOfferedOnlyWhileTheFileIsAbsent() {
        #expect(GCKeepListRow.canCustomize(.list(.shipped, .shippedDefaults)))
        #expect(!GCKeepListRow.canCustomize(.list(GCKeepList(patterns: []), .file)))
        #expect(!GCKeepListRow.canCustomize(.unreadable(reason: "x")))
    }
}
