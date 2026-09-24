import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `terminal.swapProfile` in `.inPlace` mode, where the row it is asked about
/// runs on the pty-holder transport.
///
/// The arm under test is a composition of three verbs that already soak —
/// park, re-home, wake — and what this suite can reach in the fast pass is
/// everything up to the first one that needs a live pty. A park needs a reader
/// the daemon only has over a real holder, so the success path and the
/// "child is really gone" half live in `HolderProfileSwapLiveTests`; what is
/// here is the routing (which arm runs at all), the cold path, and the states
/// the two halves leave behind when they refuse.
@Suite("terminal.swapProfile, in place, on the pty-holder transport")
struct HolderInPlaceSwapTests {

    /// The session the row carries and the swap resumes. Never reaches a real
    /// agent: nothing in this suite spawns.
    static let sessionID = "swap-holder-session"

    // MARK: - Fixture

    private final class TmuxArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var argvs: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            argvs.append(argv)
        }
        var all: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return argvs
        }
        func count(_ subcommand: String) -> Int {
            all.filter { $0.contains(subcommand) }.count
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: TmuxArgvRecorder
        let worktree: Worktree
        let destProfileID: UUID
        let home: String
        let actuationLogPath: String

        func tearDown() {
            try? ModelProfileKeychain.delete(id: destProfileID.uuidString)
            try? FileManager.default.removeItem(atPath: home)
        }

        func swap(_ terminalID: UUID) async throws -> RPCResponse {
            await router.handle(try RPCRequest(
                method: RPCMethod.terminalSwapProfile,
                params: TerminalSwapProfileParams(
                    terminalID: terminalID,
                    newProfileID: destProfileID,
                    mode: .inPlace)))
        }

        func local() async throws -> LocalWorktree {
            try #require(try await db.worktrees.getLocal(id: worktree.id))
        }

        /// Every actuation line the log holds, decoded. The record is the only
        /// place a swallowed transport failure is visible, so a test that
        /// asserts on the response alone cannot tell a dispatched swap from a
        /// failed one.
        func actuationRows() throws -> [[String: Any]] {
            guard let contents = try? String(
                contentsOfFile: actuationLogPath, encoding: .utf8) else { return [] }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(
                        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
        }
    }

    /// A spawner whose executable does not exist: `canSpawn` is true, so the
    /// wake reaches its spawn, and the spawn always throws. That is what makes
    /// "this path never tried to spawn" an assertion rather than a hope — a
    /// registry with no spawner at all refuses earlier and for a different
    /// reason.
    private static func unspawnableSpawner() -> HolderSpawner {
        HolderSpawner(executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder"))
    }

    private static func makeFixture(spawner: HolderSpawner?) async throws -> Fixture {
        let home = fencedScratchRoot(prefix: "tbdhis")
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        let recorder = TmuxArgvRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in "" })
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)

        let configDirManager = makeIsolatedConfigDirManager(tag: "holder-in-place-swap")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let actuationLogPath = "\(home)/actuations.jsonl"
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: ActuationLog(path: actuationLogPath))
        // The registry both halves reach: the router's own for the swap's
        // transport decision, and the coordinator's for the park and the wake.
        // Its environment is explicit, so no rendezvous path can reach the
        // developer's real `~/tbd` even for an instant.
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
            listTerminals: { [] },
            spawner: spawner)
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)

        let repoPath = "\(home)/repo"
        try FileManager.default.createDirectory(
            atPath: repoPath, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let worktreePath = "\(home)/wt"
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: worktreePath, tmuxServer: "tbd-his-test")
        let dest = try await db.modelProfiles.create(name: "Dest", kind: .oauth)

        return Fixture(
            db: db, router: router, recorder: recorder, worktree: worktree,
            destProfileID: dest.id, home: home, actuationLogPath: actuationLogPath)
    }

    /// A holder-backed Claude row with a NON-blank transcript, so the swap
    /// plans a resume rather than a fresh spawn.
    ///
    /// A parked row names no processes — that is what a park leaves behind —
    /// so the two shapes differ in their pids as well as in their park columns.
    ///
    /// `withTranscript: false` leaves the session with NO transcript on disk
    /// at all — the shape a `.fork` refuses and `.inPlace` must not.
    private static func holderRow(
        _ fixture: Fixture, parked: Bool, withTranscript: Bool = true
    ) async throws -> Terminal {
        let transcript = "\(fixture.home)/\(UUID().uuidString).jsonl"
        if withTranscript {
            try #"{"type":"user","message":{"content":"switch me"}}"#
                .write(toFile: transcript, atomically: true, encoding: .utf8)
        }
        let created = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: TerminalLabel.claudeCode,
            claudeSessionID: sessionID,
            kind: .claude,
            transport: .holder,
            holderPID: parked ? nil : 9101,
            childPID: parked ? nil : 9102)
        try await fixture.db.terminals.updateSession(
            id: created.id, sessionID: sessionID, transcriptPath: transcript)
        if parked {
            try await fixture.db.terminals.setHibernated(
                id: created.id, sessionID: sessionID, reason: .auto)
        }
        return try #require(try await fixture.db.terminals.get(id: created.id))
    }

    // MARK: - The cold path, unchanged

    /// An `.inPlace` swap of a row that is ALREADY parked takes the cold path
    /// on either transport: re-home, and wake nothing.
    ///
    /// The discriminator against a fall-through to the holder arm is the
    /// pending incarnation. That arm's wake reserves a replacement identity
    /// before it spawns and this fixture's spawner always throws, so a swap
    /// that took the arm would leave a row still reading parked with a pending
    /// incarnation no launch will ever confirm.
    @Test("an in-place swap of an already parked holder row re-homes it and spawns nothing")
    func coldSwapOfAParkedHolderRowOnlyReHomes() async throws {
        let fixture = try await Self.makeFixture(spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let terminal = try await Self.holderRow(fixture, parked: true)

        let response = try await fixture.swap(terminal.id)

        #expect(response.success, "\(response.error ?? "")")
        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.profileID == fixture.destProfileID, "the parked row was not re-homed")
        #expect(after.isParked, "the cold path woke a parked row")
        #expect(after.pendingSessionIncarnationID == nil,
                "the cold path reached the wake's replacement reservation")
        #expect(after.holderPID == nil && after.childPID == nil,
                "the cold path recorded processes for a session it must not have started")
        #expect(fixture.recorder.count("respawn-window") == 0,
                "the cold path reached tmux: \(fixture.recorder.all)")
        let rows = try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
        #expect(rows.count == 1, "the cold path created a second row")
    }

    // MARK: - The park half, refused

    /// The first of the spec's failure outcomes: a park that refuses leaves
    /// the row AWAKE on its OLD account with nothing about it changed, and the
    /// actuation says `transport-failed` rather than inheriting a success.
    ///
    /// The refusal is the park's own text, not a new one: this fixture's
    /// registry adopted nothing, so the daemon holds no reader to write the
    /// polite `/exit` through.
    @Test("a swap whose park refuses leaves the row awake on its old account and records transport-failed")
    func swapParkRefusalLeavesTheRowAwake() async throws {
        let fixture = try await Self.makeFixture(spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let terminal = try await Self.holderRow(fixture, parked: false)

        let response = try await fixture.swap(terminal.id)

        #expect(!response.success)
        #expect(response.error == HibernationCoordinator.holderNoReaderRefusal,
                "the swap failed somewhere other than the park: \(response.error ?? "success")")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!after.isParked, "a refused park left the row parked")
        #expect(after.profileID == nil, "a refused park still re-homed the row")
        #expect(after.holderPID == 9101 && after.childPID == 9102,
                "a refused park cleared the row's pids")
        #expect(after.sessionIncarnationID == terminal.sessionIncarnationID,
                "a refused park committed a replacement identity to the row")

        // The record is where a swallowed transport failure is visible at all.
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2,
                "the swap did not open and close exactly one actuation: \(rows)")
        #expect(rows.last?["result"] as? String == "transport-failed",
                "a refused park was recorded as something other than transport-failed")
    }

    /// A holder row whose session has NO transcript on disk is still swapped
    /// in place: the missing-transcript refusal belongs to `.fork` alone, so
    /// this swap must reach the holder arm's park (and stop there, for the
    /// same no-reader reason as above) rather than being refused up front.
    @Test("an in-place swap of a holder row with no transcript still reaches the park")
    func swapWithoutATranscriptStillReachesThePark() async throws {
        let fixture = try await Self.makeFixture(spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let terminal = try await Self.holderRow(fixture, parked: false, withTranscript: false)

        let response = try await fixture.swap(terminal.id)

        #expect(response.error == HibernationCoordinator.holderNoReaderRefusal,
                "the swap stopped somewhere other than the park: \(response.error ?? "success")")
        let rows = try fixture.actuationRows()
        #expect(rows.last?["result"] as? String == "transport-failed",
                "the swap was recorded as something other than the park's failure: \(rows)")
    }

    /// A park already mid-ladder for this row is a REFUSAL, not a park: the
    /// swap cannot see whether that ladder will finish parking the row or roll
    /// its intent back because the child survived, and a re-home committed on
    /// the strength of an intent that later rolls back would leave the row
    /// awake under the NEW account with the old process running under the old
    /// one. So the arm must change nothing and say so.
    ///
    /// The refusal arrives at the arm's claim rather than at the park, because
    /// the claim the arm takes before it parks anything is refused by every
    /// park, wake or swap already holding the row. The arm keeps its own
    /// `.alreadyHibernated` answer for the park that begins AFTER the claim is
    /// taken — the claim excludes wakes, not hibernates — and both land in the
    /// state this test asserts.
    ///
    /// Staged by claiming the singleflight slot for this terminal before the
    /// RPC, which is exactly what a concurrent ladder holds while it runs. The
    /// row stays awake in the database, because a row that reads parked at the
    /// handler's entry takes the cold path further up and never reaches this
    /// arm at all — the in-flight ladder's park intent, when it lands, is
    /// invisible to a swap that has already passed that branch.
    @Test("a swap whose row a park already holds changes nothing and says which half refused")
    func swapParkAnsweredByAnInFlightParkChangesNothing() async throws {
        let fixture = try await Self.makeFixture(spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let terminal = try await Self.holderRow(fixture, parked: false)
        await fixture.router.hibernationCoordinator.claimHibernateSlotForTest(terminal.id)

        let response = try await fixture.swap(terminal.id)

        #expect(!response.success)
        let error = response.error ?? "success"
        #expect(error.contains("another pause, wake or account switch of this session is in flight"),
                "the refusal does not name the swap claim: \(error)")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.profileID == nil,
                "a park that never happened still re-homed the row")
        #expect(!after.isParked, "an in-flight park's swap parked the row itself")
        #expect(after.holderPID == 9101 && after.childPID == 9102,
                "an in-flight park's swap cleared the row's pids")
        #expect(after.sessionIncarnationID == terminal.sessionIncarnationID,
                "an in-flight park's swap committed a replacement identity")
        #expect(after.pendingSessionIncarnationID == nil,
                "an in-flight park's swap reached the wake's replacement reservation")

        let rows = try fixture.actuationRows()
        #expect(rows.count == 2,
                "the swap did not open and close exactly one actuation: \(rows)")
        #expect(rows.last?["result"] as? String == "transport-failed",
                "an in-flight park was recorded as something other than transport-failed")
    }

    /// The claim the arm takes on the row before it parks anything, seen from
    /// the outside: a row some other park, wake or swap already holds is
    /// refused by a named reason, and nothing about it is touched.
    ///
    /// Staged by holding the swap claim itself, which is what a concurrent
    /// "Switch account" on the same row holds for the whole of its
    /// composition. The same guard is what makes an ordinary focus-wake
    /// arriving mid-swap answer in-flight rather than un-park the row under
    /// the account the swap is moving it off — pinned from the wake's side by
    /// `HibernationCoordinatorTests.wakeAnswersInFlightWhileAProfileSwapHoldsTheRow`
    /// and end to end by `HolderProfileSwapLiveTests`.
    @Test("a swap of a row another swap already claimed changes nothing and says so")
    func swapOfAnAlreadyClaimedRowChangesNothing() async throws {
        let fixture = try await Self.makeFixture(spawner: Self.unspawnableSpawner())
        defer { fixture.tearDown() }
        let terminal = try await Self.holderRow(fixture, parked: false)
        #expect(await fixture.router.hibernationCoordinator.claimSwap(terminalID: terminal.id),
                "the fixture could not stage a concurrent claim")

        let response = try await fixture.swap(terminal.id)

        #expect(!response.success)
        let error = response.error ?? "success"
        #expect(error.contains("another pause, wake or account switch of this session is in flight"),
                "the refusal does not name the claim that refused it: \(error)")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!after.isParked, "a refused claim still parked the row")
        #expect(after.profileID == nil, "a refused claim still re-homed the row")
        #expect(after.holderPID == 9101 && after.childPID == 9102,
                "a refused claim cleared the row's pids")
        #expect(after.pendingSessionIncarnationID == nil,
                "a refused claim reached the wake's replacement reservation")

        let rows = try fixture.actuationRows()
        #expect(rows.count == 2,
                "the swap did not open and close exactly one actuation: \(rows)")
        #expect(rows.last?["result"] as? String == "transport-failed",
                "a refused claim was recorded as something other than transport-failed")

        // And the claim the arm never took is not left behind: a release the
        // arm reached anyway would have freed a claim this test still holds.
        #expect(await fixture.router.hibernationCoordinator.isSwapInFlight(terminalID: terminal.id),
                "the refused arm released a claim it never took")
        await fixture.router.hibernationCoordinator.releaseSwap(terminalID: terminal.id)
    }

    // MARK: - The wake half, refused

    /// The third of the spec's failure outcomes, asked of the half that owns
    /// it: a wake that cannot start a holder leaves the row PARKED and on the
    /// NEW profile, so the swap has taken effect at the account level and the
    /// next focus-wake retries the resume.
    ///
    /// Driven through the wake half directly rather than through the RPC,
    /// because reaching it through the RPC would need a park to succeed and a
    /// park needs a reader over a real pty. The composition is the live
    /// suite's; what this pins is the state this half leaves behind. The
    /// RPC-level contract for this outcome — a success-shaped response carrying
    /// the re-homed row, with the failure recorded only in the actuation — is
    /// pinned by
    /// `HolderProfileSwapLiveTests.inPlaceSwapWhoseWakeFailsLeavesTheRowParkedOnTheNewAccount`.
    @Test("the swap's wake half leaves a refused row parked on the account it was re-homed to")
    func swapWakeRefusalLeavesTheRowParkedOnTheNewProfile() async throws {
        // No spawner at all: `canSpawn` is false, which is the daemon whose
        // TBDHolder helper has moved — the spec's named wake failure.
        let fixture = try await Self.makeFixture(spawner: nil)
        defer { fixture.tearDown() }
        let terminal = try await Self.holderRow(fixture, parked: true)
        // The state the arm's second step leaves: parked, on the destination.
        let rehomed = try #require(try await fixture.db.terminals.setParkedProfileID(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: terminal),
            profileID: fixture.destProfileID))

        let result = await fixture.router.hibernationCoordinator.wakeHolderForProfileSwap(
            terminal: rehomed,
            worktree: try await fixture.local(),
            sessionID: Self.sessionID,
            expectedReplacementState: TerminalReplacementSnapshot(terminal: rehomed),
            spawnCommand: "claude --resume \(Self.sessionID)",
            env: ["TBD_TERMINAL_ID": rehomed.id.uuidString],
            attachment: .unproxied([:]),
            cols: 80,
            rows: 24)

        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected .respawnFailed from a daemon that cannot spawn, got \(result)")
            return
        }
        #expect(reason.contains("TBDHolder"),
                "the refusal does not name what is missing: \(reason)")

        let after = try #require(try await fixture.db.terminals.get(id: rehomed.id))
        #expect(after.isParked, "a refused wake un-parked the row")
        #expect(after.profileID == fixture.destProfileID,
                "a refused wake un-did the re-home; the swap must stand at the account level")
        #expect(after.holderPID == nil && after.childPID == nil,
                "a refused wake recorded processes nothing started")
    }
}

/// The seams the in-flight tests need: claim or release either per-terminal
/// singleflight slot without running a ladder or a respawn. A real concurrent
/// hibernate or wake holds exactly these for the length of its own work.
extension HibernationCoordinator {
    func claimHibernateSlotForTest(_ terminalID: UUID) {
        hibernatesInFlight.insert(terminalID)
    }

    func releaseHibernateSlotForTest(_ terminalID: UUID) {
        hibernatesInFlight.remove(terminalID)
    }

    func claimWakeSlotForTest(_ terminalID: UUID) {
        wakesInFlight.insert(terminalID)
    }

    func releaseWakeSlotForTest(_ terminalID: UUID) {
        wakesInFlight.remove(terminalID)
    }
}
