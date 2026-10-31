import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2 — real files in a temp directory, because the reader's contract
/// includes a byte-bounded tail read, which does not survive being mocked
/// away. No `TBD_HOME` involved: every path is passed in.
@Suite struct ContextLoadReaderTests {

    private struct Scratch {
        let root: URL
        let transcriptPath: String

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-ctx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            transcriptPath = root.appendingPathComponent("transcript.jsonl").path
        }

        /// Two assistant records; the later one is what the reader must use.
        func writeTranscript(tokens: Int, timestamp: String) throws {
            let earlier = #"{"type":"assistant","timestamp":"2026-08-10T00:00:00Z","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
            let latest = """
            {"type":"assistant","timestamp":"\(timestamp)","message":{"usage":\
            {"input_tokens":\(tokens - 30),"output_tokens":9999,\
            "cache_creation_input_tokens":20,"cache_read_input_tokens":10}}}
            """
            try Data(([earlier, latest].joined(separator: "\n") + "\n").utf8)
                .write(to: URL(fileURLWithPath: transcriptPath))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static let transcriptStamp = "2026-08-10T12:00:00Z"
    private static var transcriptDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: transcriptStamp)!
    }

    // MARK: - Spawned without the session mod's `usage`

    @Test func aSessionSpawnedWithoutUsageReportsAnUnknownWindowNamingTheCase() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 120_000, timestamp: Self.transcriptStamp)

        let load = ContextLoadReader().read(transcriptPath: scratch.transcriptPath)

        // Never a guess. The numerator is real and labeled with where it came
        // from; the denominator says it does not know, and why.
        let used = try #require(load.used)
        #expect(used.value == 120_000)
        #expect(used.source == .transcriptTail)
        #expect(used.observedAt == Self.transcriptDate)
        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window, got \(load.window)")
            return
        }
        #expect(why.contains("spawned without the session mod's usage feature"))
        #expect(!load.isPairedReading)
    }

    @Test func noTranscriptLeavesBothHalvesHonestlyEmpty() {
        let load = ContextLoadReader().read(transcriptPath: nil)
        #expect(load.used == nil)
        #expect(load.percentUsed() == nil)
    }

    @Test func theTwoHundredKFallbackIsLabelledEverywhereItIsUsed() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 100_000, timestamp: Self.transcriptStamp)

        let load = ContextLoadReader().read(transcriptPath: scratch.transcriptPath)

        let percent = try #require(load.percentUsed())
        #expect(percent.percent == 50.0)
        // The flag rides with the number: a caller cannot receive the
        // percentage without also receiving "this denominator was assumed".
        #expect(percent.assumedWindow)
        #expect(load.window.effectiveTokens() == (ContextWindow.assumedTokens, true))
    }

    // MARK: - The tail read

    @Test func tailReadIsByteBoundedAndTolerantOfATruncatedFirstLine() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        var lines: [String] = []
        for index in 1...500 {
            lines.append(
                #"{"type":"assistant","message":{"usage":{"input_tokens":\#(index),"#
                + #""cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: URL(fileURLWithPath: scratch.transcriptPath))

        var reader = ContextLoadReader()
        reader.tailWindowBytes = 512

        let load = reader.read(transcriptPath: scratch.transcriptPath)

        // The window lands mid-record, so the first line in it is a fragment.
        // It is skipped, and the last complete record still wins.
        #expect(load.used?.value == 500)
    }

    @Test func recordWithoutATimestampFallsBackToTheInjectedDate() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let line = #"{"message":{"usage":{"input_tokens":42}}}"# + "\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: scratch.transcriptPath))
        let fixed = Date(timeIntervalSince1970: 1_234_567)

        var reader = ContextLoadReader()
        reader.now = { fixed }

        let load = reader.read(transcriptPath: scratch.transcriptPath)

        #expect(load.used?.observedAt == fixed)
        // Cache buckets absent entirely — defaulted to zero, not treated as a
        // parse failure, since sessions without prompt caching omit them.
        #expect(load.used?.value == 42)
    }

    /// The ASCII cut above is the easy case. A real transcript is full of
    /// emoji, box drawing and curly quotes, so a byte-offset tail routinely
    /// starts **inside** a multi-byte sequence — and strict UTF-8 decoding
    /// answers nil for the whole tail when it does, erasing a numerator that
    /// was sitting there in plain ASCII a few hundred bytes later. The failure
    /// is indistinguishable from a missing transcript, which is what makes it
    /// worth a test of its own.
    @Test func aTailCutInsideAMultiByteSequenceStillReportsTheNumerator() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        // 4-byte emoji as the padding — ordinary agent output.
        let padding = String(repeating: "🙂", count: 200)
        let filler = #"{"type":"user","message":{"content":"\#(padding)"}}"#
        let record = #"{"type":"assistant","message":{"usage":{"input_tokens":777,"#
            + #""cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let bytes = Data((filler + "\n" + record + "\n").utf8)
        try bytes.write(to: URL(fileURLWithPath: scratch.transcriptPath))

        // Pin the cut **inside** the filler's last emoji rather than hoping for
        // it: the tail then opens on a UTF-8 continuation byte, which is the
        // exact shape that used to erase the whole read.
        let lastEmojiStart = try #require(
            bytes.range(of: Data("🙂".utf8), options: .backwards)?.lowerBound)
        let cut = lastEmojiStart + 1
        #expect(bytes[cut] & 0xC0 == 0x80, "the cut must land on a continuation byte")
        #expect(String(data: bytes[cut...], encoding: .utf8) == nil,
                "if this tail decodes strictly, the test is not exercising the defect")

        var reader = ContextLoadReader()
        reader.tailWindowBytes = bytes.count - cut

        let load = reader.read(transcriptPath: scratch.transcriptPath)

        #expect(load.used?.value == 777,
                "a tail cut mid-codepoint erased a numerator that was plainly there")
    }

    @Test func unreadableTranscriptIsAbsenceNotZero() {
        let load = ContextLoadReader().read(transcriptPath: "/nonexistent/transcript.jsonl")
        #expect(load.used == nil)
    }

    // MARK: - The session mod's usage file

    private static let liveIncarnation = UUID()
    private static let usageMeasuredAtMs: Int64 = 1_770_000_000_000
    private static var usageMeasuredAt: Date {
        Date(timeIntervalSince1970: Double(usageMeasuredAtMs) / 1000)
    }

    /// The shape `SessionMod/hooks/features/usage.ts` writes, with the window
    /// spelled as a raw JSON literal so a test can hand it a malformed one.
    private static func usageJSON(
        window: String = "200000", tokens: Int? = 50_000,
        incarnationID: String = ContextLoadReaderTests.liveIncarnation.uuidString
    ) -> String {
        let tokensField = tokens.map { #","tokens":\#($0),"percent":25"# } ?? ""
        return """
        {"schemaVersion":1,"claudeSessionID":"s","incarnationID":"\(incarnationID)",\
        "measuredAt":\(usageMeasuredAtMs),"context":{"window":\(window)\(tokensField)},\
        "rateLimits":[{"kind":"five_hour","percentUsed":12}],"cost":{"usd":1.5}}
        """
    }

    private func writeUsage(_ json: String, in scratch: Scratch) throws -> String {
        let path = scratch.root.appendingPathComponent(SessionModFiles.usageFileName).path
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func confirmedUsageGivesThePairedReadingFromTheFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        // The transcript exists and disagrees — the file the spawn chose wins.
        try scratch.writeTranscript(tokens: 999_999, timestamp: Self.transcriptStamp)
        let usagePath = try writeUsage(Self.usageJSON(), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: Self.liveIncarnation,
            usageLiveness: .confirmed,
            transcriptPath: scratch.transcriptPath)

        let used = try #require(load.used)
        #expect(used == ObservedFact(value: 50_000, source: .sessionMod, observedAt: Self.usageMeasuredAt))
        #expect(load.window == .observed(
            ObservedFact(value: 200_000, source: .sessionMod, observedAt: Self.usageMeasuredAt)))
        #expect(load.isPairedReading)
        #expect(load.percentUsed()?.percent == 25.0)
        #expect(load.percentUsed()?.assumedWindow == false)
    }

    /// The `session.start` baseline carries the window before any response
    /// reported a fill. The window is observed; the numerator is the
    /// transcript's, and the pair is not presented as one reading.
    @Test func aBaselineWithoutTokensKeepsTheWindowAndTakesTheTranscriptNumerator() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 40_000, timestamp: Self.transcriptStamp)
        let usagePath = try writeUsage(Self.usageJSON(tokens: nil), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: Self.liveIncarnation,
            usageLiveness: .confirmed,
            transcriptPath: scratch.transcriptPath)

        #expect(load.window == .observed(
            ObservedFact(value: 200_000, source: .sessionMod, observedAt: Self.usageMeasuredAt)))
        #expect(load.used == ObservedFact(value: 40_000, source: .transcriptTail, observedAt: Self.transcriptDate))
        #expect(!load.isPairedReading)
    }

    /// `$.fs` has no rename, so a reader can meet a file cut off mid-write.
    /// That is "not observed", never a zero window.
    @Test func aTornUsageFileIsAnUnknownWindowNotAZero() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 60_000, timestamp: Self.transcriptStamp)
        let full = Self.usageJSON()
        let usagePath = try writeUsage(String(full.prefix(full.count / 2)), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: Self.liveIncarnation,
            usageLiveness: .confirmed,
            transcriptPath: scratch.transcriptPath)

        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window for a torn usage file, got \(load.window)")
            return
        }
        #expect(why.contains("unreadable"))
        #expect(load.used == ObservedFact(value: 60_000, source: .transcriptTail, observedAt: Self.transcriptDate))
    }

    @Test func aMissingUsageFileIsAnUnknownWindow() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }

        let load = ContextLoadReader().read(
            usagePath: scratch.root.appendingPathComponent(SessionModFiles.usageFileName).path,
            usageLiveness: .confirmed, transcriptPath: nil)

        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window for a missing usage file, got \(load.window)")
            return
        }
        #expect(why.contains("has not been written yet"))
        #expect(load.used == nil)
    }

    /// A boolean, zero, a negative, a fraction, a string or null is no window.
    /// JSON `true` is the sharp one — it would otherwise read as a one-token
    /// window.
    @Test(arguments: ["true", "false", "0", "-1", "1.5", #""200000""#, "null", "[]", "{}"])
    func aMalformedUsageWindowIsNoWindowRatherThanAWrongOne(literal: String) throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 70_000, timestamp: Self.transcriptStamp)
        let usagePath = try writeUsage(Self.usageJSON(window: literal), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: Self.liveIncarnation,
            usageLiveness: .confirmed,
            transcriptPath: scratch.transcriptPath)

        guard case .unknown = load.window else {
            Issue.record("window literal \(literal) was read as \(load.window)")
            return
        }
        #expect(load.used?.source == .transcriptTail)
    }

    /// A confirmed mod vouches for the process, not for the file: the new
    /// process's heartbeat can land before its first usage write, leaving the
    /// file an earlier process of the same session wrote.
    @Test func aUsageFileFromAnEarlierProcessIsAnUnknownWindow() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 42_000, timestamp: Self.transcriptStamp)
        let live = UUID()
        let stalePath = try writeUsage(Self.usageJSON(incarnationID: UUID().uuidString), in: scratch)

        let stale = ContextLoadReader().read(
            usagePath: stalePath, usageIncarnationID: live,
            usageLiveness: .confirmed, transcriptPath: scratch.transcriptPath)
        guard case .unknown(let why) = stale.window else {
            Issue.record("expected an unknown window for an earlier process's file, got \(stale.window)")
            return
        }
        #expect(why.contains("earlier process"))
        #expect(stale.used?.source == .transcriptTail)
        #expect(stale.used?.value == 42_000)

        // The same file naming the live incarnation — lowercased, since the
        // comparison is by UUID rather than by text — is this process's reading.
        let ownPath = try writeUsage(
            Self.usageJSON(incarnationID: live.uuidString.lowercased()), in: scratch)
        let own = ContextLoadReader().read(
            usagePath: ownPath, usageIncarnationID: live,
            usageLiveness: .confirmed, transcriptPath: scratch.transcriptPath)
        #expect(own.window == .observed(
            ObservedFact(value: 200_000, source: .sessionMod, observedAt: Self.usageMeasuredAt)))
        #expect(own.isPairedReading)
    }

    /// A spawn that chose to record its usage through the mod, but whose mod
    /// has not confirmed itself, reports no window and takes its numerator
    /// from the transcript.
    @Test func anUnconfirmedModTakesTheTranscriptNumerator() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 80_000, timestamp: Self.transcriptStamp)
        let usagePath = try writeUsage(Self.usageJSON(), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath,
            usageLiveness: .unknown(.noAliveFile),
            transcriptPath: scratch.transcriptPath)

        guard case .unknown(let why) = load.window else {
            Issue.record("expected an unknown window for an unconfirmed mod, got \(load.window)")
            return
        }
        #expect(why.contains(SessionModLiveness.UnknownReason.noAliveFile.rawValue))
        #expect(load.used == ObservedFact(value: 80_000, source: .transcriptTail, observedAt: Self.transcriptDate))
    }

    /// Only a confirmed mod vouches for the process. Every unknown reason — a
    /// stale heartbeat included — leaves it unvouched for, so even a file
    /// naming the live incarnation is not read.
    @Test(arguments: [
        SessionModLiveness.UnknownReason.noAliveFile, .otherIncarnation, .staleHeartbeat, .featureNotRunning,
        .unreadableFile,
    ])
    func unknownReasonsDoNotReadTheUsageFile(reason: SessionModLiveness.UnknownReason) throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let live = UUID()
        let usagePath = try writeUsage(Self.usageJSON(incarnationID: live.uuidString), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: live,
            usageLiveness: .unknown(reason), transcriptPath: nil)

        guard case .unknown(let why) = load.window else {
            Issue.record("reason \(reason.rawValue) read the usage file as \(load.window)")
            return
        }
        #expect(why.contains(reason.rawValue))
    }

    /// A spawn made without `usage` reports no window, whatever a usage file
    /// on disk says: nothing vouches that this process wrote it.
    @Test func aLegacySpawnIgnoresAUsageFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.writeTranscript(tokens: 30_000, timestamp: Self.transcriptStamp)
        let usagePath = try writeUsage(Self.usageJSON(), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: Self.liveIncarnation,
            usageLiveness: .legacy, transcriptPath: scratch.transcriptPath)

        guard case .unknown(let why) = load.window else {
            Issue.record("a legacy spawn read a usage file's window: \(load.window)")
            return
        }
        #expect(why.contains("spawned without the session mod's usage feature"))
        #expect(load.used == ObservedFact(value: 30_000, source: .transcriptTail, observedAt: Self.transcriptDate))
    }

    // MARK: - The gatherer's liveness check

    /// End to end through the session files: the gatherer evaluates liveness
    /// against the row's live incarnation, and only a Claude row reads the
    /// mod's file.
    @Test func theGathererReadsUsageOnlyForAConfirmedClaudeSession() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let pinned = Date(timeIntervalSince1970: 1_770_000_010)
        let sessionsDir = scratch.root.appendingPathComponent("sessions", isDirectory: true)
        let sessionID = "sess-usage"
        let incarnation = UUID()
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: sessionID, incarnationId: incarnation.uuidString,
                  spawnedAtMs: Self.usageMeasuredAtMs, features: ["usage"]),
            sessionsDir: sessionsDir)
        let dir = try #require(
            SessionModFiles.directory(sessionsDir: sessionsDir, claudeSessionID: sessionID))
        try JSONEncoder().encode(SessionModFiles.AliveRecord(
            sessionId: sessionID, incarnationId: incarnation.uuidString, features: ["usage"],
            heartbeatAtMs: Int64(pinned.timeIntervalSince1970 * 1000)))
            .write(to: dir.appendingPathComponent(SessionModFiles.aliveFileName))
        try Data(Self.usageJSON(incarnationID: incarnation.uuidString).utf8)
            .write(to: dir.appendingPathComponent(SessionModFiles.usageFileName))

        let gatherer = SessionStateFactGatherer(now: { pinned }, sessionsDir: sessionsDir)

        let claude = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@0", tmuxPaneID: "%0",
            claudeSessionID: sessionID, sessionIncarnationID: incarnation, kind: .claude)
        let load = gatherer.contextLoad(for: claude)
        #expect(load.window == .observed(
            ObservedFact(value: 200_000, source: .sessionMod, observedAt: Self.usageMeasuredAt)))
        #expect(load.isPairedReading)

        // Another incarnation of the same session: the spawn record does not
        // vouch for it, so it is legacy and reads no window.
        var respawned = claude
        respawned.sessionIncarnationID = UUID()
        Self.expectLegacy(gatherer.contextLoad(for: respawned).window)

        // The same session whose heartbeat is older than the staleness bound:
        // the mod is no longer confirmed, so even its own file is not read.
        let stale = SessionStateFactGatherer(
            now: { pinned.addingTimeInterval(SessionModSessionFiles.heartbeatStaleAfter + 60) },
            sessionsDir: sessionsDir)
        let staleWindow = stale.contextLoad(for: claude).window
        if case .unknown(let why) = staleWindow {
            #expect(why.contains(SessionModLiveness.UnknownReason.staleHeartbeat.rawValue))
        } else {
            Issue.record("a stale heartbeat read a window: \(staleWindow)")
        }

        // A Codex row never reads the mod's file: it is legacy.
        var codex = claude
        codex.kind = .codex
        Self.expectLegacy(gatherer.contextLoad(for: codex).window)
    }

    /// The window a spawn made without `usage` reports: unknown, saying so.
    private static func expectLegacy(
        _ window: ContextWindow, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .unknown(let why) = window else {
            Issue.record("expected a legacy spawn's unknown window, got \(window)",
                         sourceLocation: sourceLocation)
            return
        }
        #expect(why.contains("spawned without the session mod's usage feature"),
                sourceLocation: sourceLocation)
    }

    // MARK: - A parked session

    /// A Claude session whose spawn record names `incarnation` with `features`,
    /// whose mod heartbeat and usage file were written by that incarnation,
    /// and which is then parked through `TerminalStore.setHibernated` — the
    /// production park write, which gives the row a fresh incarnation for the
    /// inert shell. Returns the parked row as the store reads it back.
    private func parkedSession(
        features: [String], incarnation: UUID, sessionsDir: URL, heartbeatAt: Date
    ) async throws -> Terminal {
        let sessionID = "sess-parked"
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: sessionID, incarnationId: incarnation.uuidString,
                  spawnedAtMs: Self.usageMeasuredAtMs, features: features),
            sessionsDir: sessionsDir)
        let directory = SessionModFiles.directory(sessionsDir: sessionsDir, claudeSessionID: sessionID)
        let dir = try #require(directory)
        try JSONEncoder().encode(SessionModFiles.AliveRecord(
            sessionId: sessionID, incarnationId: incarnation.uuidString, features: features,
            heartbeatAtMs: Int64(heartbeatAt.timeIntervalSince1970 * 1000)))
            .write(to: dir.appendingPathComponent(SessionModFiles.aliveFileName))
        try Data(Self.usageJSON(incarnationID: incarnation.uuidString).utf8)
            .write(to: dir.appendingPathComponent(SessionModFiles.usageFileName))

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/ctx-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/ctx-wt-\(UUID().uuidString)", tmuxServer: "tbd-ctx")
        let created = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: sessionID, kind: .claude,
            sessionIncarnationID: incarnation)
        try await db.terminals.setHibernated(id: created.id, sessionID: sessionID)
        let fetched = try await db.terminals.get(id: created.id)
        let parked = try #require(fetched)
        // The premise the parked rule exists for: the row no longer names the
        // incarnation that wrote the files.
        #expect(parked.isParked)
        #expect(parked.sessionIncarnationID != incarnation)
        return parked
    }

    /// A parked session whose last spawn ran `usage` has no process reporting
    /// its window. Its usage file is not read — even one naming the spawn
    /// record's incarnation, since that shared record cannot say whose file is
    /// on disk: the window is unknown and says the session is parked, and the
    /// numerator comes from the transcript.
    @Test func aParkedUsageSessionIsAnUnknownWindow() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let sessionsDir = scratch.root.appendingPathComponent("sessions", isDirectory: true)
        let heartbeatAt = Date(timeIntervalSince1970: 1_770_000_010)
        let parked = try await parkedSession(
            features: ["usage"], incarnation: UUID(), sessionsDir: sessionsDir, heartbeatAt: heartbeatAt)
        try scratch.writeTranscript(tokens: 90_000, timestamp: Self.transcriptStamp)
        var row = parked
        row.transcriptPath = scratch.transcriptPath

        // Within the heartbeat bound, so only parking decides the answer.
        let gatherer = SessionStateFactGatherer(now: { heartbeatAt }, sessionsDir: sessionsDir)
        let load = gatherer.contextLoad(for: row)
        guard case .unknown(let why) = load.window else {
            Issue.record("a parked usage session read a window: \(load.window)")
            return
        }
        #expect(why.contains("parked"))
        #expect(load.used == ObservedFact(value: 90_000, source: .transcriptTail, observedAt: Self.transcriptDate))
    }

    /// A woken process whose `clearHibernated` failed still has a parked row,
    /// but its mod confirms against the row's live incarnation and has written
    /// its own usage file: the window is that file's, not "parked".
    @Test func aParkedRowWithConfirmedLivenessReadsItsOwnUsageFile() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let sessionsDir = scratch.root.appendingPathComponent("sessions", isDirectory: true)
        let heartbeatAt = Date(timeIntervalSince1970: 1_770_000_010)
        let incarnation = UUID()
        let parked = try await parkedSession(
            features: ["usage"], incarnation: incarnation, sessionsDir: sessionsDir,
            heartbeatAt: heartbeatAt)
        try scratch.writeTranscript(tokens: 90_000, timestamp: Self.transcriptStamp)
        var row = parked
        row.transcriptPath = scratch.transcriptPath
        row.sessionIncarnationID = incarnation

        let gatherer = SessionStateFactGatherer(now: { heartbeatAt }, sessionsDir: sessionsDir)
        let load = gatherer.contextLoad(for: row)
        #expect(load.window == .observed(
            ObservedFact(value: 200_000, source: .sessionMod, observedAt: Self.usageMeasuredAt)))
    }

    /// A missing live incarnation is unknown, so a confirmed read accepts no file.
    @Test func aMissingLiveIncarnationAcceptsNoUsageFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let usagePath = try writeUsage(Self.usageJSON(), in: scratch)

        let load = ContextLoadReader().read(
            usagePath: usagePath, usageIncarnationID: nil,
            usageLiveness: .confirmed, transcriptPath: nil)

        guard case .unknown = load.window else {
            Issue.record("a nil live incarnation accepted a usage file: \(load.window)")
            return
        }
    }

    /// A parked session whose last spawn ran without `usage` is legacy, as a
    /// live one would be — not "parked".
    @Test func aParkedSessionSpawnedWithoutUsageIsLegacy() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let sessionsDir = scratch.root.appendingPathComponent("sessions", isDirectory: true)
        let heartbeatAt = Date(timeIntervalSince1970: 1_770_000_010)
        let parked = try await parkedSession(
            features: [], incarnation: UUID(), sessionsDir: sessionsDir, heartbeatAt: heartbeatAt)

        let gatherer = SessionStateFactGatherer(
            now: { heartbeatAt.addingTimeInterval(86_400) }, sessionsDir: sessionsDir)
        Self.expectLegacy(gatherer.contextLoad(for: parked).window)
    }
}
