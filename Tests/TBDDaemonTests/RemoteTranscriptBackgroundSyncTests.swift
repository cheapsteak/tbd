import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `RemoteTranscriptBackgroundSync`: admission from sightings, the skips, the
/// flag on all three of its states, coalescing, per-provider pacing, re-queue
/// at the back, failure handling, the queue drop, and restart survival through
/// the hint recorded in `state.json`.
///
/// Tier 2: a scripted sync closure and a temp `TBD_HOME` passed as the
/// environment; no provider, no router, no subprocess.
@Suite("RemoteTranscriptBackgroundSync", .fastPassBounded)
struct RemoteTranscriptBackgroundSyncTests: ~Copyable {
    let home: URL
    let environment: [String: String]

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-transcript-background-\(UUID().uuidString)", isDirectory: true)
        environment = ["TBD_HOME": home.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// A one-shot gate the test opens from outside.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private struct ScriptedFailure: Error {}

    /// Stands in for `RemoteTranscriptSync.sync`. Records each session it is
    /// asked to sync, can park a session's first call on a gate, and answers
    /// from a per-session script (caught up by default). A caught-up answer
    /// records the session's current hint in `state.json`, as the real sync
    /// does; a not-caught-up or failed one records nothing.
    private actor ScriptedSync {
        enum Answer { case caughtUp, notCaughtUp, fails }

        private(set) var started: [String] = []
        private var answers: [String: [Answer]]
        private var holds: [String: Gate]
        private let hints: RemoteTranscriptHints
        private let environment: [String: String]

        init(
            hints: RemoteTranscriptHints, environment: [String: String],
            answers: [String: [Answer]] = [:], holds: [String: Gate] = [:]
        ) {
            self.hints = hints
            self.environment = environment
            self.answers = answers
            self.holds = holds
        }

        func run(_ provider: String, _ sessionID: String) async throws -> RemoteTranscriptSyncResult {
            started.append(sessionID)
            if let gate = holds.removeValue(forKey: sessionID) { await gate.wait() }
            var answer = Answer.caughtUp
            if var scripted = answers[sessionID], !scripted.isEmpty {
                answer = scripted.removeFirst()
                answers[sessionID] = scripted
            }
            switch answer {
            case .fails:
                throw ScriptedFailure()
            case .notCaughtUp:
                return RemoteTranscriptSyncResult(path: "/p", generation: 1, caughtUp: false)
            case .caughtUp:
                if let hint = await hints.latest(provider: provider, sessionID: sessionID) {
                    let cache = RemoteTranscriptCache(
                        provider: provider, sessionID: sessionID, environment: environment)
                    _ = try cache.commitHint(hint, to: try cache.load())
                }
                return RemoteTranscriptSyncResult(path: "/p", generation: 1, caughtUp: true)
            }
        }
    }

    /// The flag, the dismissed set, and the discards the actor asked for.
    private actor Switches {
        private(set) var enabled = true
        private(set) var dismissed: Set<String> = []
        private(set) var discards: [String] = []

        func setEnabled(_ value: Bool) { enabled = value }
        func dismiss(_ sessionID: String) { dismissed.insert(sessionID) }
        func discard(_ sessionID: String) { discards.append(sessionID) }
    }

    private static let both: Set<String> = [RemoteCapability.transcriptRead, RemoteCapability.transcriptTail]

    private func makeBackground(
        _ scripted: ScriptedSync, hints: RemoteTranscriptHints, switches: Switches,
        isEnabled: (@Sendable () async -> Bool)? = nil,
        capabilities: [String: Set<String>] = ["agentbox": RemoteTranscriptBackgroundSyncTests.both, "other": RemoteTranscriptBackgroundSyncTests.both]
    ) -> RemoteTranscriptBackgroundSync {
        let flag: @Sendable () async -> Bool
        if let isEnabled {
            flag = isEnabled
        } else {
            flag = { await switches.enabled }
        }
        return RemoteTranscriptBackgroundSync(
            environment: environment,
            hints: hints,
            isEnabled: flag,
            capabilities: { provider in capabilities[provider] ?? [] },
            isDismissed: { _, sessionID in await switches.dismissed.contains(sessionID) },
            discard: { _, sessionID in await switches.discard(sessionID) },
            sync: { provider, sessionID in try await scripted.run(provider, sessionID) })
    }

    private func session(_ id: String, _ hint: RemoteTranscriptHint?) -> RemoteSessionPayload {
        RemoteSessionPayload(id: id, state: .running, transcript: hint)
    }

    private func hint(_ id: String, _ size: Int) -> RemoteTranscriptHint {
        RemoteTranscriptHint(id: id, size: size)
    }

    private func waitUntilStarted(_ scripted: ScriptedSync, _ sessionID: String) async -> PollOutcome {
        await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await scripted.started.contains(sessionID)
        }
    }

    // MARK: - The flag

    @Test func idleWithTheFlagOff() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let switches = Switches()
        await switches.setEnabled(false)
        let background = makeBackground(scripted, hints: hints, switches: switches)

        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()

