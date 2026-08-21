import Foundation
import Testing
@testable import TBDShared

/// Tier 1. `Worktree.pendingPromptSubmitResolved` is the single answer to
/// "does delivering this prompt press Enter", shared by the daemon's delivery
/// path and by the read-back sheet that tells the operator what delivery will
/// do. These pin the answer itself; the two consumers are pinned in
/// `QueuedPromptDeliveryTests` and `ParkedPromptReadbackTests`.
@Suite("Pending prompt submit resolution")
struct PendingPromptSubmitResolutionTests {

    /// Always names `pendingPromptSubmit`, including for the nil case — the
    /// initializer defaults it to nil, so an omitted argument would make the
    /// case under test indistinguishable from an oversight.
    private func worktree(submit: Bool?) -> Worktree {
        Worktree(
            repoID: UUID(), name: "wt", displayName: "wt", branch: "tbd/wt",
            path: "/tmp/wt", tmuxServer: "tbd-test",
            pendingPrompt: "do the thing",
            pendingPromptSubmit: submit)
    }

    @Test("An absent bit resolves to: do not press Enter")
    func absentResolvesToFalse() {
        let wt = worktree(submit: nil)
        #expect(wt.pendingPromptSubmit == nil)
        #expect(wt.pendingPromptSubmitResolved == false)
    }

    @Test("An explicit choice is returned as recorded")
    func explicitChoiceIsReturned() {
        #expect(worktree(submit: false).pendingPromptSubmitResolved == false)
        #expect(worktree(submit: true).pendingPromptSubmitResolved == true)
    }

    /// The same resolution, arrived at through the decoder rather than the
    /// initializer. The JSON is hand-built and no daemon emits it — one old
    /// enough to omit the submit key omits `pendingPrompt` with it — so what is
    /// pinned is that an absent key decodes to nil and resolves exactly as an
    /// explicit nil does: staged, not sent.
    @Test("JSON that omits the key resolves to: do not press Enter")
    func jsonWithoutTheKeyResolvesToFalse() throws {
        let json = """
        {"id":"88888888-8888-8888-8888-888888888888","name":"w","displayName":"w",
         "branch":"b","path":"/tmp/x","status":"active","createdAt":0,
         "tmuxServer":"srv","pendingPrompt":"do the thing"}
        """
        let decoded = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        #expect(decoded.pendingPromptSubmit == nil)
        #expect(decoded.pendingPromptSubmitResolved == false)
    }
}
