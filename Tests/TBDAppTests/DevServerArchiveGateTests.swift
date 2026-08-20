import Foundation
import TBDShared
import Testing

@testable import TBDApp

private func makeWorktree(
    id: UUID = UUID(),
    displayName: String = "my-feature",
    localPath: String = "/tmp/wt"
) -> Worktree {
    Worktree(
        id: id,
        repoID: UUID(),
        name: "wt",
        displayName: displayName,
        branch: "main",
        path: localPath,
        status: .active,
        tmuxServer: "test-server"
    )
}

/// The branch that decides whether a destructive action happens.
///
/// Separated from `archiveWorktree` so each arm is reachable without standing up
/// a daemon — the same reason `archiveShortcutRoute` is a pure seam. Every arm
/// below is a way the archive can proceed *without* asking, and each one is a
/// decision rather than a default, so each gets its own case.
@Suite("dev-server archive gate")
struct DevServerArchiveGateTests {

    @Test func holdsTheArchiveWhenAServerIsRunning() {
        let id = UUID()
        let held = AppState.devServerArchiveGate(
            worktree: makeWorktree(id: id, displayName: "my-feature"),
            devServersConfirmed: false,
            force: false,
            runningServers: { _ in ["storybook", "dev"] }
        )
        #expect(held?.worktreeID == id)
        #expect(held?.worktreeName == "my-feature")
        #expect(held?.servers == ["storybook", "dev"])
    }

    @Test func proceedsWhenNothingIsRunning() {
        let held = AppState.devServerArchiveGate(
            worktree: makeWorktree(),
            devServersConfirmed: false,
            force: false,
            runningServers: { _ in [] }
        )
        #expect(held == nil)
    }

    /// The question has been answered. Re-asking would make the second click
    /// appear to do nothing, and the prompt would be unescapable.
    @Test func proceedsOnceConfirmedEvenWithServersStillRunning() {
        let held = AppState.devServerArchiveGate(
            worktree: makeWorktree(),
            devServersConfirmed: true,
            force: false,
            runningServers: { _ in ["dev"] }
        )
        #expect(held == nil)
    }

    /// A remote row's `localPath` is the synthetic `remote://…` URI, not a
    /// filesystem path. A registry on this machine cannot speak for a worktree
    /// on another one, so the gate does not consult it at all — rather than
    /// consulting it and relying on the comparison never matching.
    @Test func proceedsForARemoteRowWithoutConsultingTheRegistry() {
        var consulted = false
        let held = AppState.devServerArchiveGate(
            worktree: makeWorktree(localPath: "remote://provider/session-id"),
            devServersConfirmed: false,
            force: false,
            runningServers: { _ in
                consulted = true
                return ["dev"]
            }
        )
        #expect(held == nil)
        #expect(consulted == false, "a remote row must not be looked up in a local registry")
    }

    @Test func proceedsWhenThereIsNoWorktree() {
        let held = AppState.devServerArchiveGate(
            worktree: nil,
            devServersConfirmed: false,
            force: false,
            runningServers: { _ in ["dev"] }
        )
        #expect(held == nil)
    }

    /// The gate asks about the worktree it was given, not some other path.
    @Test func looksUpTheWorktreesOwnPath() {
        var asked: String?
        _ = AppState.devServerArchiveGate(
            worktree: makeWorktree(localPath: "/tmp/some-worktree"),
            devServersConfirmed: false,
            force: false,
            runningServers: { path in
                asked = path
                return []
            }
        )
        #expect(asked == "/tmp/some-worktree")
    }

    /// A scratch space is a real directory that can host a dev server, and
    /// archiving one closes its terminals just the same. The gate must see it —
    /// `archiveWorktree` used to delegate scratch rows before running the check,
    /// which made the guarantee true only for rows belonging to a repo.
    @Test func aScratchRowIsGatedLikeAnyOther() {
        let scratch = Worktree(
            id: UUID(),
            repoID: nil,
            name: "scratch",
            displayName: "Scratch",
            branch: "main",
            path: "/tmp/scratch-wt",
            status: .active,
            tmuxServer: "test-server"
        )
        #expect(scratch.isScratch)
        let held = AppState.devServerArchiveGate(
            worktree: scratch,
            devServersConfirmed: false,
            force: false,
            runningServers: { _ in ["dev"] }
        )
        #expect(held?.servers == ["dev"])
    }

    /// `force` means "skip the archive hook". It has to survive the round trip
    /// so confirming re-issues the SAME archive; flipping it here would run, or
    /// skip, a repo's hook against the user's intent.
    @Test func forceIsCarriedIntoTheHeldArchive() {
        for force in [true, false] {
            let held = AppState.devServerArchiveGate(
                worktree: makeWorktree(),
                devServersConfirmed: false,
                force: force,
                runningServers: { _ in ["dev"] }
            )
            #expect(held?.force == force)
        }
    }
}