        #expect(await scripted.started.isEmpty)
        #expect(await background.queuedSessions(provider: "agentbox").isEmpty)
    }

    @Test func enqueuesWithTheFlagOn() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()

        #expect(await scripted.started == ["s-1"])
    }

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    /// NULL, 0 and 1 drive admission differently: NULL follows the shipped
    /// default (off), an explicit true syncs, an explicit false is idle again.
    @Test func theFlagsThreeStatesAreDistinguishable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(
            scripted, hints: hints, switches: Switches(),
            isEnabled: { (try? await db.config.get().remoteTranscriptLiveSyncEnabled) ?? false })

        // NULL — never chosen.
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.remote_transcript_live_sync_enabled == nil)
        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started.isEmpty)

        // 1 — explicitly on.
        try await db.config.setRemoteTranscriptLiveSyncEnabled(true)
        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1"])

        // 0 — explicitly off; a moved hint is still not synced.
        try await db.config.setRemoteTranscriptLiveSyncEnabled(false)
        await background.observe(sessions: [session("s-1", hint("c1", 2))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1"])
    }

    /// The other half of the three states: with the default constant flipped
    /// to on, NULL follows it into admission, while an explicit false stays
    /// off under the same default.
    @Test func nullFollowsTheDefaultWhileAnExplicitFalseSurvivesIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(
            scripted, hints: hints, switches: Switches(),
            isEnabled: {
                let record = try? await db.writerForTests.read { conn in
                    try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
                }
                return record?.toModel(remoteTranscriptLiveSyncDefault: true)
                    .remoteTranscriptLiveSyncEnabled ?? false
            })

        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1"], "NULL did not follow a default of on")

        try await db.config.setRemoteTranscriptLiveSyncEnabled(false)
        await background.observe(sessions: [session("s-2", hint("d1", 1))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1"], "an explicit false followed the default")
    }

    @Test func hintsAreRecordedEvenWithTheFlagOff() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let switches = Switches()
        await switches.setEnabled(false)
        let background = makeBackground(scripted, hints: hints, switches: switches)

        await background.observe(sessions: [session("s-1", hint("c1", 7))], provider: "agentbox")
        #expect(await hints.latest(provider: "agentbox", sessionID: "s-1") == hint("c1", 7))

        await background.observe(sessions: [session("s-1", nil)], provider: "agentbox")
        #expect(await hints.latest(provider: "agentbox", sessionID: "s-1") == nil)
        #expect(await scripted.started.isEmpty)
    }

    // MARK: - Skips

    @Test func skipsASessionWithNoHint() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(
            sessions: [session("s-1", nil), session("s-2", hint("c2", 1))], provider: "agentbox")
        await background.waitUntilIdle()

        #expect(await scripted.started == ["s-2"])
    }

    @Test func skipsADismissedSession() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let switches = Switches()
        await switches.dismiss("s-1")
        let background = makeBackground(scripted, hints: hints, switches: switches)

        await background.observe(
            sessions: [session("s-1", hint("c1", 1)), session("s-2", hint("c2", 1))], provider: "agentbox")
        await background.waitUntilIdle()

        #expect(await scripted.started == ["s-2"])
    }

    @Test func skipsAProviderMissingTranscriptRead() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(
            scripted, hints: hints, switches: Switches(),
            capabilities: ["noread": [RemoteCapability.transcriptTail], "agentbox": Self.both])

        await background.observe(sessions: [session("n-1", hint("c1", 1))], provider: "noread")
        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()

        #expect(await scripted.started == ["s-1"])
    }

    @Test func skipsAProviderMissingTranscriptTail() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(
            scripted, hints: hints, switches: Switches(),
            capabilities: ["notail": [RemoteCapability.transcriptRead], "agentbox": Self.both])

        await background.observe(sessions: [session("n-1", hint("c1", 1))], provider: "notail")
        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()

        #expect(await scripted.started == ["s-1"])
    }

    // MARK: - Restart

    /// A new actor over a `state.json` whose recorded hint matches the first
    /// sighting does not refetch; a sighting that differs syncs once.
    @Test func aMatchingRecordedHintIsNotRefetchedAfterARestart() async throws {
        let cache = RemoteTranscriptCache(provider: "agentbox", sessionID: "s-1", environment: environment)
        _ = try cache.commitHint(hint("c1", 100), to: try cache.load())

        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment)
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-1", hint("c1", 100))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started.isEmpty)

        await background.observe(sessions: [session("s-1", hint("c1", 200))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1"])
    }

    // MARK: - Pacing

    @Test func hintChangesBeforeTheSyncRunsCoalesce() async {
        let gate = Gate()
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment, holds: ["s-a": gate])
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-a", hint("a", 1))], provider: "agentbox")
        let started = await waitUntilStarted(scripted, "s-a")
        for size in 1...3 {
            await background.observe(sessions: [session("s-b", hint("b", size))], provider: "agentbox")
        }
        let queued = await background.queuedSessions(provider: "agentbox")
        await gate.open()
        await background.waitUntilIdle()

        #expect(started == .satisfied)
        #expect(queued == ["s-b"])
        #expect(await scripted.started == ["s-a", "s-b"])
    }

    @Test func oneSyncPerProviderAtATime() async {
        let gate = Gate()
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment, holds: ["s-a": gate])
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-a", hint("a", 1))], provider: "agentbox")
        let startedA = await waitUntilStarted(scripted, "s-a")
        await background.observe(sessions: [session("s-b", hint("b", 1))], provider: "agentbox")
        await background.observe(sessions: [session("o-c", hint("c", 1))], provider: "other")
        let startedC = await waitUntilStarted(scripted, "o-c")
        let whileHeld = await scripted.started
        await gate.open()
        await background.waitUntilIdle()

        #expect(startedA == .satisfied)
        #expect(startedC == .satisfied, "another provider's sync waited behind a held one")
        #expect(!whileHeld.contains("s-b"), "a second sync started on a provider already syncing")
        let all = await scripted.started
        #expect(Set(all) == ["s-a", "s-b", "o-c"])
    }

    @Test func aSyncNotCaughtUpGoesToTheBackOfItsQueue() async {
        let gate = Gate()
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(
            hints: hints, environment: environment,
            answers: ["s-a": [.notCaughtUp, .caughtUp]], holds: ["s-a": gate])
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-a", hint("a", 1))], provider: "agentbox")
        let started = await waitUntilStarted(scripted, "s-a")
        await background.observe(sessions: [session("s-b", hint("b", 1))], provider: "agentbox")
        await gate.open()
        await background.waitUntilIdle()

        #expect(started == .satisfied)
        #expect(await scripted.started == ["s-a", "s-b", "s-a"])
    }

    /// A failure ends that session's turn; nothing retries it until the next
    /// sighting, which enqueues it again because the recorded hint still
    /// differs.
    @Test func aFailedSyncIsDroppedNotRetriedInALoop() async {
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(
            hints: hints, environment: environment, answers: ["s-1": [.fails, .caughtUp]])
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1"])
        #expect(await background.queuedSessions(provider: "agentbox").isEmpty)

        await background.observe(sessions: [session("s-1", hint("c1", 1))], provider: "agentbox")
        await background.waitUntilIdle()
        #expect(await scripted.started == ["s-1", "s-1"])
    }

    // MARK: - Dropping the queue

    /// Read before every dequeue: a flag turned off while a sync runs leaves
    /// the sessions queued behind it unsynced.
    @Test func theQueueIsDroppedWhenTheFlagGoesOff() async {
        let gate = Gate()
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment, holds: ["s-a": gate])
        let switches = Switches()
        let background = makeBackground(scripted, hints: hints, switches: switches)

        await background.observe(sessions: [session("s-a", hint("a", 1))], provider: "agentbox")
        let started = await waitUntilStarted(scripted, "s-a")
        await background.observe(
            sessions: [session("s-b", hint("b", 1)), session("s-c", hint("c", 1))], provider: "agentbox")
        let queued = await background.queuedSessions(provider: "agentbox")
        await switches.setEnabled(false)
        await gate.open()
        await background.waitUntilIdle()

        #expect(started == .satisfied)
        #expect(queued == ["s-b", "s-c"])
        #expect(await scripted.started == ["s-a"])
        #expect(await background.queuedSessions(provider: "agentbox").isEmpty)
    }

    /// `dropAll` empties the queues at once, with the flag still on: the
    /// queued sessions never sync, and the running one finishes.
    @Test func dropAllEmptiesTheQueuesAtOnce() async {
        let gate = Gate()
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment, holds: ["s-a": gate])
        let background = makeBackground(scripted, hints: hints, switches: Switches())

        await background.observe(sessions: [session("s-a", hint("a", 1))], provider: "agentbox")
        let started = await waitUntilStarted(scripted, "s-a")
        await background.observe(
            sessions: [session("s-b", hint("b", 1)), session("s-c", hint("c", 1))], provider: "agentbox")
        let before = await background.queuedSessions(provider: "agentbox")
        await background.dropAll()
        let after = await background.queuedSessions(provider: "agentbox")
        await gate.open()
        await background.waitUntilIdle()

        #expect(started == .satisfied)
        #expect(before == ["s-b", "s-c"])
        #expect(after.isEmpty)
        #expect(await scripted.started == ["s-a"])
    }

    // MARK: - Dismissal mid-sync

    @Test func aSessionDismissedDuringItsSyncKeepsNoCache() async {
        let gate = Gate()
        let hints = RemoteTranscriptHints()
        let scripted = ScriptedSync(hints: hints, environment: environment, holds: ["s-a": gate])
        let switches = Switches()
        let background = makeBackground(scripted, hints: hints, switches: switches)

        await background.observe(sessions: [session("s-a", hint("a", 1))], provider: "agentbox")
        let started = await waitUntilStarted(scripted, "s-a")
        await background.observe(sessions: [session("s-b", hint("b", 1))], provider: "agentbox")
        await switches.dismiss("s-a")
        await gate.open()
        await background.waitUntilIdle()

        #expect(started == .satisfied)
        #expect(await switches.discards == ["s-a"], "only the session dismissed mid-sync is discarded")
        #expect(await scripted.started == ["s-a", "s-b"])
    }
}
