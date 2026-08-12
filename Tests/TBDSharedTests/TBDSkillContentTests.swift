import Testing
import Foundation
@testable import TBDShared

@Test func bodyStartsWithYAMLFrontmatter() {
    let body = TBDSkillContent.body
    #expect(body.hasPrefix("---\n"))
    // Frontmatter terminator
    let rest = body.dropFirst("---\n".count)
    #expect(rest.contains("\n---\n"))
}

@Test func bodyContainsRequiredFrontmatterFields() {
    let body = TBDSkillContent.body
    #expect(body.contains("name: tbd"))
    #expect(body.contains("description:"))
}

@Test func bodyContainsExpectedWorkflowSections() {
    let body = TBDSkillContent.body
    #expect(body.contains("## Common workflows"))
    #expect(body.contains("tbd terminal create"))
    #expect(body.contains("--type codex"))
    #expect(body.contains("tbd worktree create"))
    #expect(body.contains("tbd notify"))
    #expect(body.contains("tbd link"))
    #expect(body.contains("tbd terminal send"))
    #expect(body.contains("tbd terminal output"))
    #expect(body.contains("tbd terminal focus"))
    #expect(body.contains("--activate"))
}

@Test func bodyDelegatesFlagDetailToHelp() {
    let body = TBDSkillContent.body
    // Versioning-drift mitigation: instruct the model to use --help for current flags.
    #expect(body.contains("--help"))
}

@Test func bodyContainsSiblingMessagingSection() {
    let body = TBDSkillContent.body
    #expect(body.contains("### Message a sibling session"))
    // Both channels are stated; neither is recommended over the other, so
    // both names must survive an edit of this section.
    #expect(body.contains("ListAgents"))
    #expect(body.contains("SendMessage"))
    #expect(body.contains("worktree display name"))
    #expect(body.contains("tbd terminal send"))
    #expect(body.contains("tbd terminal output"))
    // Display names are not unique — several terminals share one worktree's,
    // and worktrees in different repos can share one too — so the text must
    // point at the per-row `[ref]` as the address.
    #expect(body.contains("[ref]"))
    // Missing tools have several causes (four env killswitches, and the
    // non-Claude harnesses this same body is fed to), so the text must not
    // name one. It states the fallback instead.
    #expect(!body.contains("predates the feature"))
}

@Test func bodyContainsScratchPromotionSection() {
    let body = TBDSkillContent.body
    #expect(body.contains("## Scratch spaces & promotion"))
    #expect(body.contains("tbd scratch new"))
    #expect(body.contains("tbd scratch list"))
    #expect(body.contains("tbd scratch promote <dest-path>"))
    #expect(body.contains("--display-name"))
}
