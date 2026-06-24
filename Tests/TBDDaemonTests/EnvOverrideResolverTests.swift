import Testing
@testable import TBDDaemonLib

@Suite struct EnvOverrideResolverTests {
    @Test func unionAcrossScopes() {
        let merged = EnvOverrideResolver.merge(
            global: ["G": "g"], repo: ["R": "r"], profile: ["P": "p"])
        #expect(merged == ["G": "g", "R": "r", "P": "p"])
    }
    @Test func profileWinsThenRepoThenGlobal() {
        let merged = EnvOverrideResolver.merge(
            global: ["K": "global", "A": "ga"],
            repo:   ["K": "repo",   "A": "ra"],
            profile:["K": "profile"])
        #expect(merged["K"] == "profile")   // profile > repo > global
        #expect(merged["A"] == "ra")        // repo > global
    }
    @Test func nilScopesAreEmpty() {
        #expect(EnvOverrideResolver.merge(global: nil, repo: nil, profile: nil) == [:])
    }

    // Mirrors the merge order in WorktreeLifecycle+Create.swift Task 7 Step 3:
    // the Claude builder's auth/routing env is layered ON TOP of the merged
    // free-form overrides, so it stays final and free-form vars can't clobber it.
    @Test func claudeBuilderEnvWinsOverFreeForm() {
        // Free-form tries to set AWS_REGION; builder (bedrock) also sets it → builder wins.
        let freeForm = ["AWS_REGION": "us-east-1", "EXTRA": "x"]
        let builder  = ["AWS_REGION": "us-west-2", "CLAUDE_CODE_USE_BEDROCK": "1"]
        let final = freeForm.merging(builder) { _, b in b }
        #expect(final["AWS_REGION"] == "us-west-2")   // auth/routing stays final
        #expect(final["EXTRA"] == "x")                // free-form preserved
    }
}
