import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp

/// Tier 2: the two teardown paths that must reclaim a tmux **view session**,
/// driven against a recording command runner instead of a tmux server.
///
/// Every viewed panel gets its own `tbd-view-<panel prefix>` session with the
/// worktree's window linked into it, and tmux destroys a window only when the
/// last session referencing it goes away — so a view session nobody kills
/// keeps that window, its pane process and the whole tmux server alive after
/// the owning `main` session is gone. `TmuxBridge` also kills the view
/// session's own initial window, so a leaked one holds nothing *but* linked
/// worktree windows.
///
/// The two paths, and why each has a test:
///
/// - **Coordinator release.** `cleanup()` runs only from `dismantleNSView`,
///   which SwiftUI does not guarantee to run; the bridge log recorded 15
///   `PANEL: deinit` lines in 35 seconds with no matching `PANEL: cleanup`.
///   `deinit` therefore reclaims the session itself, relying on
///   `cleanupSession`'s idempotence so a normal dismantle still kills once.
/// - **App termination.** `applicationWillTerminate` has to *block* on the
///   kills; a detached task does not outlive the process.
/// - **A preparation that lands after teardown.** `prepareSession` registers
///   the session with the bridge before its caller records the generation, so
///   a teardown that lands inside that window leaves an entry neither
///   `cleanup()` nor `deinit` can name. The preparation reclaims it itself.
///
/// Both per-panel paths are scoped to the generation their own
/// `prepareSession` minted, because `panelID` alone does not identify a
/// preparation — see `supersededCoordinatorReleaseSparesTheRebuiltViewSession`.
/// The termination path deliberately is not: it reclaims everything tracked.
@Suite("tmux view sessions are reclaimed on every teardown path")
struct TerminalViewSessionReclamationTests {
    private static let panelID = UUID(uuidString: "4C4F1A61-F385-46AB-861D-42A425DB427B")!
    private static let sessionName = "tbd-view-4c4f1a61"

    /// A prepared bridge plus the runner recording what it asked tmux to do,
    /// and the generation each preparation minted — the token its teardown has
    /// to carry back.
    /// `prepareSession` issues a pre-emptive `kill-session` of its own, so the
    /// runner's log is cleared once preparation has finished: everything left
    /// in it afterwards was issued by a teardown.
    private func makePreparedBridge(
        fixture: TmuxBridgeFixture,
        panels: [(panelID: UUID, server: String, windowID: String)]
    ) async throws -> (bridge: TmuxBridge, runner: RecordingTmuxRunner, generations: [UInt64]) {
        let runner = RecordingTmuxRunner()
        let bridge = TmuxBridge(
            tmuxExecutableResolver: try fixture.resolvingResolver(),
            commandRunner: { _, server, args in await runner.run(server: server, args: args) }
        )
        var generations: [UInt64] = []
        for panel in panels {
            generations.append(try await bridge.prepareSession(
                panelID: panel.panelID,
                server: panel.server,
                windowID: panel.windowID
            ).get().generation)
        }
        await runner.forgetInvocations()
        return (bridge, runner, generations)
    }

    /// **The test that pins the bug.** Releasing the coordinator without ever
    /// calling `cleanup()` is exactly what SwiftUI does when it skips
    /// `dismantleNSView`, and before the fix nothing killed the session.
    @Test("releasing a panel coordinator without dismantle still kills its view session")
    func coordinatorReleaseWithoutDismantleKillsViewSession() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let (bridge, runner, generations) = try await makePreparedBridge(
            fixture: fixture,
            panels: [(Self.panelID, "tbd-repo", "@147")]
        )

        autoreleasepool {
            var coordinator: TerminalPanelRepresentable.Coordinator? =
                TerminalPanelRepresentable.Coordinator()
            coordinator?.tmuxBridge = bridge
            coordinator?.tmuxServer = "tbd-repo"
            coordinator?.panelID = Self.panelID
            coordinator?.viewSessionReclaim.publish(bridge: bridge, generation: generations[0])
            // No `cleanup()`, no `dismantleNSView` — only ARC.
            coordinator = nil
        }

