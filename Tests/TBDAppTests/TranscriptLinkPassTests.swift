// Tests/TBDAppTests/TranscriptLinkPassTests.swift
import Testing
import AppKit
@testable import TBDApp

@MainActor
struct TranscriptLinkPassTests {
    /// Resolver stub: a token in `existing` resolves to an absolute path under
    /// `/w`. Absolute is what a real resolver always returns, and it keeps the
    /// `tbd-file:` URL hierarchical so `.path` round-trips.
    private func resolver(_ existing: Set<String>) -> @MainActor (String) -> String? {
        { existing.contains($0) ? "/w/\($0)" : nil }
    }

    private func applied(
        _ string: NSMutableAttributedString, existing: Set<String>
    ) -> NSAttributedString {
        TranscriptLinkPass.apply(to: string, resolve: resolver(existing))
        return string
    }

    private func link(in s: NSAttributedString, at index: Int) -> URL? {
        s.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    @Test func resolvablePath_getsATbdFileLink() {
        let s = NSMutableAttributedString(string: "see docs/a.md now")
        let out = applied(s, existing: ["docs/a.md"])
        let url = link(in: out, at: 4)
        #expect(url?.scheme == "tbd-file")
        #expect(url?.path == "/w/docs/a.md")
    }

    @Test func unresolvablePath_getsNoLink() {
        let s = NSMutableAttributedString(string: "see docs/a.md now")
        let out = applied(s, existing: [])
        #expect(link(in: out, at: 4) == nil)
    }

    @Test func webURL_getsItsOwnURLUnchanged() {
        let s = NSMutableAttributedString(string: "go https://example.com/x now")
        let out = applied(s, existing: [])
        #expect(link(in: out, at: 3)?.absoluteString == "https://example.com/x")
    }

    @Test func proseLink_getsLinkColorAndNoUnderline() {
        let s = NSMutableAttributedString(string: "see docs/a.md")
        let out = applied(s, existing: ["docs/a.md"])
        let color = out.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.linkColor)
        #expect(out.attribute(.underlineStyle, at: 4, effectiveRange: nil) == nil)
    }

    // A candidate can straddle the boundary: `` the file `docs/a`.md `` renders
    // as one prose string whose first four characters are code and whose last
    // three are not, and the scanner sees one token across both. Styling read
    // from `range.location` alone would treat the whole token as code.
    @Test func linkStraddlingACodeBoundary_isStyledPerSubRun() {
        let s = NSMutableAttributedString(
            string: "docs/a.md", attributes: [.foregroundColor: NSColor.systemPink])
        s.addAttribute(.tbdCodeContext, value: true, range: NSRange(location: 0, length: 4))
        let out = applied(s, existing: ["docs/a.md"])

        // Code half: underlined, original color kept.
        #expect(out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
                == NSUnderlineStyle.single.rawValue)
        #expect(out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == NSColor.systemPink)
        // Prose half: tinted, no underline.
        #expect(out.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
                == NSColor.linkColor)
        #expect(out.attribute(.underlineStyle, at: 5, effectiveRange: nil) == nil)
        // One link across the whole token either way.
        #expect(link(in: out, at: 0) == link(in: out, at: 5))
    }

    @Test func codeContextLink_getsUnderlineAndKeepsItsColor() {
        let s = NSMutableAttributedString(
            string: "docs/a.md",
            attributes: [.foregroundColor: NSColor.systemPink, .tbdCodeContext: true]
        )
        let out = applied(s, existing: ["docs/a.md"])
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.systemPink)
        let underline = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.single.rawValue)
    }

    // An existing markdown link must survive untouched — no double-linking.
    @Test func existingLinkRange_isLeftAlone() {
        let s = NSMutableAttributedString(string: "docs/a.md")
        let existing = URL(string: "https://example.com/original")!
        s.addAttribute(.link, value: existing, range: NSRange(location: 0, length: s.length))
        let out = applied(s, existing: ["docs/a.md"])
        #expect(link(in: out, at: 0) == existing)
    }

    @Test func emptyString_isANoOp() {
        let s = NSMutableAttributedString(string: "")
        TranscriptLinkPass.apply(to: s, resolve: resolver([]))
        #expect(s.length == 0)
    }

    // `.path` only round-trips because the resolver always hands back an
    // absolute path — a relative one would make the `tbd-file:` URL
    // non-hierarchical and `.path` would come back empty. The builder enforces
    // that itself rather than trusting every caller, so a future caller that
    // passes a relative path gets nil instead of a link that opens nothing.
    @Test func nonAbsolutePath_makesNoFileURL() {
        #expect(TranscriptLinkPass.fileURL(forResolvedPath: "docs/a.md") == nil)
        #expect(TranscriptLinkPass.fileURL(forResolvedPath: "")  == nil)
        #expect(TranscriptLinkPass.fileURL(forResolvedPath: "/w/docs/a.md")?.path
                == "/w/docs/a.md")
    }
}
