import Testing
import Foundation
@testable import TBDApp

struct TranscriptLinkScannerTests {
    private func tokens(_ text: String) -> [String] {
        TranscriptLinkScanner.scan(text).map(\.token)
    }

    private func urlFlags(_ text: String) -> [Bool] {
        TranscriptLinkScanner.scan(text).map(\.isURL)
    }

    @Test func emptyString_yieldsNothing() {
        #expect(TranscriptLinkScanner.scan("").isEmpty)
    }

    @Test func proseWithoutCandidates_yieldsNothing() {
        #expect(tokens("just some prose with no paths at all").isEmpty)
    }

    @Test func absolutePath_isFound() {
        #expect(tokens("see /work/tree/CLAUDE.md now") == ["/work/tree/CLAUDE.md"])
    }

    @Test func relativePathWithSlash_isFound() {
        #expect(tokens("see docs/nightwatch.md now") == ["docs/nightwatch.md"])
    }

    @Test func bareFilenameWithExtension_isFound() {
        #expect(tokens("open CLAUDE.md") == ["CLAUDE.md"])
    }

    @Test func plainWordWithoutSlashOrExtension_isNotACandidate() {
        #expect(tokens("open the docs folder").isEmpty)
    }

    @Test func trailingSentencePeriod_isExcludedFromToken() {
        #expect(tokens("the spec lives at docs/nightwatch.md.") == ["docs/nightwatch.md"])
    }

    // The slash-less version of the same sentence. The shape test runs on the
    // trimmed extent, so ending a sentence does not cost the file its
    // extension — and with it, its candidacy.
    @Test func bareFilenameEndingASentence_isFound() {
        #expect(tokens("everything is in CLAUDE.md.") == ["CLAUDE.md"])
    }

    @Test func trailingCommaAndParen_areExcluded() {
        #expect(tokens("(see docs/a.md), then") == ["docs/a.md"])
    }

    @Test func lineSuffix_staysInsideToken() {
        #expect(tokens("at Sources/A.swift:17 here") == ["Sources/A.swift:17"])
    }

    @Test func lineAndColumnSuffix_staysInsideToken() {
        #expect(tokens("at /w/CLAUDE.md:3:1 here") == ["/w/CLAUDE.md:3:1"])
    }

    // Grep and compiler output paste `path:line:text` into code blocks. Widening
    // through that second colon would swallow the first word of the matched line
    // and link nothing, so a colon only extends the token when a digit follows it.
    @Test func grepShapedToken_stopsAfterTheLineNumber() {
        #expect(tokens("Sources/A.swift:17:let x = 1").first == "Sources/A.swift:17")
    }

    // The colon must be INTERIOR to discriminate: a trailing `docs/a.md: ` is
    // already handled by the trailing-punctuation trim, so a spaced fixture
    // passes with or without the colon-digit boundary rule.
    @Test func interiorColonFollowedByProse_endsTheToken() {
        #expect(tokens("see docs/a.md:the spec") == ["docs/a.md"])
    }

    @Test func httpsURL_isFoundAndFlaggedAsURL() {
        #expect(tokens("go to https://example.com/x now") == ["https://example.com/x"])
        #expect(urlFlags("go to https://example.com/x now") == [true])
    }

    @Test func fileURL_isFoundAndFlaggedAsPath() {
        // A file:// token resolves through the path resolver, not NSWorkspace.
        #expect(tokens("open file:///w/CLAUDE.md") == ["file:///w/CLAUDE.md"])
        #expect(urlFlags("open file:///w/CLAUDE.md") == [false])
    }

    @Test func urlTrailingPeriod_isExcluded() {
        #expect(tokens("see https://example.com/x.") == ["https://example.com/x"])
    }

    // `!` and `?` are legal in a hostname, so leaving them attached sends the
    // click to a host that does not exist.
    @Test func urlTrailingBangOrQuestionMark_isExcluded() {
        #expect(tokens("see https://example.com!") == ["https://example.com"])
        #expect(tokens("have you seen https://example.com?") == ["https://example.com"])
    }

    @Test func urlIsNotSplitIntoPathCandidates() {
        // The `//example.com/x` inside a URL must not surface as a second candidate.
        #expect(TranscriptLinkScanner.scan("see https://example.com/x").count == 1)
    }

