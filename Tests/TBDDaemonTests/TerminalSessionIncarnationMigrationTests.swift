import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct TerminalSessionIncarnationMigrationTests {
    private static let migrationID = "20260825060216_terminal_session_incarnation"
    private static let pendingMigrationID = "20260829210843_pending_terminal_incarnation"

    @Test func forwardMigrationLeavesExistingIncarnationNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "20260825024814_codex_transcript_boundary")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/session-incarnation-repo', 'Incarnation', 'main', ?)
                    """, arguments: [repoID, epoch])
            try database.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'w', 'w', 'main', '/tmp/session-incarnation-wt',
                            'active', ?, 'tbd-incarnation')
                    """, arguments: [worktreeID, repoID, epoch])
            try database.execute(
                sql: """
                    INSERT INTO terminal
                        (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt)
                    VALUES (?, ?, '@1', '%1', ?)
                    """, arguments: [terminalID, worktreeID, epoch])
        }
        let columnsBefore = try queue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!columnsBefore.contains("sessionIncarnationID"))

        try migrator.migrate(queue, upTo: Self.migrationID)
        let result = try queue.read { database in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            let value = try String.fetchOne(
                database,
                sql: "SELECT sessionIncarnationID FROM terminal WHERE id = ?",
                arguments: [terminalID])
            return (columns, value)
        }
        #expect(result.0.contains("sessionIncarnationID"))
        #expect(result.1 == nil)
    }

    @Test func terminalRecordRoundTripsIncarnation() async throws {
        let database = try TBDDatabase(inMemory: true)
        let repo = try await database.repos.create(
            path: "/tmp/session-incarnation-record-repo-\(UUID().uuidString)",
            displayName: "Incarnation", defaultBranch: "main")
        let worktree = try await database.worktrees.create(
            repoID: repo.id, name: "incarnation", branch: "incarnation",
            path: "/tmp/session-incarnation-record-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-incarnation-record")
        let incarnationID = UUID()
        let pendingIncarnationID = UUID()
        let terminal = Terminal(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            sessionIncarnationID: incarnationID,
            pendingSessionIncarnationID: pendingIncarnationID)
        try await database.writerForTests.write { connection in
            try TerminalRecord(from: terminal).insert(connection)
        }
        let raw = try database.writerForTests.read { connection in
            return try Row.fetchOne(
                connection,
                sql: """
                    SELECT sessionIncarnationID, pendingSessionIncarnationID
                    FROM terminal WHERE id = ?
                    """,
                arguments: [terminal.id.uuidString])
        }
        #expect(raw?["sessionIncarnationID"] as String? == incarnationID.uuidString)
        #expect(raw?["pendingSessionIncarnationID"] as String? == pendingIncarnationID.uuidString)
        let decoded = try await database.terminals.get(id: terminal.id)
        #expect(decoded?.sessionIncarnationID == incarnationID)
        #expect(decoded?.pendingSessionIncarnationID == pendingIncarnationID)
    }

    @Test func forwardMigrationLeavesExistingPendingIncarnationNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.migrationID)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/pending-incarnation-repo', 'Incarnation', 'main', ?)
                    """, arguments: [repoID, epoch])
            try database.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'w', 'w', 'main', '/tmp/pending-incarnation-wt',
                            'active', ?, 'tbd-pending-incarnation')
                    """, arguments: [worktreeID, repoID, epoch])
            try database.execute(
                sql: """
                    INSERT INTO terminal
                        (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt,
                         sessionIncarnationID)
                    VALUES (?, ?, '@1', '%1', ?, ?)
                    """, arguments: [terminalID, worktreeID, epoch, UUID().uuidString])
        }

        try migrator.migrate(queue, upTo: Self.pendingMigrationID)
        let result = try queue.read { database in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            let value = try String.fetchOne(
                database,
                sql: "SELECT pendingSessionIncarnationID FROM terminal WHERE id = ?",
                arguments: [terminalID])
            return (columns, value)
        }
        #expect(result.0.contains("pendingSessionIncarnationID"))
        #expect(result.1 == nil)
    }

    @Test func legacyNilSessionStartStillAttachesToLegacyRow() async throws {
        let (database, terminal) = try await makeTerminal(kind: .codex, label: "Codex")

        let application = try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            reportedIncarnationID: nil,
            sessionID: "legacy-session",
            transcriptPath: "/tmp/legacy-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 10))

        #expect(application?.sessionID == "legacy-session")
        #expect(try await database.terminals.get(id: terminal.id)?.sessionIncarnationID == nil)
    }

    @Test func nonnilProcessIncarnationRejectsLegacyRowWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .codex, label: "Codex")
        let sessionOrderAt = Date(timeIntervalSinceReferenceDate: 5)
        let activityObservedAt = Date(timeIntervalSinceReferenceDate: 6)
        let activityOrderAt = Date(timeIntervalSinceReferenceDate: 7)
        let activitySource = FactSource.hookEvent("kept")
        try await database.writerForTests.write { connection in
            try connection.execute(
                sql: """
                    UPDATE terminal
                    SET claudeSessionID = ?, transcriptPath = ?,
                        sessionOrderObservedAt = ?, codexTranscriptBoundaryOffset = ?,
                        activityState = ?, activityStateSource = ?, activityStateObservedAt = ?,
                        activityStateOrderObservedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    "kept-session", "/tmp/kept-session.jsonl", sessionOrderAt, 77,
                    TerminalActivityState.working.rawValue,
                    FactColumnJSON.encode(activitySource), activityObservedAt, activityOrderAt,
                    terminal.id.uuidString,
                ])
        }
        let current = try #require(try await database.terminals.get(id: terminal.id))
        #expect(current.sessionIncarnationID == nil)

        let application = try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: current),
            reportedIncarnationID: UUID(),
            sessionID: "foreign-session",
            transcriptPath: "/tmp/foreign-session.jsonl",
            observedTranscriptBoundary: ObservedTranscriptBoundary(
                path: "/tmp/foreign-session.jsonl", eof: 999),
            observedAt: Date(timeIntervalSinceReferenceDate: 10))

        #expect(application == nil)
        let stored = try #require(try await database.terminals.get(id: terminal.id))
        #expect(stored.sessionIncarnationID == nil)
        #expect(stored.claudeSessionID == "kept-session")
        #expect(stored.transcriptPath == "/tmp/kept-session.jsonl")
        #expect(stored.sessionOrderObservedAt == sessionOrderAt)
        #expect(stored.codexTranscriptBoundaryOffset == 77)
        #expect(stored.activityState == .working)
        #expect(stored.activityStateSource == activitySource)
        #expect(stored.activityStateObservedAt == activityObservedAt)
        #expect(stored.activityStateOrderObservedAt == activityOrderAt)
    }

    @Test func exactProcessIncarnationAcceptsSessionStart() async throws {
        let (database, terminal) = try await makeTerminal(kind: .codex, label: "Codex")
        let incarnationID = UUID()
        try await setIncarnation(incarnationID, terminalID: terminal.id, in: database)
        let current = try #require(try await database.terminals.get(id: terminal.id))

        let application = try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: current),
            reportedIncarnationID: incarnationID,
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 10))

        #expect(application?.sessionID == "replacement-session")
        #expect(try await database.terminals.get(id: terminal.id)?.sessionIncarnationID
                == incarnationID)
    }

    @Test func missingAndMismatchedProcessIncarnationRejectWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .codex, label: "Codex")
        let incarnationID = UUID()
        let seededAt = Date(timeIntervalSinceReferenceDate: 5)
        try await database.writerForTests.write { connection in
            try connection.execute(
                sql: """
                    UPDATE terminal
                    SET sessionIncarnationID = ?, claudeSessionID = ?, transcriptPath = ?,
                        sessionOrderObservedAt = ?, codexTranscriptBoundaryOffset = ?,
                        activityState = ?, activityStateSource = ?, activityStateObservedAt = ?,
                        activityStateOrderObservedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    incarnationID.uuidString, "kept-session", "/tmp/kept-session.jsonl",
                    seededAt, 77, TerminalActivityState.working.rawValue,
                    FactColumnJSON.encode(FactSource.hookEvent("kept")), seededAt, seededAt,
                    terminal.id.uuidString,
                ])
        }
        let current = try #require(try await database.terminals.get(id: terminal.id))

        for reported in [nil, UUID()] as [UUID?] {
            let application = try await database.terminals.applySessionStart(
                id: terminal.id,
                expectedIncarnation: TerminalSessionIncarnation(terminal: current),
                reportedIncarnationID: reported,
                sessionID: "stale-session",
                transcriptPath: "/tmp/stale-session.jsonl",
                observedTranscriptBoundary: ObservedTranscriptBoundary(
                    path: "/tmp/stale-session.jsonl", eof: 999),
                observedAt: Date(timeIntervalSinceReferenceDate: 10))
            #expect(application == nil)
        }

        let stored = try #require(try await database.terminals.get(id: terminal.id))
        #expect(stored.sessionIncarnationID == incarnationID)
        #expect(stored.claudeSessionID == "kept-session")
        #expect(stored.transcriptPath == "/tmp/kept-session.jsonl")
        #expect(stored.sessionOrderObservedAt == seededAt)
        #expect(stored.codexTranscriptBoundaryOffset == 77)
        #expect(stored.activityState == .working)
        #expect(stored.activityStateObservedAt == seededAt)
        #expect(stored.activityStateOrderObservedAt == seededAt)
    }

    @Test func trueProcessReplacementsMintButSessionRecapturePreservesIncarnation() async throws {
        let database = try TBDDatabase(inMemory: true)
        let repo = try await database.repos.create(
            path: "/tmp/session-incarnation-reset-repo-\(UUID().uuidString)",
            displayName: "Incarnation", defaultBranch: "main")
        let worktree = try await database.worktrees.create(
            repoID: repo.id, name: "incarnation", branch: "incarnation",
            path: "/tmp/session-incarnation-reset-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-incarnation-reset")
        let terminal = try await database.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        #expect(terminal.sessionIncarnationID == nil)

        _ = try await database.terminals.replaceRecreatedCodexWindow(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            windowID: "@1", paneID: "%1", at: Date())
        let replacement = try #require(
            try await database.terminals.get(id: terminal.id)?.sessionIncarnationID)
        try await database.terminals.updateTmuxIDs(
            id: terminal.id, windowID: "@1", paneID: "%1")
        let moved = try #require(
            try await database.terminals.get(id: terminal.id)?.sessionIncarnationID)
        #expect(moved != replacement)
        try await database.terminals.clearRecreated(id: terminal.id)
        let cleared = try #require(
            try await database.terminals.get(id: terminal.id)?.sessionIncarnationID)
        #expect(cleared != moved)
        try await database.terminals.updateSessionID(id: terminal.id, sessionID: "replacement")
        let recaptured = try #require(
            try await database.terminals.get(id: terminal.id)?.sessionIncarnationID)
        #expect(recaptured == cleared)
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "next-replacement",
            transcriptPath: "/tmp/next-replacement.jsonl")
        let updated = try #require(
            try await database.terminals.get(id: terminal.id)?.sessionIncarnationID)
        #expect(updated == recaptured)
    }

    @Test func codexPrelaunchTransitionReturnsTokenAndAcceptsImmediateMatchingHook() async throws {
        let (database, terminal) = try await makeTerminal(kind: .codex, label: "Codex")
        let token = try #require(
            try await database.terminals.replaceRecreatedCodexWindow(
                id: terminal.id,
                expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
                windowID: "@1", paneID: "%1", at: Date()))
        let prepared = try #require(try await database.terminals.get(id: terminal.id))
        #expect(prepared.sessionIncarnationID == token)
        #expect(try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: prepared),
            reportedIncarnationID: nil,
            sessionID: "stale-session",
            transcriptPath: "/tmp/stale-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 9)) == nil)
        _ = try #require(try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: prepared),
            reportedIncarnationID: token,
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 10)))

        let accepted = try #require(try await database.terminals.get(id: terminal.id))
        #expect(accepted.sessionIncarnationID == token)
        #expect(accepted.claudeSessionID == "replacement-session")
        #expect(accepted.transcriptPath == "/tmp/replacement-session.jsonl")
    }

    @Test func codexWindowReplacementRejectsStaleIncarnationWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .codex, label: "Codex")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "current-session",
            transcriptPath: "/tmp/current-codex-session.jsonl")
        let staleIncarnation = TerminalSessionIncarnation(terminal: terminal)
        try await database.terminals.updateTmuxIDs(
            id: terminal.id, windowID: "@current", paneID: "%current")
        let current = try #require(try await database.terminals.get(id: terminal.id))

        let replacement = try await database.terminals.replaceRecreatedCodexWindow(
            id: terminal.id,
            expectedIncarnation: staleIncarnation,
            windowID: "@stale",
            paneID: "%stale",
            at: Date(timeIntervalSinceReferenceDate: 20))

        #expect(replacement == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: current)
    }

    @Test func shellWindowReplacementRejectsStaleIncarnationWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .shell, label: "shell")
        let staleIncarnation = TerminalSessionIncarnation(terminal: terminal)
        try await database.terminals.updateTmuxIDs(
            id: terminal.id, windowID: "@current", paneID: "%current")
        let current = try #require(try await database.terminals.get(id: terminal.id))

        let replacement = try await database.terminals.replaceRecreatedShellWindow(
            id: terminal.id,
            expectedIncarnation: staleIncarnation,
            windowID: "@stale",
            paneID: "%stale",
            at: Date(timeIntervalSinceReferenceDate: 20))

        #expect(replacement == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: current)
    }

    @Test func profilePrelaunchTransitionAtomicallySetsIntentAndReturnsToken() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "stored-session",
            transcriptPath: "/tmp/stored-session.jsonl")
        let expectedState = try #require(try await database.terminals.get(id: terminal.id))
        let profileID = UUID()
        let token = try #require(try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: expectedState),
            sessionID: "stored-session",
            transcriptPath: "/tmp/stored-session.jsonl",
            profileID: profileID,
            at: Date(timeIntervalSinceReferenceDate: 20)))
        let prepared = try #require(try await database.terminals.get(id: terminal.id))
        #expect(prepared.profileID == profileID)
        #expect(prepared.sessionIncarnationID == token)
        #expect(prepared.claudeSessionID == "stored-session")
        #expect(prepared.transcriptPath == "/tmp/stored-session.jsonl")
        #expect(prepared.activityState == .unknown)

        _ = try #require(try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: prepared),
            reportedIncarnationID: token,
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 30)))
        let accepted = try #require(try await database.terminals.get(id: terminal.id))
        #expect(accepted.sessionIncarnationID == token)
        #expect(accepted.claudeSessionID == "replacement-session")
        #expect(accepted.transcriptPath == "/tmp/replacement-session.jsonl")
    }

    @Test func profilePrelaunchTransitionRejectsChangedStateWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "old-session",
            transcriptPath: "/tmp/old-session.jsonl")
        let stale = try #require(try await database.terminals.get(id: terminal.id))
        try await database.terminals.updateTmuxIDs(
            id: terminal.id,
            windowID: "@replacement",
            paneID: "%replacement")
        let replacement = try #require(try await database.terminals.get(id: terminal.id))

        let token = try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: stale),
            sessionID: "stale-session",
            transcriptPath: "/tmp/stale-session.jsonl",
            profileID: UUID(),
            at: Date(timeIntervalSinceReferenceDate: 20))

        #expect(token == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: replacement)
    }

    @Test func wakePreparationKeepsTerminalParkedUntilLaunchIsConfirmed() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "parked-session",
            transcriptPath: "/tmp/parked-session.jsonl")
        try await database.terminals.setHibernated(
            id: terminal.id,
            sessionID: "parked-session",
            reason: .manual,
            at: Date(timeIntervalSinceReferenceDate: 10))
        let parked = try #require(try await database.terminals.get(id: terminal.id))

        let token = try #require(try await database.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: parked),
            at: Date(timeIntervalSinceReferenceDate: 20)))
        let prepared = try #require(try await database.terminals.get(id: terminal.id))
        #expect(prepared.isParked)
        #expect(prepared.sessionIncarnationID == token)
        #expect(token != parked.sessionIncarnationID)
        #expect(prepared.claudeSessionID == "parked-session")
        #expect(prepared.transcriptPath == "/tmp/parked-session.jsonl")
        #expect(prepared.sessionOrderObservedAt == nil)
        #expect(prepared.codexTranscriptBoundaryOffset == nil)
        #expect(prepared.activityState == .unknown)

        _ = try #require(try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: prepared),
            reportedIncarnationID: token,
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 30)))
        _ = try #require(try await database.terminals.applyActivityObservation(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: Date(timeIntervalSinceReferenceDate: 31),
            sessionID: "replacement-session",
            sessionIncarnationID: token))
        try await database.terminals.clearHibernated(id: terminal.id)

        let released = try #require(try await database.terminals.get(id: terminal.id))
        #expect(!released.isParked)
        #expect(released.sessionIncarnationID == prepared.sessionIncarnationID)
        #expect(released.claudeSessionID == "replacement-session")
        #expect(released.transcriptPath == "/tmp/replacement-session.jsonl")
        #expect(released.activityState == .working)
    }

    @Test func hibernationBeginRejectsAReplacedProcessWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "old-session",
            transcriptPath: "/tmp/old-session.jsonl")
        let oldProcess = try #require(try await database.terminals.get(id: terminal.id))
        let replacementProfile = UUID()
        _ = try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: oldProcess),
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            profileID: replacementProfile,
            at: Date(timeIntervalSinceReferenceDate: 20))
        let replacement = try #require(try await database.terminals.get(id: terminal.id))

        let preparation = try await database.terminals.beginHibernatedShellRespawn(
            id: terminal.id,
            expectedState: TerminalHibernationSnapshot(terminal: oldProcess),
            snapshot: "stale snapshot",
            reason: .manual,
            at: Date(timeIntervalSinceReferenceDate: 30))

        #expect(preparation == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: replacement)
    }

    @Test func hibernationBeginRejectsChangedActivityWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "old-session",
            transcriptPath: "/tmp/old-session.jsonl")
        try await database.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: .derived,
            observedAt: Date(timeIntervalSinceReferenceDate: 10))
        let idle = try #require(try await database.terminals.get(id: terminal.id))
        let expected = TerminalHibernationSnapshot(terminal: idle)
        try await database.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("task_started"),
            observedAt: Date(timeIntervalSinceReferenceDate: 20))
        let working = try #require(try await database.terminals.get(id: terminal.id))

        let preparation = try await database.terminals.beginHibernatedShellRespawn(
            id: terminal.id,
            expectedState: expected,
            snapshot: "stale snapshot",
            reason: .manual,
            at: Date(timeIntervalSinceReferenceDate: 30))

        #expect(preparation == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: working)
    }

    @Test func hibernationBeginMakesOutgoingActivityInertBeforeProcessReplacement() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        let oldToken = try #require(try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: terminal),
            sessionID: "resume-session",
            transcriptPath: "/tmp/resume-session.jsonl",
            profileID: nil,
            at: Date(timeIntervalSinceReferenceDate: 10)))
        try await database.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: Date(timeIntervalSinceReferenceDate: 20))
        let working = try #require(try await database.terminals.get(id: terminal.id))

        let inertStage = try #require(
            try await database.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: TerminalHibernationSnapshot(terminal: working),
                reason: .manual,
                at: Date(timeIntervalSinceReferenceDate: 30)))

        let prepared = try #require(try await database.terminals.get(id: terminal.id))
        #expect(prepared.isParked)
        #expect(prepared.sessionIncarnationID == oldToken)
        let pendingToken = try #require(prepared.pendingSessionIncarnationID)
        #expect(pendingToken != oldToken)
        #expect(prepared.activityState == .idle)
        #expect(prepared.activityStateSource == .database)

        let staleActivity = try await database.terminals.applyActivityObservation(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: Date(timeIntervalSinceReferenceDate: 40),
            sessionID: "resume-session",
            sessionIncarnationID: oldToken)
        #expect(staleActivity == nil)
        #expect(try await database.terminals.get(id: terminal.id)?.activityState == .idle)
        let staleStart = try await database.terminals.applySessionStart(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: prepared),
            reportedIncarnationID: oldToken,
            sessionID: "stale-session",
            transcriptPath: "/tmp/stale-session.jsonl",
            observedAt: Date(timeIntervalSinceReferenceDate: 41))
        #expect(staleStart == nil)
        #expect(try await database.terminals.get(id: terminal.id)?.claudeSessionID
            == "resume-session")

        let shellToken = try #require(
            try await database.terminals.finalizeHibernatedShellRespawn(
                id: terminal.id,
                expectedIncarnation: inertStage,
                at: Date(timeIntervalSinceReferenceDate: 50)))
        #expect(shellToken == pendingToken)
        let finalized = try #require(try await database.terminals.get(id: terminal.id))
        #expect(finalized.sessionIncarnationID == pendingToken)
        #expect(finalized.pendingSessionIncarnationID == nil)
    }

    @Test func clearingInterruptedHibernationPreparationRestoresCurrentProcess() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        let oldToken = try #require(try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: terminal),
            sessionID: "current-session",
            transcriptPath: "/tmp/current-session.jsonl",
            profileID: nil,
            at: Date(timeIntervalSinceReferenceDate: 10)))
        let current = try #require(try await database.terminals.get(id: terminal.id))
        _ = try #require(try await database.terminals.beginHibernatedShellRespawn(
            id: terminal.id,
            expectedState: TerminalHibernationSnapshot(terminal: current),
            reason: .manual,
            at: Date(timeIntervalSinceReferenceDate: 20)))
        #expect(try await database.terminals.get(id: terminal.id)?
            .pendingSessionIncarnationID != nil)

        try await database.terminals.clearHibernated(id: terminal.id)

        let restored = try #require(try await database.terminals.get(id: terminal.id))
        #expect(!restored.isParked)
        #expect(restored.sessionIncarnationID == oldToken)
        #expect(restored.pendingSessionIncarnationID == nil)
    }

    @Test func wakePreparationReplacesAnInterruptedHibernationStage() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        let oldToken = try #require(try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: terminal),
            sessionID: "resume-session",
            transcriptPath: "/tmp/resume-session.jsonl",
            profileID: nil,
            at: Date(timeIntervalSinceReferenceDate: 10)))
        let current = try #require(try await database.terminals.get(id: terminal.id))
        _ = try #require(try await database.terminals.beginHibernatedShellRespawn(
            id: terminal.id,
            expectedState: TerminalHibernationSnapshot(terminal: current),
            reason: .manual,
            at: Date(timeIntervalSinceReferenceDate: 20)))
        let interrupted = try #require(try await database.terminals.get(id: terminal.id))
        let stagedToken = try #require(interrupted.pendingSessionIncarnationID)

        let wakeToken = try #require(try await database.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: interrupted),
            at: Date(timeIntervalSinceReferenceDate: 30)))

        let prepared = try #require(try await database.terminals.get(id: terminal.id))
        #expect(prepared.isParked)
        #expect(wakeToken != oldToken)
        #expect(wakeToken != stagedToken)
        #expect(prepared.sessionIncarnationID == wakeToken)
        #expect(prepared.pendingSessionIncarnationID == nil)
    }

    @Test func hibernationFinalizeRejectsAReplacedInertStageWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "old-session",
            transcriptPath: "/tmp/old-session.jsonl")
        let oldProcess = try #require(try await database.terminals.get(id: terminal.id))
        let inertStage = try #require(
            try await database.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: TerminalHibernationSnapshot(terminal: oldProcess),
                snapshot: "parked snapshot",
                reason: .manual,
                at: Date(timeIntervalSinceReferenceDate: 20)))
        let replacementProfile = UUID()
        let inert = try #require(try await database.terminals.get(id: terminal.id))
        _ = try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: inert),
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            profileID: replacementProfile,
            at: Date(timeIntervalSinceReferenceDate: 30))
        let replacement = try #require(try await database.terminals.get(id: terminal.id))

        let shellToken = try await database.terminals.finalizeHibernatedShellRespawn(
            id: terminal.id,
            expectedIncarnation: inertStage,
            at: Date(timeIntervalSinceReferenceDate: 40))

        #expect(shellToken == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: replacement)
    }

    @Test func hibernationBeginRejectsChangedCoordinatesWithMatchingToken() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        let token = try #require(try await database.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: terminal),
            sessionID: "replacement-session",
            transcriptPath: "/tmp/replacement-session.jsonl",
            profileID: UUID(),
            at: Date(timeIntervalSinceReferenceDate: 10)))
        let expected = try #require(try await database.terminals.get(id: terminal.id))
        #expect(expected.sessionIncarnationID == token)
        try await setCoordinatesWithoutRotating(
            terminalID: terminal.id,
            windowID: "@replacement",
            paneID: "%replacement",
            in: database)
        let replacement = try #require(try await database.terminals.get(id: terminal.id))

        let preparation = try await database.terminals.beginHibernatedShellRespawn(
            id: terminal.id,
            expectedState: TerminalHibernationSnapshot(terminal: expected),
            snapshot: "stale snapshot",
            reason: .manual,
            at: Date(timeIntervalSinceReferenceDate: 20))

        #expect(preparation == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: replacement)
    }

    @Test func hibernationFinalizeRejectsChangedCoordinatesWithMatchingToken() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        let current = try #require(try await database.terminals.get(id: terminal.id))
        let inertStage = try #require(
            try await database.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: TerminalHibernationSnapshot(terminal: current),
                reason: .manual,
                at: Date(timeIntervalSinceReferenceDate: 10)))
        try await setCoordinatesWithoutRotating(
            terminalID: terminal.id,
            windowID: "@replacement",
            paneID: "%replacement",
            in: database)
        let replacement = try #require(try await database.terminals.get(id: terminal.id))

        let shellToken = try await database.terminals.finalizeHibernatedShellRespawn(
            id: terminal.id,
            expectedIncarnation: inertStage,
            at: Date(timeIntervalSinceReferenceDate: 20))

        #expect(shellToken == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: replacement)
    }

    @Test func wakePreparationRejectsAChangedParkedProfileWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "resume-session",
            transcriptPath: "/tmp/resume-session.jsonl")
        try await database.terminals.setHibernated(
            id: terminal.id, sessionID: "resume-session")
        let expected = try #require(try await database.terminals.get(id: terminal.id))
        try await database.terminals.setProfileID(id: terminal.id, profileID: UUID())
        let changed = try #require(try await database.terminals.get(id: terminal.id))

        let token = try await database.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: expected),
            at: Date(timeIntervalSinceReferenceDate: 30))

        #expect(token == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: changed)
    }

    @Test func parkedProfileSwapRejectsACompletedWakeWithoutMutation() async throws {
        let (database, terminal) = try await makeTerminal(kind: .claude, label: "claude")
        try await database.terminals.updateSession(
            id: terminal.id,
            sessionID: "resume-session",
            transcriptPath: "/tmp/resume-session.jsonl")
        try await database.terminals.setHibernated(
            id: terminal.id, sessionID: "resume-session")
        let expected = try #require(try await database.terminals.get(id: terminal.id))
        try await database.terminals.clearHibernated(id: terminal.id)
        let woken = try #require(try await database.terminals.get(id: terminal.id))

        let swapped = try await database.terminals.setParkedProfileID(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: expected),
            profileID: UUID())

        #expect(swapped == nil)
        let unchanged = try #require(try await database.terminals.get(id: terminal.id))
        assertReplacementState(unchanged, equals: woken)
    }

    private func assertReplacementState(_ actual: Terminal, equals expected: Terminal) {
        #expect(actual.sessionIncarnationID == expected.sessionIncarnationID)
        #expect(actual.pendingSessionIncarnationID == expected.pendingSessionIncarnationID)
        #expect(actual.tmuxWindowID == expected.tmuxWindowID)
        #expect(actual.tmuxPaneID == expected.tmuxPaneID)
        #expect(actual.label == expected.label)
        #expect(actual.profileID == expected.profileID)
        #expect(actual.claudeSessionID == expected.claudeSessionID)
        #expect(actual.transcriptPath == expected.transcriptPath)
        #expect(actual.sessionOrderObservedAt == expected.sessionOrderObservedAt)
        #expect(actual.codexTranscriptBoundaryOffset
                == expected.codexTranscriptBoundaryOffset)
        #expect(actual.activityState == expected.activityState)
        #expect(actual.activityStateSource == expected.activityStateSource)
        #expect(actual.activityStateObservedAt == expected.activityStateObservedAt)
        #expect(actual.activityStateOrderObservedAt
                == expected.activityStateOrderObservedAt)
        #expect(actual.hibernatedAt == expected.hibernatedAt)
        #expect(actual.hibernateReason == expected.hibernateReason)
        #expect(actual.suspendedSnapshot == expected.suspendedSnapshot)
    }

    private func makeTerminal(
        kind: TerminalKind,
        label: String
    ) async throws -> (TBDDatabase, Terminal) {
        let database = try TBDDatabase(inMemory: true)
        let repo = try await database.repos.create(
            path: "/tmp/session-respawn-repo-\(UUID().uuidString)",
            displayName: "Respawn", defaultBranch: "main")
        let worktree = try await database.worktrees.create(
            repoID: repo.id, name: "respawn", branch: "respawn",
            path: "/tmp/session-respawn-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-session-respawn")
        let terminal = try await database.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            kind: kind)
        return (database, terminal)
    }

    private func setIncarnation(
        _ incarnationID: UUID,
        terminalID: UUID,
        in database: TBDDatabase
    ) async throws {
        try await database.writerForTests.write { connection in
            try connection.execute(
                sql: "UPDATE terminal SET sessionIncarnationID = ? WHERE id = ?",
                arguments: [incarnationID.uuidString, terminalID.uuidString])
        }
    }

    private func setCoordinatesWithoutRotating(
        terminalID: UUID,
        windowID: String,
        paneID: String,
        in database: TBDDatabase
    ) async throws {
        try await database.writerForTests.write { connection in
            try connection.execute(
                sql: "UPDATE terminal SET tmuxWindowID = ?, tmuxPaneID = ? WHERE id = ?",
                arguments: [windowID, paneID, terminalID.uuidString])
        }
    }
}
