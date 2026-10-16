import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// The `OrphanGC` leg that reclaims `~/tbd/repos/<repoID>/checkout-template/`
/// — the template `CheckoutTemplateStore` clones fresh worktrees from — when
/// its repo row is gone, or for every repo while `clone_checkout_enabled` is
/// off.
///
/// Tier 2: a real temp tree, an in-memory database, a fixed clock. The repos
/// root comes through the leg's own seam and every other base the sweep walks
/// is pointed inside the same temp home, so this suite never reads the
/// process-global `TBD_HOME`.
@Suite("OrphanGC reclaims checkout templates")
struct OrphanGCCheckoutTemplateTests: ~Copyable {
    private let fm = FileManager.default
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let home: URL

    init() {
        home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgcct"), isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    private var environment: [String: String] { ["TBD_HOME": home.path] }

    private func makeGC(db: TBDDatabase) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: home.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: home.appendingPathComponent("p", isDirectory: true),
            hangStackBase: home.appendingPathComponent("hs", isDirectory: true),
            processSnapshotProvider: { [] },
            holdersBase: home.appendingPathComponent("h", isDirectory: true),
            modelProxyBase: home.appendingPathComponent("mp", isDirectory: true),
            streamsBase: home.appendingPathComponent("st", isDirectory: true),
            attachmentsBase: home.appendingPathComponent("a", isDirectory: true),
            remoteTranscriptsEnvironment: environment,
            reposBase: TBDConstants.reposDir(environment: environment))
    }

    /// Writes a template with one tracked-looking file at the path
    /// `TBDConstants` gives the repo, and returns the template root.
    private func writeTemplate(repoID: UUID) throws -> String {
        let root = TBDConstants.checkoutTemplateDir(repoID: repoID, environment: environment)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("tracked\n".utf8).write(to: tree.appendingPathComponent("file.txt"))
        try Data("0123456789abcdef0123456789abcdef01234567\n".utf8)
            .write(to: root.appendingPathComponent("commit"))
        return root.path
    }

    private func makeRepo(db: TBDDatabase) async throws -> Repo {
        let path = home.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        return try await db.repos.create(path: path.path, displayName: "acme", defaultBranch: "main")
    }

    /// The last repo removed while the flag stays on: the repo list reads
    /// back empty, and that successful empty read must still reclaim.
    @Test func aTemplateWhoseRepoIsGoneIsReclaimedEvenWithNoReposLeft() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setCloneCheckoutEnabled(true)
        let template = try writeTemplate(repoID: UUID())

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: template) == false, "\(template) survived the sweep")
        #expect(result.planned.contains("REAP checkout-template repo-removed \(template)"))
        #expect(result.reaped >= 1)
    }

    @Test func aTemplateWhoseRepoIsGoneIsReclaimedBesideALiveOne() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setCloneCheckoutEnabled(true)
        let live = try await makeRepo(db: db)
        let kept = try writeTemplate(repoID: live.id)
        let gone = try writeTemplate(repoID: UUID())

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: kept), "the live repo's template was reclaimed with the flag on")
        #expect(fm.fileExists(atPath: gone) == false, "\(gone) survived the sweep")
        #expect(result.planned.contains("REAP checkout-template repo-removed \(gone)"))
        #expect(result.planned.contains { $0.contains(kept) } == false)
    }

    @Test func everyTemplateIsReclaimedWhileTheFlagIsOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setCloneCheckoutEnabled(false)
        let live = try await makeRepo(db: db)
        let template = try writeTemplate(repoID: live.id)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: template) == false, "\(template) survived with the flag off")
        #expect(result.planned.contains("REAP checkout-template clone-checkout-off \(template)"))
    }

    @Test func aDryRunReportsTheReclaimButKeepsTheTemplate() async throws {
        let db = try TBDDatabase(inMemory: true)
        let template = try writeTemplate(repoID: UUID())

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(fm.fileExists(atPath: template), "a dry run removed \(template)")
        #expect(result.planned.contains("REAP checkout-template repo-removed \(template)"))
    }

    @Test func nothingIsReclaimedWithGCDisabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let template = try writeTemplate(repoID: UUID())

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: template), "\(template) was reclaimed with gcEnabled off")
        #expect(result.planned.contains { $0.contains("checkout-template") } == false)
    }

    /// The leg only ever removes the `checkout-template` directory, never the
    /// repo directory around it (which also holds unsent first messages).
    @Test func onlyTheTemplateDirectoryIsRemoved() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repoID = UUID()
        let template = try writeTemplate(repoID: repoID)
        let sibling = TBDConstants.reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("keep-me")
        try Data("x".utf8).write(to: sibling)

        _ = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: template) == false)
        #expect(fm.fileExists(atPath: sibling.path), "the sweep removed a sibling of the template")
    }
}