    @Test func multipleCandidates_areReturnedInOrder() {
        #expect(tokens("a docs/a.md b /w/b.md c https://e.com/c")
                == ["docs/a.md", "/w/b.md", "https://e.com/c"])
    }

    @Test func ranges_pointAtTheTokenInTheOriginalString() {
        let text = "see docs/a.md now"
        let found = TranscriptLinkScanner.scan(text)
        #expect(found.count == 1)
        let ns = text as NSString
        #expect(ns.substring(with: found[0].range) == "docs/a.md")
    }

    // Emoji ahead of the token: NSRange is UTF-16, so a non-BMP scalar must not
    // shift the reported range.
    @Test func ranges_areUTF16Correct_afterNonBMPCharacter() {
        let text = "🚀 docs/a.md"
        let found = TranscriptLinkScanner.scan(text)
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range) == "docs/a.md")
    }

    // MARK: - Token starts that are not whitespace

    // A flag argument. `=` is the boundary agents write most often inside code
    // blocks, and a whitespace-only start rule skips the path entirely.
    @Test func pathAfterAnEqualsSign_isFound() {
        #expect(tokens("run --file=docs/a.md now") == ["docs/a.md"])
    }

    @Test func commaSeparatedPaths_areBothFound() {
        #expect(tokens("cat a.md,b.md") == ["a.md", "b.md"])
    }

    // MARK: - Shapes that must be candidates

    @Test func dotfile_isACandidate() {
        #expect(tokens("edit .gitignore first") == [".gitignore"])
    }

    // A digit-bearing extension is still an extension. `Package.resolved` also
    // pins that the length cap is not four characters.
    @Test func extensionsWithDigits_areCandidates() {
        #expect(tokens("Package.resolved") == ["Package.resolved"])
        #expect(tokens("clip a.mp4 and x.7z") == ["a.mp4", "x.7z"])
    }

    // Deliberate exclusion, documented in `looksLikeAPath`: no dot and no slash
    // means no candidate, which is the rule that keeps every English word off
    // the filesystem. Real extension-less files pay for it.
    @Test func extensionlessFilename_isNotACandidate() {
        #expect(tokens("edit the Makefile and the LICENSE").isEmpty)
    }

    // MARK: - Trailing punctuation

    @Test func urlWithBalancedParens_keepsItsClosingParen() {
        #expect(tokens("see https://en.wikipedia.org/wiki/Foo_(bar) here")
                == ["https://en.wikipedia.org/wiki/Foo_(bar)"])
    }

    @Test func urlWithAnUnbalancedClosingParen_dropsIt() {
        #expect(tokens("(see https://example.com/x) here") == ["https://example.com/x"])
    }

    // MARK: - Shape versus resolution

    // Honest accounting of the classic false positives. Three of them ARE
    // shape-candidates and the design accepts that: `Node.js` and `e.g.` end in
    // a letter run, `and/or` and `24/7` contain a slash, and nothing about
    // their shape distinguishes them from `a.js` or `docs/api`. They cost one
    // `stat()` each and then fail to resolve, so no link appears. Only a
    // digits-only extension is cheap to rule out by shape, and `v1.2.3` — the
    // one that actually recurs in transcripts — is exactly that.
    @Test func versionNumber_isNotACandidate() {
        #expect(tokens("bumped to v1.2.3 today").isEmpty)
    }

    @Test func prosePunctuationLookalikes_areCandidatesThatWillNotResolve() {
        #expect(tokens("Node.js") == ["Node.js"])
        #expect(tokens("and/or") == ["and/or"])
        #expect(tokens("24/7") == ["24/7"])
        // The trailing period is trimmed before the shape test, leaving `e.g`
        // — a one-letter extension, indistinguishable in shape from `main.c`.
        #expect(tokens("e.g. this") == ["e.g"])
    }

    // A directory IS a candidate by shape. The resolver rejects it later — it
    // requires an existing file that is not a directory — which is where that
    // rule belongs: the scanner has no filesystem.
    @Test func bareDirectory_isACandidate() {
        #expect(tokens("look in docs/ for it") == ["docs/"])
    }
}
