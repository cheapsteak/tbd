import Foundation

/// One shadow peer's row in Claude Code's peer registry — the record half of
/// the membership test `docs/cross-session-messaging.md` defines (a record plus
/// a socket that answers a connect).
///
/// **This type's key set is the contract, and it is a whitelist.** A record
/// carrying one key Claude Code does not itself define survives on disk and is
/// silently absent from every listing — measured, on four probe records driven
/// with `ListAgents`, and the single most consequential fact in
/// `docs/specs/2026-08-29-remote-peer-messaging-design.md` § "What was
/// measured". So there is no marker field, no namespace, and nothing of TBD's
/// own inside the record; TBD recognises its own shadows **only** from its own
/// durable bookkeeping. Adding a property here without adding its name to
/// `claudeCodeDefinedKeys` makes every shadow invisible at once, which is why
/// the composed key set is pinned by a test rather than reviewed by eye.
///
/// **There is deliberately no `tmux` case in `CodingKeys`.** A shadow has no
/// local terminal, and remote coordinates would be actively harmful: the far
/// host's tmux server is also called `main` and also has a pane `%388`, so the
/// row would look joinable against local panes and join to the wrong terminal.
/// A record with no `tmux` key lists correctly — measured. The absence is
/// structural (the key cannot be encoded) rather than a nil that a later edit
/// could fill in.
public struct ShadowPeerRecord: Sendable, Equatable, Codable {
    /// The helper's own real pid, in the local `darwin` domain. The registry
    /// loader parses the pid from the record's **filename** and rejects a
    /// filename that does not round-trip as an integer, so this field and
    /// `ShadowPeerRecordStore.recordURL(pid:)` must always agree.
    public let pid: pid_t
    /// A session id minted for this shadow. Opaque to Claude Code; TBD's own
    /// bookkeeping is what ties it back to a remote session.
    public let sessionID: String
    /// A working directory for the row. A shadow has no local one, so the
    /// daemon supplies a path that exists locally — the worktree the remote
    /// session was adopted into — rather than a remote path that would resolve
    /// to nothing on this machine.
    public let cwd: String
    /// Milliseconds since the epoch, matching the `startedAt` on every live
    /// record. Separate from `procStart`: this is when the *peer* started, not
    /// when the process did.
    public let startedAtMilliseconds: Int
    /// The helper process's own start time, read from the kernel — see
    /// `ProcessStartTime`. It must describe the process the record is filed
    /// under: Claude Code's reaper checks pid liveness and nothing else
    /// (measured), so a wrong value here is invisible to it and is exactly what
    /// TBD's own sweep uses to recognise a recycled-pid ghost.
    public let procStart: String
    /// The peer protocol this shadow speaks. Sourced from the remote session's
    /// own registry row via the `messages` stream's `peer` line, never asserted.
    public let peerProtocol: Int
    /// **Only what the bridge actually carries.** A feature echoed from the far
    /// side that the bridge does not forward — idle notification, say — would
    /// silently never fire. For v1 the bridge forwards message frames and
    /// nothing else, so this is `bridgedPeerFeatures`, which is empty.
    public let peerFeatures: [String]
    /// `"interactive"` — the kind every session a shadow stands for is.
    public let kind: String
    /// `"cli"` — the entrypoint every session a shadow stands for was launched
    /// through.
    public let entrypoint: String
    /// `"darwin"`. **The local domain, deliberately, not the origin's.** A
    /// foreign `pidDomain` would make Claude Code's reaper skip the record
    /// forever — it refuses to collect a record whose domain is not ours,
    /// because a foreign pid's liveness cannot be checked locally — which opts
    /// out of the only garbage collector that exists in exactly the scenarios
    /// where TBD is not running to collect. See the design's rejected
    /// alternatives.
    public let pidDomain: String
    /// The socket this record's helper owns and answers connects on.
    public let messagingSocketPath: String
    /// `<provider>:<worktree display name>` — the whole identity of a shadow
    /// peer, since the pane join that disambiguates local peers is unavailable.
    public let name: String
    /// `"user"`: TBD names a shadow explicitly rather than letting anything
    /// derive one from a working directory.
    public let nameSource: String
    /// The remote session's status, verbatim from its own registry row. A
    /// record published once and never updated shows a frozen status forever,
    /// so the helper rewrites this — see `withStatus(_:)`.
    public let status: String
    /// The agent version, when one is known. **Absent by default**, and that is
    /// a deliberate choice between two unmeasured risks: a fabricated version
    /// is a quiet wrongness that survives a soak, while an omitted key — if the
    /// loader turned out to require it — makes the shadow fail to list, which
    /// is loud on the first try. Set it when the far side reports one.
    public let version: String?

