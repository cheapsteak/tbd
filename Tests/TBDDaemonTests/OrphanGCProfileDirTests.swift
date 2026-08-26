import Foundation
import GRDB
import Security
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Records every path-keyed Claude credentials delete the sweep requests, so a
/// test can assert the item keyed on the *original* config dir path is cleaned
/// up — the one the quarantine rename just made unreachable. Never touches the
/// real login keychain.
private final class RecordingKeychain: ClaudeCredentialsKeychainDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedServices: [String] = []
    /// Status returned to the caller; `errSecItemNotFound` is the "nothing to
    /// clean" leg, which the sweep must also treat as success.
    let status: OSStatus

    init(status: OSStatus = errSecSuccess) {
        self.status = status
    }

    var services: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedServices
    }

    func deleteGenericPassword(service: String) -> OSStatus {
        lock.lock()
        storedServices.append(service)
        lock.unlock()
        return status
    }
}

/// Tier 2: real filesystem plus an in-memory database, no `~/tbd` and no real
/// keychain. The profiles base, the scratchpad base, the clock and the keychain
/// are all injected; nothing here resolves a production path.
@Suite("OrphanGC reclaims orphaned profile dirs")
struct OrphanGCProfileDirTests: ~Copyable {
    let fm = FileManager.default
    /// Sandbox root for this test instance; everything lives under it.
    let sandbox: URL
    /// Injected profiles base (`OrphanGC(profileDirBase:)`).
    let profileBase: URL
    /// Injected scratchpad base, so the sweep's scratchpad phase can never
    /// reach the developer's real Claude store.
    let scratchpadBase: URL
    /// Fixed sweep clock, far enough past every fixture's creation date that
    /// the one-hour grace window has elapsed without backdating anything.
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-profile-dir-\(UUID().uuidString)", isDirectory: true)
        profileBase = sandbox.appendingPathComponent("profiles", isDirectory: true)
        scratchpadBase = sandbox.appendingPathComponent("scratchpads", isDirectory: true)
        try? fm.createDirectory(at: profileBase, withIntermediateDirectories: true)
        try? fm.createDirectory(at: scratchpadBase, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    // MARK: - Fixtures

    private func makeGC(
        db: TBDDatabase,
        keychain: any ClaudeCredentialsKeychainDeleting,
        beforeProfileDirReap: (@Sendable () async -> Void)? = nil
    ) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: scratchpadBase,
            now: { fixed },
            beforeInterruptedArchiveReap: nil,
            profileDirBase: profileBase,
            credentialsKeychain: keychain,
            beforeProfileDirReap: beforeProfileDirReap,
            // Injected empty rather than defaulted. `sweep(dryRun: true)`
            // reaches the orphan-process phase regardless of
            // `gcOrphanProcessesEnabled`, and the default provider is the real
            // `/bin/ps -axww` over every process on the machine — a subprocess
            // this suite has no business spawning (`Tests/CLAUDE.md`: prefer the
            // injection seam). Behaviour-preserving: `liveCWDsProvider` is empty
            // too, so every pid's cwd is unreadable and the phase already plans
            // nothing.
            processSnapshotProvider: { [] }
        )
    }

    /// A profile config dir named for `id`, with a `claude/` subdirectory —
    /// the shape `ClaudeProfileConfigDirManager` creates, and the path the
    /// keychain item is keyed on.
    @discardableResult
    private func makeProfileDir(_ id: UUID) throws -> URL {
        let url = profileBase.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(
            at: url.appendingPathComponent("claude", isDirectory: true),
            withIntermediateDirectories: true)
        return url
    }

    private var quarantineBase: URL {
        profileBase.appendingPathComponent(
            ProfileDirCollector.quarantineDirName, isDirectory: true)
    }

    /// A quarantine entry stamped `age` before the sweep clock.
    @discardableResult
    private func makeQuarantineEntry(age: TimeInterval) throws -> URL {
        let stamp = ProfileDirCollector.stamp(clock.addingTimeInterval(-age))
        let url = quarantineBase.appendingPathComponent(
            "\(UUID().uuidString.lowercased())-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Inserts a `model_profiles` row with a caller-chosen id, which
    /// `ModelProfileStore.create` cannot do (it mints its own UUID) — and the
    /// id has to match the directory name for any of these gates to engage.
    private func insertProfileRow(id: UUID, db: TBDDatabase) async throws {
        let profile = ModelProfile(id: id, name: "acme-\(id.uuidString.prefix(8))", kind: .oauth)
        try await db.modelProfiles.writer.write { db in
            try ModelProfileRecord(from: profile).insert(db)
        }
    }

    private func expectedKeychainService(forProfileDir path: String) -> String {
        ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path + "/claude")
    }

    // MARK: - Flag gates

    @Test("the profile-dir flag ships off: a real sweep leaves an aged orphan untouched")
    func flagOffIsNoOp() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let dir = try makeProfileDir(UUID())
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(fm.fileExists(atPath: dir.path))
        #expect(!result.planned.contains { $0.hasPrefix("REAP profile-dir ") })
        #expect(!result.planned.contains { $0.contains(dir.path) })
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    @Test("with the flag off a dry run still plans what enabling it would reclaim")
    func flagOffDryRunStillPlans() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let dir = try makeProfileDir(UUID())
        let expired = try makeQuarantineEntry(age: 40 * 86_400)
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep(dryRun: true)

        // The whole point of the bypass: a user deciding whether to flip a
        // default-off flag can preview exactly what it would reclaim.
        #expect(result.planned.contains("REAP profile-dir \(dir.path)"))
        #expect(result.planned.contains("PURGE quarantine \(expired.path)"))
        #expect(result.reaped == 0)
        #expect(fm.fileExists(atPath: dir.path))
        #expect(fm.fileExists(atPath: expired.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    @Test("gcEnabled off keeps everything even with the profile-dir flag on")
    func masterSwitchStillGoverns() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        try await db.config.setGCProfileDirsEnabled(true)
        let dir = try makeProfileDir(UUID())
        // The master switch stops quarantine expiry too — it is the one gate
        // that governs the whole sweep, unlike the classifier flag.
        let expired = try makeQuarantineEntry(age: 40 * 86_400)
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(result.planned == ["gc disabled"])
        #expect(fm.fileExists(atPath: dir.path))
        #expect(fm.fileExists(atPath: expired.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    // MARK: - Reaping

    @Test("flag on: an aged orphan is quarantined, recorded, and its keychain item deleted")
    func flagOnQuarantines() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let id = UUID()
        let dir = try makeProfileDir(id)
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(result.planned.contains("REAP profile-dir \(dir.path)"))
        #expect(result.reaped == 1)
        #expect(!fm.fileExists(atPath: dir.path))

        let records = try await db.reapRecords.list(repoPath: nil)
        let record = try #require(records.first { $0.kind == .profileDir })
        #expect(record.worktreePath == dir.path)
        let quarantine = try #require(record.quarantinePath)
        #expect(fm.fileExists(atPath: quarantine))
        #expect(quarantine.hasPrefix(quarantineBase.path + "/"))
        #expect(fm.fileExists(atPath: quarantine + "/claude"), "the directory moved, not deleted")

        // Keyed on the ORIGINAL config dir path — the rename invalidated it.
        #expect(keychain.services == [expectedKeychainService(forProfileDir: dir.path)])
    }

    @Test("errSecItemNotFound from the keychain is success, not a refusal to reap")
    func missingKeychainItemStillReaps() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let dir = try makeProfileDir(UUID())
        let keychain = RecordingKeychain(status: errSecItemNotFound)

        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(result.planned.contains("REAP profile-dir \(dir.path)"))
        #expect(!fm.fileExists(atPath: dir.path))
        #expect(try await db.reapRecords.list(repoPath: nil).count == 1)
    }

    // MARK: - Keep gates

    @Test("a dir whose profile row exists is kept")
    func keepsLiveProfile() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let id = UUID()
        try await insertProfileRow(id: id, db: db)
        let dir = try makeProfileDir(id)
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(result.planned.contains("KEEP row-exists \(dir.path)"))
        #expect(!result.planned.contains("REAP profile-dir \(dir.path)"))
        #expect(fm.fileExists(atPath: dir.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    @Test("a dir referenced by a terminal row is kept even with no profile row")
    func keepsTerminalReferenced() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let id = UUID()
        let dir = try makeProfileDir(id)

        let repoPath = sandbox.appendingPathComponent("acme", isDirectory: true)
        try fm.createDirectory(at: repoPath, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: repoPath.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "wt",
            path: repoPath.appendingPathComponent("wt").path, tmuxServer: "tbd-test")
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", profileID: id)

        let keychain = RecordingKeychain()
        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(result.planned.contains("KEEP terminal-reference \(dir.path)"))
        #expect(!result.planned.contains("REAP profile-dir \(dir.path)"))
        #expect(fm.fileExists(atPath: dir.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    @Test("a row that appears after the candidate listing keeps its directory")
    func keepsRowThatAppearedMidSweep() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let id = UUID()
        let dir = try makeProfileDir(id)
        let keychain = RecordingKeychain()

        // Lands in the window between the candidate/row snapshot and the reap
        // — the exact staleness the pre-reap re-read closes.
        let gc = makeGC(db: db, keychain: keychain, beforeProfileDirReap: {
            try? await db.modelProfiles.writer.write { db in
                try ModelProfileRecord(
                    from: ModelProfile(id: id, name: "acme-recreated", kind: .oauth)
                ).insert(db)
            }
        })
        let result = await gc.sweep()

        #expect(result.planned.contains("KEEP row-appeared \(dir.path)"))
        #expect(result.reaped == 0)
        #expect(fm.fileExists(atPath: dir.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    // MARK: - Dry run

    @Test("dry run plans without touching disk, the DB or the keychain")
    func dryRunPlansOnly() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let dir = try makeProfileDir(UUID())
        let expired = try makeQuarantineEntry(age: 40 * 86_400)
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep(dryRun: true)

        #expect(result.planned.contains("REAP profile-dir \(dir.path)"))
        #expect(result.planned.contains("PURGE quarantine \(expired.path)"))
        #expect(result.reaped == 0)
        #expect(fm.fileExists(atPath: dir.path))
        #expect(fm.fileExists(atPath: expired.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    // MARK: - Quarantine expiry

    @Test("expired quarantine entries are purged; unexpired ones survive")
    func purgesExpiredQuarantine() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let expired = try makeQuarantineEntry(age: 40 * 86_400)
        let fresh = try makeQuarantineEntry(age: 1 * 86_400)
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep()

        #expect(result.planned.contains("PURGE quarantine \(expired.path)"))
        #expect(!result.planned.contains("PURGE quarantine \(fresh.path)"))
        #expect(!fm.fileExists(atPath: expired.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    @Test("quarantine expiry is not gated by the classifier flag")
    func flagOffStillPurgesExpiredQuarantine() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let expired = try makeQuarantineEntry(age: 40 * 86_400)
        let fresh = try makeQuarantineEntry(age: 1 * 86_400)
        // An orphan the classifier would reap if it were on — it must stay put,
        // proving the flag still gates classification and only classification.
        let orphan = try makeProfileDir(UUID())
        let keychain = RecordingKeychain()

        let result = await makeGC(db: db, keychain: keychain).sweep()

        // Purging `.reaped/` is cleanup of GC's own artifacts, not a
        // classification of a user resource: an operator who ends a soak by
        // turning the flag off must not strand credentials in quarantine past
        // the retention window.
        #expect(result.planned.contains("PURGE quarantine \(expired.path)"))
        #expect(!fm.fileExists(atPath: expired.path))
        #expect(fm.fileExists(atPath: fresh.path))

        #expect(!result.planned.contains { $0.hasPrefix("REAP profile-dir ") })
        #expect(fm.fileExists(atPath: orphan.path))
        #expect(try await db.reapRecords.list(repoPath: nil).isEmpty)
        #expect(keychain.services.isEmpty)
    }

    // MARK: - Pre-reap re-read failures

    @Test("a throwing pre-reap re-read keeps the directory")
    func preReapReadFailureKeepsDirectory() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCProfileDirsEnabled(true)
        let dir = try makeProfileDir(UUID())
        let keychain = RecordingKeychain()

        // Close the connection inside the pre-reap window, so the re-read
        // *throws* rather than returning nil. No production error-injection
        // seam: the store genuinely has no connection left, which is the same
        // shape a real read failure takes.
        let gc = makeGC(db: db, keychain: keychain, beforeProfileDirReap: {
            try? db.writerForTests.close()
        })
        let result = await gc.sweep()

        #expect(result.planned.contains("KEEP row-read-failed \(dir.path)"))
        #expect(result.reaped == 0)
        #expect(fm.fileExists(atPath: dir.path))
        #expect(fm.fileExists(atPath: dir.path + "/claude"))
        // Nothing was moved aside, and the path-keyed credentials item — which
        // only the rename makes unreachable — was left alone.
        let quarantined = (try? fm.contentsOfDirectory(atPath: quarantineBase.path)) ?? []
        #expect(quarantined.isEmpty)
        #expect(keychain.services.isEmpty)
    }
}
