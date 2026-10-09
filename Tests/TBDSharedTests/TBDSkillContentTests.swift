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

/// The screen paragraph tells an agent which store answered its read, and all
/// three sources have to survive an edit of it.
///
/// Pinned because the text is the only place an agent learns the distinction,
/// and it was wrong for as long as `viewer` was unreachable — it named two
/// sources and called `staleDaemon` the thing a reader should watch for. An
/// unpinned paragraph can drift back to that quietly, and the reader who pays
/// for it is an agent acting on a half-typed composer line as if it were the
/// session's settled state.
@Test func bodyNamesAllThreeScreenSources() {
    let body = TBDSkillContent.body
    #expect(body.contains("Three stores can answer"))
    // Each source's own spelling, which is also the `--json` field's value, so
    // a script correlating on one finds the other.
    #expect(body.contains("`daemon` — the daemon is reading"))
    #expect(body.contains("`viewer` — somebody has the session open"))
    #expect(body.contains("`staleDaemon` — somebody has the session open"))
    // The caveat a `viewer` answer carries, which is the one an agent gets
    // wrong: live is not the same as settled.
    #expect(body.contains("a person is at that keyboard"))
    // The two fields that carry the provenance machine-readably.
    #expect(body.contains("screen.source"))
    #expect(body.contains("screen.ageMilliseconds"))
}

@Test func bodyContainsSiblingMessagingSection() {
    let body = TBDSkillContent.body
    #expect(body.contains("### Message a sibling session"))
    // Both channels are stated; neither is recommended over the other, so
    // both names must survive an edit of this section.
    #expect(body.contains("ListAgents"))
    #expect(body.contains("SendMessage"))
    #expect(body.contains("worktree display name at spawn"))
    #expect(body.contains("tbd terminal send"))
    #expect(body.contains("tbd terminal output"))
    // The display-name correspondence is a default, not a guarantee: a session
    // spawned by a daemon without naming carries the cwd slug instead, and one
    // that outlived a rename keeps its spawn-time name. Pin the qualifier, so a
    // rewrite that restores the unconditional claim reds.
    #expect(body.contains("working-directory slug plus a short suffix"))
    // The consequence is the part sessions get wrong in the field: a flat
    // not-found reads as "the peer is dead" unless the text says otherwise.
    #expect(body.contains("No agent named 'X' is reachable."))
    #expect(body.contains("listed under a different name, not that it is dead"))
    // The recovery identifies the row by its terminal id and worktree — the
    // identity every transport carries — through `tbd peer list`, with the
    // two listings that resolve what it prints; all three legs have to survive.
    #expect(body.contains("Identify its row by its terminal id and worktree"))
    #expect(body.contains("tbd peer list"))
    #expect(body.contains("every peer TBD can see"))
    #expect(body.contains("first eight characters of its id"))
    // …and the step back to `ListAgents`, where the ref lives: the name
    // `tbd peer list` shows is what to look the row up by there.
    #expect(body.contains("is the one to look up in `ListAgents`"))
    #expect(body.contains("tbd terminal list <worktree-id>"))
    #expect(body.contains("tbd worktree list --json"))
    // A tmux pane is a legacy coordinate of tmux-transport rows, never the
    // identity: a holder-backed session has none, so text that teaches the
    // pane as the way to find a row strands every holder session. Pin the
    // demotion, and red on the old instruction coming back.
    #expect(body.contains("A tmux pane is not an identity"))
    #expect(body.contains("legacy coordinate `tmux <server>:<window>.<pane>`"))
    #expect(!body.contains("Identify its row by the tmux pane"))
    #expect(!body.contains("every TBD-spawned row prints"))
    #expect(!body.contains("TBD-spawned rows also carry a tmux pane"))
    // The `[ref]` is the address, not merely a tiebreak for ambiguous names:
    // a peer that has not been messaged before must be addressed `name [ref]`,
    // and a bare name is refused even where exactly one row answers to it.
    // Pin the addressing form and the refusal together — text that described
    // the ref as only-for-collisions would satisfy neither.
    #expect(body.contains("name [ref]"))
    #expect(body.contains("a bare name may be refused"))
    #expect(body.contains("have not messaged before"))
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

@Test func bodyDocumentsPRCommands() {
    let body = TBDSkillContent.body
    #expect(body.contains("tbd pr list"))
    #expect(body.contains("tbd pr attach"))
    #expect(body.contains("tbd pr detach"))
    // Non-obvious behaviours a caller would otherwise get wrong.
    #expect(body.contains("A detached PR stays detached"))
    #expect(body.contains("every bound PR"))
    // The hook-only entry point must not be documented as a user command.
    #expect(!body.contains("tbd pr bind"))
}