    // MARK: - The values TBD stamps

    /// The local pid domain. See `pidDomain`.
    public static let localPIDDomain = "darwin"
    /// `kind` for every shadow.
    public static let interactiveKind = "interactive"
    /// `entrypoint` for every shadow.
    public static let cliEntrypoint = "cli"
    /// `nameSource` for every shadow.
    public static let userNameSource = "user"

    /// What the bridge carries, and therefore the whole of `peerFeatures`.
    ///
    /// **Empty, and untested against Claude Code's loader**: every live record
    /// observed carried a non-empty list, so an empty one has never been driven
    /// through `ListAgents`. It is here as a named constant, in one place, so
    /// that adding the first genuinely-forwarded feature — or discovering the
    /// loader needs a non-empty list — is a one-line change rather than a hunt.
    /// Anything added here must actually be forwarded by the bridge; a feature
    /// advertised and not carried fails silently, which is the failure mode the
    /// design calls out by name.
    public static let bridgedPeerFeatures: [String] = []

    // MARK: - The wire

    /// Every field name a shadow's record puts on disk. **No `tmux`**, and
    /// nothing of TBD's own.
    enum CodingKeys: String, CodingKey {
        case pid
        case sessionID = "sessionId"
        case cwd
        case startedAtMilliseconds = "startedAt"
        case procStart
        case peerProtocol
        case peerFeatures
        case kind
        case entrypoint
        case pidDomain
        case messagingSocketPath
        case name
        case nameSource
        case status
        case version
    }

    /// The keys Claude Code itself writes, per the record captured from a live
    /// session in `docs/research/2026-08-29-cross-machine-messaging/findings.md`.
    /// A composed record's key set must be a **subset** of this: that is the
    /// whole of the "no key Claude Code does not define" rule, expressed as
    /// something a test can check.
    ///
    /// Two of these are never composed. `tmux` is forbidden outright (see the
    /// type's doc comment). `bridgeSessionId` identifies a Claude Code session
    /// on Anthropic's own hosted relay; a shadow has none, and claiming one
    /// would name a session that does not exist.
    ///
    /// A live registry also carries `nameSince`, `updatedAt`, `statusUpdatedAt`
    /// and `waitingFor` on records this document's single sample did not
    /// include. They are Claude Code's own and would be legal here; none is
    /// composed, because nothing in the bridge has an honest value for them
    /// yet.
    public static let claudeCodeDefinedKeys: Set<String> = [
        "pid",
        "sessionId",
        "cwd",
        "startedAt",
        "procStart",
        "version",
        "peerProtocol",
        "peerFeatures",
        "kind",
        "entrypoint",
        "pidDomain",
        "tmux",
        "messagingSocketPath",
        "name",
        "nameSource",
        "status",
        "bridgeSessionId",
    ]

    // MARK: - Composition

    /// Compose one shadow's record.
    ///
    /// Everything TBD stamps rather than learns is defaulted, so a call site
    /// states only the facts it actually has: the process, the socket, the
    /// name, and what the far side said about the session.
    ///
    /// - Parameters:
    ///   - pid: the helper's own real pid. Must be the pid the record is filed
    ///     under.
    ///   - procStart: that process's kernel start time, from
    ///     `ProcessStartTime.procStart(pid:)`.
    public init(
        pid: pid_t,
        procStart: String,
        messagingSocketPath: String,
        name: String,
        status: String,
        peerProtocol: Int,
        cwd: String,
        sessionID: String = UUID().uuidString,
        startedAt: Date = Date(),
        version: String? = nil,
        peerFeatures: [String] = ShadowPeerRecord.bridgedPeerFeatures,
        kind: String = ShadowPeerRecord.interactiveKind,
        entrypoint: String = ShadowPeerRecord.cliEntrypoint,
        nameSource: String = ShadowPeerRecord.userNameSource,
        pidDomain: String = ShadowPeerRecord.localPIDDomain
    ) {
        self.pid = pid
        self.procStart = procStart
        self.messagingSocketPath = messagingSocketPath
        self.name = name
        self.status = status
        self.peerProtocol = peerProtocol
        self.cwd = cwd
        self.sessionID = sessionID
        self.startedAtMilliseconds = Self.milliseconds(since: startedAt)
        self.version = version
        self.peerFeatures = peerFeatures
        self.kind = kind
        self.entrypoint = entrypoint
        self.nameSource = nameSource
        self.pidDomain = pidDomain
    }

