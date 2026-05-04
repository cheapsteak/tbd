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
    #expect(body.contains("tbd worktree create"))
    #expect(body.contains("tbd notify"))
    #expect(body.contains("tbd link"))
    #expect(body.contains("tbd terminal send"))
    #expect(body.contains("tbd terminal output"))
}

@Test func bodyDelegatesFlagDetailToHelp() {
    let body = TBDSkillContent.body
    // Versioning-drift mitigation: instruct the model to use --help for current flags.
    #expect(body.contains("--help"))
}

@Test func bodyHashIsStableAcrossCalls() {
    #expect(TBDSkillContent.bodyHash() == TBDSkillContent.bodyHash())
}

@Test func bodyHashIsHexEncoded64Chars() {
    let hash = TBDSkillContent.bodyHash()
    #expect(hash.count == 64)
    #expect(hash.allSatisfy { $0.isHexDigit })
}