        let kills = try await runner.awaitKillSessions(
            atLeast: 1,
            describedAs: "the view session for a coordinator released without dismantle"
        )
        #expect(kills == [
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
        ])
    }

    /// The idempotence half. `deinit` does not consult `cleanup()`'s
    /// `isTornDown` flag (it is `@MainActor`-confined); it relies on the
    /// bridge having already removed the panel from `activeSessions`.
    ///
    /// One observation settles this: both teardown steps run to the point of
    /// deciding whether to spawn a kill *before* the wait below starts, so no
    /// later invocation can appear — a second kill would already be recorded
    /// or already be impossible.
    @Test("a cleaned-up coordinator that is then released kills its session exactly once")
    func cleanedUpCoordinatorReleaseDoesNotKillTwice() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let (bridge, runner, generations) = try await makePreparedBridge(
            fixture: fixture,
            panels: [(Self.panelID, "tbd-repo", "@147")]
        )

        var coordinator: TerminalPanelRepresentable.Coordinator? =
            TerminalPanelRepresentable.Coordinator()
        coordinator?.tmuxBridge = bridge
        coordinator?.tmuxServer = "tbd-repo"
        coordinator?.panelID = Self.panelID
        coordinator?.viewSessionReclaim.publish(bridge: bridge, generation: generations[0])
        await MainActor.run { [coordinator] in
            coordinator?.cleanup()
        }
        coordinator = nil

        let kills = try await runner.awaitKillSessions(
            atLeast: 1,
            describedAs: "the view session of a coordinator torn down and then released"
        )
        #expect(kills.count == 1)
        #expect(kills.first?.args == TmuxBridge.killSessionArgs(sessionName: Self.sessionName))
    }

    /// The terminate path, end to end through the delegate method the app
    /// actually implements — and across two servers, because `activeSessions`
    /// spans every server the app has a panel on while each kill has to reach
    /// the socket its own session lives on.
    ///
    /// `applicationWillTerminate` blocks while the kills run, and it is
    /// `@MainActor`-isolated, so this test blocks the main thread exactly as
    /// production does. That is safe here and cannot wedge the pool
    /// (`Tests/CLAUDE.md`, "Thread-blocking gates run off the cooperative
    /// pool"): the main thread is not a cooperative-pool thread, so the kill
    /// task that releases the wait always has somewhere to run — and the wait
    /// is bounded by `cleanupAllSessionsBlocking`'s own timeout regardless.
    @Test("applicationWillTerminate reclaims tracked view sessions on every server")
    func terminateReclaimsSessionsAcrossServers() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let secondPanelID = UUID(uuidString: "9B2E77C0-1111-4222-8333-444455556666")!
        let (bridge, runner, _) = try await makePreparedBridge(
            fixture: fixture,
            panels: [
                (Self.panelID, "tbd-repo-one", "@147"),
                (secondPanelID, "tbd-repo-two", "@201"),
            ]
        )

        await MainActor.run {
            let delegate = AppDelegate()
            delegate.tmuxBridge = bridge
            delegate.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification))
        }

        let kills = try await runner.awaitKillSessions(
            atLeast: 2,
            describedAs: "both tracked view sessions on the terminate path"
        )
        #expect(Set(kills) == [
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo-one",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo-two",
                args: TmuxBridge.killSessionArgs(
                    sessionName: TmuxBridge.sessionName(for: secondPanelID))
            ),
        ])
    }

    /// **The test that pins the generation bug.** `panelID` is the *terminal's*
    /// id and is stable across SwiftUI view rebuilds, so it does not identify a
    /// preparation: `PanePlaceholder` keys the terminal view on
    /// `"\(terminal.id)-\(terminal.tmuxWindowID)-\(terminal.isParked)"`, and
    /// waking a parked terminal flips `isParked`, mints a fresh `Coordinator`
    /// and prepares the panel again. The superseded coordinator is released
    /// afterwards — from `deinit`, which fires later and less predictably than
    /// `dismantleNSView` — and before the fix its teardown removed and killed
    /// whatever `activeSessions` held for that `panelID`, which by then was the
    /// *new* coordinator's session. Symptom: the freshly woken terminal is dead.
    @Test("a superseded coordinator's release does not kill the rebuilt panel's view session")
    func supersededCoordinatorReleaseSparesTheRebuiltViewSession() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        // The same panel prepared twice — exactly what the rebuild does.
        let (bridge, runner, generations) = try await makePreparedBridge(
            fixture: fixture,
            panels: [
                (Self.panelID, "tbd-repo", "@147"),
                (Self.panelID, "tbd-repo", "@147"),
            ]
        )

        autoreleasepool {
            var superseded: TerminalPanelRepresentable.Coordinator? =
                TerminalPanelRepresentable.Coordinator()
            superseded?.tmuxBridge = bridge
            superseded?.tmuxServer = "tbd-repo"
            superseded?.panelID = Self.panelID
            superseded?.viewSessionReclaim.publish(bridge: bridge, generation: generations[0])
            superseded = nil
        }

        // One-sided negative, and sound because `cleanupSession` decides
        // whether to kill synchronously under the bridge's lock before it
        // returns: a teardown that wrongly matched has already spawned its kill
        // task by now, and the settle window only has to cover that task being
        // scheduled. A stray landing after the window still fails the exact-set
        // assertion below, which re-reads every kill recorded.
        let strayKills = await runner.killSessionsAfterSettling(for: .milliseconds(250))
        #expect(strayKills == [])

        // And the fresh preparation is still tracked: its own teardown still
        // finds an entry to reclaim. (Before the fix the superseded release had
        // already removed it, so this kill never happened.)
        bridge.cleanupSession(panelID: Self.panelID, generation: generations[1])
        let kills = try await runner.awaitKillSessions(
            atLeast: 1,
            describedAs: "the rebuilt panel's view session on its own teardown"
        )
        #expect(kills == [
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
        ])
    }

    /// The ordinary path, unchanged by generation scoping: a teardown carrying
    /// the generation of the preparation it belongs to reclaims that session,
    /// exactly once.
    @Test("a teardown carrying its own preparation's generation kills that view session once")
    func matchingGenerationTeardownKillsTheViewSession() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let (bridge, runner, generations) = try await makePreparedBridge(
            fixture: fixture,
            panels: [(Self.panelID, "tbd-repo", "@147")]
        )

        bridge.cleanupSession(panelID: Self.panelID, generation: generations[0])

        let kills = try await runner.awaitKillSessions(
            atLeast: 1,
            describedAs: "the view session torn down by its own preparation's generation"
        )
        #expect(kills == [
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
        ])
    }

    /// **The test that pins the wrong-socket bug.** A tmux session exists on
    /// exactly one server socket, and the bridge already records which one when
    /// it prepares the session. A teardown that carried its caller's idea of
    /// the server instead would remove the tracked entry — the only handle
    /// anything has on that session — and then send `kill-session` to a socket
    /// that has no such session: the view session survives with nothing left
    /// able to reclaim it, holding its linked worktree window, that window's
    /// pane process and the whole tmux server alive.
    ///
    /// A coordinator whose `tmuxServer` disagrees with the preparation is the
    /// reachable shape: the field is assigned when SwiftUI makes the view,
    /// while the server the preparation actually ran against is the one the
    /// bridge recorded.
    @Test("a teardown kills on the session's own server, not the one its caller holds")
    func teardownKillsOnThePreparationsServerNotTheCallers() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let (bridge, runner, generations) = try await makePreparedBridge(
            fixture: fixture,
            panels: [(Self.panelID, "tbd-repo-actual", "@147")]
        )

        autoreleasepool {
            var coordinator: TerminalPanelRepresentable.Coordinator? =
                TerminalPanelRepresentable.Coordinator()
            coordinator?.tmuxBridge = bridge
            // Disagrees with the server the session was prepared on.
            coordinator?.tmuxServer = "tbd-repo-stale"
            coordinator?.panelID = Self.panelID
            coordinator?.viewSessionReclaim.publish(bridge: bridge, generation: generations[0])
            coordinator = nil
        }

        let kills = try await runner.awaitKillSessions(
            atLeast: 1,
            describedAs: "the view session of a coordinator holding a stale server name"
        )
        #expect(kills == [
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo-actual",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
        ])
    }

    /// **The test that pins the in-flight-preparation leak.** `cleanup()` can
    /// run while `prepareSession` is suspended: the panel's `Task` starts the
    /// preparation, tmux takes a while, and the user closes the tab. The
    /// post-await torn-down guard then returns *before* the `.startViewer`
    /// branch that publishes the generation — but `prepareSession` has
    /// already registered the session with the bridge. Neither `cleanup()`
    /// (already run, generation still nil) nor `deinit` (nil forever) can
    /// name it, so nothing reclaims the view session, the linked worktree
    /// window, or that window's pane process.
    ///
    /// The interleave is real rather than simulated: the injected runner holds
    /// the preparation's last tmux command until the test has torn the
    /// coordinator down, so the suspension the bug needs is the one under test.
    /// It awaits rather than blocking a thread, so no cooperative-pool thread
    /// is parked (`Tests/CLAUDE.md`, "Thread-blocking gates run off the
    /// cooperative pool"), and every wait carries a deadline.
    ///
    /// Two kills are expected, not one: `prepareSession` opens with a
    /// pre-emptive `kill-session` of any leftover session under the same name,
    /// and that is indistinguishable from a teardown's kill by arguments
    /// alone. Before the fix only the pre-emptive one is ever recorded.
    @MainActor
    @Test("a preparation that completes after teardown reclaims its own view session")
    func preparationCompletingAfterTeardownReclaimsItsSession() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let runner = RecordingTmuxRunner()
        // The verification query is preparation's last command, so holding it
        // parks the preparation with everything else already done.
        await runner.hold(command: "display-message")
        let bridge = TmuxBridge(
            tmuxExecutableResolver: try fixture.resolvingResolver(),
            commandRunner: { _, server, args in await runner.run(server: server, args: args) }
        )

        let terminalView = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(
                defaults: UserDefaults(
                    suiteName: "TerminalViewSessionReclamationTests.inFlightPreparation")!)
        )
        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.tmuxBridge = bridge
        coordinator.tmuxServer = "tbd-repo"
        coordinator.panelID = Self.panelID

        let preparing = Task { @MainActor in
            await coordinator.startTmuxClient(
                terminalView: terminalView,
                bridge: bridge,
                server: "tbd-repo",
                windowID: "@147",
                panelID: Self.panelID
            )
        }

        // Awaiting here hands the main actor back, which is what lets the
        // preparation above run far enough to reach the held command.
        try await runner.awaitHold(
            describedAs: "the in-flight preparation this teardown has to race")
        coordinator.cleanup()
        await runner.release()
        await preparing.value

        let kills = try await runner.awaitKillSessions(
            atLeast: 2,
            describedAs: "the view session of a preparation that completed after teardown"
        )
        #expect(kills == [
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
            RecordingTmuxRunner.Invocation(
                server: "tbd-repo",
                args: TmuxBridge.killSessionArgs(sessionName: Self.sessionName)
            ),
        ])
    }

    /// The holder exists so that what the `@MainActor` preparation publishes is
    /// visible to a `deinit` running on whatever thread drops the last strong
    /// reference. Publish from the main actor, read from a plain dispatch
    /// queue — never from a cooperative-pool thread, which this must not park
    /// (`Tests/CLAUDE.md`, "Thread-blocking gates run off the cooperative
    /// pool").
    ///
    /// A stale read here is the silent failure the lock rules out: `deinit`
    /// would see `nil`, skip `cleanupSession`, and leak the view session with
    /// no diagnostic anywhere.
    @Test("a preparation published on the main actor is readable from another thread")
    func publishedPreparationIsReadableOffTheMainThread() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let bridge = TmuxBridge(
            tmuxExecutableResolver: try fixture.resolvingResolver(),
            commandRunner: { _, _, _ in TmuxCommandOutcome(success: true, output: "") }
        )
        let reclaim = ViewSessionReclaim()

        await MainActor.run { reclaim.publish(bridge: bridge, generation: 7) }

        let observed: UInt64? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: reclaim.published?.generation)
            }
        }
        #expect(observed == 7)
    }
}

