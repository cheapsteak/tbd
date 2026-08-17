import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// Tier 1 — pure composition, no daemon, no filesystem.
///
/// Asserted on the composed output rather than on an internal flag: what an
/// operator reads is the contract.
@Suite("tbd supervise playbook rendering")
struct SupervisePlaybookRenderingTests {

    private static func view(
        tier: SupervisionPlaybookTier,
        path: String?,
        content: String = "conduct\n",
        skipped: [SupervisionPlaybookSkippedLevel] = []
    ) -> SupervisionPlaybookView {
        SupervisionPlaybookView(
            project: "acme-checkout", tier: tier, path: path,
            hash: SupervisionPlaybook.hash(of: Data(content.utf8)),
            content: content, skipped: skipped)
    }

    @Test func headerNamesTheTierThePathAndTheHash() {
        let rendered = renderSupervisionPlaybook(
            Self.view(tier: .repo, path: "/src/acme-web/.agents/supervision.md"),
            includeContent: false)
        #expect(rendered.contains("playbook: acme-checkout"))
        #expect(rendered.contains("tier: repo"))
        #expect(rendered.contains("/src/acme-web/.agents/supervision.md"))
        #expect(rendered.contains("hash: \(SupervisionPlaybook.hash(of: Data("conduct\n".utf8)))"))
        // Without --content the bytes stay out of the way.
        #expect(!rendered.contains("\nconduct"))
    }

    @Test func theShippedTierSaysSoWhereAPathWouldGo() {
        let rendered = renderSupervisionPlaybook(
            Self.view(tier: .shipped, path: nil), includeContent: false)
        #expect(rendered.contains("tier: shipped"))
        #expect(rendered.contains(supervisionShippedPlaybookPath))
    }

    @Test func contentIsAppendedWhenAskedFor() {
        let rendered = renderSupervisionPlaybook(
            Self.view(tier: .operator, path: "/tbd/repos/x/supervision.md",
                      content: "# my conduct\n"),
            includeContent: true)
        #expect(rendered.hasSuffix("# my conduct\n"))
    }

    @Test func aSkippedLevelIsNamedWithItsPathAndItsReason() throws {
        let lines = supervisionPlaybookSkipLines(Self.view(
            tier: .repo, path: "/src/acme-web/.agents/supervision.md",
            skipped: [SupervisionPlaybookSkippedLevel(
                tier: .operator, path: "/tbd/repos/x/supervision.md", reason: .empty)]))
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.contains("/tbd/repos/x/supervision.md"))
        #expect(line.contains("is empty"))
        #expect(line.contains("the repo level stands instead"))
    }

    @Test func anUnreadableLevelReadsDifferentlyFromAnEmptyOne() throws {
        let lines = supervisionPlaybookSkipLines(Self.view(
            tier: .shipped, path: nil,
            skipped: [SupervisionPlaybookSkippedLevel(
                tier: .repo, path: "/src/acme-web/.agents/supervision.md",
                reason: .unreadable)]))
        let line = try #require(lines.first)
        #expect(line.contains("could not be read"))
        #expect(!line.contains("is empty"))
    }

    @Test func nothingIsSaidWhenNoLevelWasSkipped() {
        #expect(supervisionPlaybookSkipLines(
            Self.view(tier: .operator, path: "/tbd/repos/x/supervision.md")).isEmpty)
    }

    @Test func customizeNamesThePathAndSaysItIsWrittenOnce() {
        let rendered = renderSupervisionPlaybookCustomize(SupervisePlaybookCustomizeResult(
            project: "acme-checkout", level: .operator,
            path: "/tbd/supervision/projects/acme-checkout/supervision.md",
            hash: "abc123"))
        #expect(rendered.contains("/tbd/supervision/projects/acme-checkout/supervision.md"))
        #expect(rendered.contains("hash: abc123"))
        #expect(rendered.contains("exactly once and never again"))
        #expect(rendered.contains("operator level"))
    }
}