    /// The same record with a new status, and **every other field unchanged** —
    /// the session id and start time above all. The helper is the single writer
    /// of its record and rewrites it on every status change; a rewrite that
    /// minted a fresh session id would republish the peer under a new identity
    /// each time the far side went from `idle` to `busy`.
    public func withStatus(_ status: String) -> ShadowPeerRecord {
        ShadowPeerRecord(replacing: self, name: name, status: status)
    }

    /// The same record under a new name. Names are the whole identity of a
    /// shadow peer — the pane join that disambiguates local peers is
    /// unavailable — so a worktree renamed on the far side must reach the
    /// record rather than leaving it answering to a name nobody uses.
    public func withName(_ name: String) -> ShadowPeerRecord {
        ShadowPeerRecord(replacing: self, name: name, status: status)
    }

    private init(replacing other: ShadowPeerRecord, name: String, status: String) {
        self.pid = other.pid
        self.sessionID = other.sessionID
        self.cwd = other.cwd
        self.startedAtMilliseconds = other.startedAtMilliseconds
        self.procStart = other.procStart
        self.peerProtocol = other.peerProtocol
        self.peerFeatures = other.peerFeatures
        self.kind = other.kind
        self.entrypoint = other.entrypoint
        self.pidDomain = other.pidDomain
        self.messagingSocketPath = other.messagingSocketPath
        self.name = name
        self.nameSource = other.nameSource
        self.status = status
        self.version = other.version
    }

    private static func milliseconds(since date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Encoded explicitly rather than synthesized, because the key set is the
    /// contract: `version` is written only when there is one
    /// (`encodeIfPresent`), and every other key is unconditional, so an encoded
    /// record's keys are decidable by reading this method.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(startedAtMilliseconds, forKey: .startedAtMilliseconds)
        try c.encode(procStart, forKey: .procStart)
        try c.encode(peerProtocol, forKey: .peerProtocol)
        try c.encode(peerFeatures, forKey: .peerFeatures)
        try c.encode(kind, forKey: .kind)
        try c.encode(entrypoint, forKey: .entrypoint)
        try c.encode(pidDomain, forKey: .pidDomain)
        try c.encode(messagingSocketPath, forKey: .messagingSocketPath)
        try c.encode(name, forKey: .name)
        try c.encode(nameSource, forKey: .nameSource)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(version, forKey: .version)
    }
}

// MARK: - Store

/// Reads, writes and removes shadow peer records in one registry directory.
///
/// The store holds the directory it was given. There is deliberately **no
/// static helper that builds its own path**: a static twin added "for
/// convenience" makes every caller's injected seam decorative, which is exactly
/// how a test suite ends up writing into the developer's real `~/.claude` (root
/// `CLAUDE.md`, "Tests must not touch ~/tbd", and the
/// `ClaudeProfileConfigDirManager.resolveConfigDir` bug recorded there).
/// Resolution happens once, in `init(environment:)`, through
/// `TBDConstants.claudeHostHome(environment:)` — the single resolution point
/// for `TBD_CLAUDE_HOST_HOME`.
public struct ShadowPeerRecordStore: Sendable {
    /// The registry directory: `<host claude store>/sessions` in production.
    public let sessionsDirectory: URL