/// Records every tmux invocation with the server it targeted, and answers
/// preparation's one query so `prepareSession` can succeed without a tmux.
private actor RecordingTmuxRunner {
    struct Invocation: Sendable, Equatable, Hashable {
        let server: String
        let args: [String]
    }

    private var invocations: [Invocation] = []
    /// Window linked into each view session, learned from `link-window`, so
    /// preparation's verification query can be answered truthfully.
    private var linkedWindows: [String: String] = [:]
    /// tmux subcommand to park on, so a test can interleave work with a
    /// preparation that is genuinely mid-flight.
    private var heldCommand: String?
    private var holdWasReached = false
    private var holdWasReleased = false

    /// Park the next invocation of `command` until `release()`. The hold
    /// *awaits* — actors are reentrant across suspension, so `release()` and
    /// `awaitHold()` still run while an invocation sits here, and no thread is
    /// blocked.
    func hold(command: String) {
        heldCommand = command
    }

    func release() {
        holdWasReleased = true
    }

    /// Bounded wait for the held command to be reached. Throws a described
    /// error rather than recording an `#expect` failure, so the diagnostic
    /// reaches the CI summary's primary failure line.
    func awaitHold(
        describedAs subject: String,
        within deadline: Duration = .seconds(10)
    ) async throws {
        for _ in 0..<attempts(for: deadline) {
            if holdWasReached { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw HoldNeverReached(subject: subject, command: heldCommand, after: deadline)
    }

    func run(server: String, args: [String]) async -> TmuxCommandOutcome {
        invocations.append(Invocation(server: server, args: args))
        if let heldCommand, args.first == heldCommand, !holdWasReleased {
            holdWasReached = true
            for _ in 0..<attempts(for: .seconds(10)) where !holdWasReleased {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        switch args.first {
        case "link-window":
            // ["link-window", "-s", <windowID>, "-t", "<session>:"]
            if args.count >= 5 {
                linkedWindows[String(args[4].dropLast())] = args[2]
            }
            return TmuxCommandOutcome(success: true, output: "")
        case "display-message":
            // ["display-message", "-p", "-t", <session>, "#{window_id}"] —
            // preparation requires the answer to match the linked window.
            let sessionName = args.count >= 4 ? args[3] : ""
            return TmuxCommandOutcome(success: true, output: linkedWindows[sessionName] ?? "")
        default:
            return TmuxCommandOutcome(success: true, output: "")
        }
    }

    func forgetInvocations() {
        invocations.removeAll()
    }

    /// Every `kill-session` recorded once the process has been left to run for
    /// `window` — the negative counterpart of `awaitKillSessions`, for
    /// asserting that a teardown killed *nothing*. One-sided by construction;
    /// pair it with a positive assertion that re-reads the full list.
    func killSessionsAfterSettling(for window: Duration) async -> [Invocation] {
        try? await Task.sleep(for: window)
        return killSessions
    }

    /// Bounded wait for kills that teardown issues off the caller's thread
    /// (`cleanupSession` kills from a detached task).
    ///
    /// Returns every `kill-session` recorded, so a caller can assert an exact
    /// set rather than only a lower bound. Throws a described error rather
    /// than recording an `#expect` failure: a bounded-wait diagnostic is the
    /// whole finding, and only a thrown error reaches the CI summary's primary
    /// failure line (`Tests/CLAUDE.md`, "Assertion hygiene").
    func awaitKillSessions(
        atLeast count: Int,
        describedAs subject: String,
        within deadline: Duration = .seconds(10)
    ) async throws -> [Invocation] {
        let pollInterval = Duration.milliseconds(10)
        let deadlineSeconds = Double(deadline.components.seconds)
            + Double(deadline.components.attoseconds) / 1e18
        let attempts = max(1, Int(deadlineSeconds / 0.01))
        for _ in 0..<attempts {
            let kills = killSessions
            if kills.count >= count { return kills }
            try? await Task.sleep(for: pollInterval)
        }
        throw MissingKillSessions(
            subject: subject,
            expected: count,
            observed: killSessions,
            allInvocations: invocations,
            after: deadline
        )
    }

    private var killSessions: [Invocation] {
        invocations.filter { $0.args.first == "kill-session" }
    }

    private func attempts(for deadline: Duration) -> Int {
        let seconds = Double(deadline.components.seconds)
            + Double(deadline.components.attoseconds) / 1e18
        return max(1, Int(seconds / 0.01))
    }
}

/// Reports which command the runner was told to park on, so a hold that never
/// fired is distinguishable from one whose command never ran.
private struct HoldNeverReached: Error, CustomStringConvertible {
    let subject: String
    let command: String?
    let after: Duration

    var description: String {
        "tmux never reached the held `\(command ?? "<none>")` command for \(subject) "
            + "after polling up to \(after), so the teardown had nothing to interleave with"
    }
}

/// Reports what the runner actually saw, not what it wanted — including every
/// invocation, since "no kill at all" and "a kill on the wrong server" are
/// different bugs.
private struct MissingKillSessions: Error, CustomStringConvertible {
    let subject: String
    let expected: Int
    let observed: [RecordingTmuxRunner.Invocation]
    let allInvocations: [RecordingTmuxRunner.Invocation]
    let after: Duration

    var description: String {
        let rendered = allInvocations
            .map { "\($0.server): \($0.args.joined(separator: " "))" }
            .joined(separator: "; ")
        return """
            tmux never killed \(subject): expected at least \(expected) kill-session \
            invocation(s), observed \(observed.count) after polling up to \(after). \
            Invocations since preparation finished: [\(rendered.isEmpty ? "none" : rendered)]
            """
    }
}