    public init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    /// Resolves the host registry — `$TBD_CLAUDE_HOST_HOME/sessions`, or
    /// `~/.claude/sessions` — from the given environment.
    ///
    /// The host directory rather than a profile's: TBD makes the registry whole
    /// across profiles by symlinking each profile's `sessions` into this one, so
    /// this is the directory every session on the machine reads.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(sessionsDirectory: TBDConstants.claudeHostHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true))
    }

    /// Permissions Claude Code creates its own `sessions/` directory with,
    /// field-measured; matched so a directory TBD creates first is
    /// indistinguishable from one Claude Code created.
    static let directoryPermissions = 0o700
    /// Permissions for a record. The directory is already `0700`, so this is
    /// defence in depth rather than a load-bearing difference.
    static let recordPermissions = 0o600

    /// A record's path. The loader parses the pid out of this filename and
    /// rejects one that does not round-trip as an integer, so the name is the
    /// bare pid and nothing else.
    public func recordURL(pid: pid_t) -> URL {
        sessionsDirectory.appendingPathComponent("\(pid).json")
    }

    /// Write `record` durably: a fresh temporary in the **same directory**,
    /// flushed, then `rename(2)` over the target.
    ///
    /// The rename is what makes the helper a safe single writer. Every session
    /// on the machine reads this directory continuously, so a reader that
    /// caught a partial write would see a record that decodes to nothing — and
    /// the failure would look like the far side going away rather than like a
    /// torn file. With the rename, a reader sees either the previous record or
    /// the complete new one.
    public func write(_ record: ShadowPeerRecord) throws {
        let destination = recordURL(pid: record.pid)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: sessionsDirectory.path) {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions])
        }

        let temporary = temporaryURL(for: destination)
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: Self.recordPermissions]
            ) else {
                throw ShadowPeerRecordStoreError.temporaryFileUncreatable(path: temporary.path)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()  // the bytes, before the name points at them
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw ShadowPeerRecordStoreError.renameFailed(
                path: destination.path, errno: code)
        }
    }

    /// Read a record back. Nil when there is none; throws when there is one
    /// that will not decode.
    public func read(pid: pid_t) throws -> ShadowPeerRecord? {
        let url = recordURL(pid: pid)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ShadowPeerRecord.self, from: data)
        } catch {
            throw ShadowPeerRecordStoreError.malformed(
                path: url.path, detail: error.localizedDescription)
        }
    }

    /// Unlink a record. An absent record is success, not an error: the helper
    /// unlinks on the way out of several paths and must not care which one got
    /// there first.
    public func remove(pid: pid_t) throws {
        let url = recordURL(pid: pid)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The write-temp for one save. Its directory is the target's directory:
    /// `rename(2)` is atomic only within a filesystem, and a temp under `/tmp`
    /// can land on another volume, where the "rename" degrades into a copy that
    /// a crash can tear in half.
    ///
    /// The leading dot keeps it out of a glob, and the name is deliberately not
    /// `<int>.json`: a temp the registry loader would parse as a pid-named
    /// record would list a second, half-written peer for the instant it exists.
    func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            Self.temporaryFileName(forRecordNamed: destination.lastPathComponent,
                                   token: UUID().uuidString))
    }

    // MARK: - The write-temp's name, and who reclaims one

    /// The naming rule for a write-temp, in exactly one place.
    ///
    /// Two things depend on it and they are in different modules: `write`
    /// creates these files, and `ShadowPeerReconciler` reclaims the ones a
    /// death mid-write stranded. A temp is created on **every** record rewrite
    /// — a shadow's status changes for its whole life — and is removed only on
    /// `write`'s throwing paths, so a daemon killed between the `synchronize`
    /// and the `rename(2)` leaves one behind that nothing else on the machine
    /// will ever collect: the leading dot keeps it out of every glob, and the
    /// registry loader reads `<int>.json` and nothing else.
    ///
    /// Composed rather than parsed, and recognised by the same two affixes, so
    /// the creating and reclaiming sides cannot drift apart silently.
    static func temporaryFileName(forRecordNamed recordFileName: String, token: String) -> String {
        "\(temporaryPrefix)\(recordFileName).\(token)\(temporarySuffix)"
    }

    private static let temporaryPrefix = "."
    private static let temporarySuffix = ".tmp"

    /// Whether `fileName` is one of this store's write-temps for the record
    /// file `recordFileName`.
    ///
    /// Deliberately narrow: it matches only the temps of one *named* record, so
    /// a caller can never turn it into "every dotfile ending in `.tmp`" — the
    /// registry directory is shared with every Claude Code session on the
    /// machine, and reclaiming by shape there is the inference the design
    /// forbids.
    public static func isTemporaryFileName(
        _ fileName: String, forRecordNamed recordFileName: String
    ) -> Bool {
        let prefix = "\(temporaryPrefix)\(recordFileName)."
        return fileName.count > prefix.count + temporarySuffix.count
            && fileName.hasPrefix(prefix)
            && fileName.hasSuffix(temporarySuffix)
    }

    /// Every write-temp for the record at `recordPath` that is on disk now, in
    /// a stable order.
    ///
    /// The directory comes from the caller's own path and is never resolved
    /// from the environment here — the store deliberately has no static helper
    /// that builds its own registry path (see the type's doc comment), and this
    /// is not one.
    public static func temporaryFiles(forRecordAt recordPath: String) -> [URL] {
        let record = URL(fileURLWithPath: recordPath)
        let directory = record.deletingLastPathComponent()
        let recordFileName = record.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names
            .filter { isTemporaryFileName($0, forRecordNamed: recordFileName) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
}

/// Failures writing or reading a shadow peer's record.
public enum ShadowPeerRecordStoreError: LocalizedError, Equatable, Sendable {
    case temporaryFileUncreatable(path: String)
    case renameFailed(path: String, errno: Int32)
    case malformed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .temporaryFileUncreatable(let path):
            return "could not create the shadow peer record write-temp at \(path)"
        case .renameFailed(let path, let code):
            return "could not rename the shadow peer record into place at \(path): \(String(cString: strerror(code)))"
        case .malformed(let path, let detail):
            return "shadow peer record at \(path) did not decode: \(detail)"
        }
    }
}
