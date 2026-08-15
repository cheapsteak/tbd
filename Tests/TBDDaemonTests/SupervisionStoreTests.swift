import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem, no clocks, no subprocesses.
///
/// Every test injects its own `supervision.json` and `ledger.jsonl` paths
/// rather than touching `TBD_HOME`: the seams exist precisely so this suite
/// never needs the process-global env, which only `TBDHomeSerialized` may
/// mutate.
@Suite("Supervision store")
struct SupervisionStoreTests {

    // MARK: - Fixture

    /// A fleet the store reads through the narrow injected seam. Deliberately
    /// not the database: supervision needs a repo list and a roster, and
    /// nothing about these tests should depend on how session facts are
    /// stored.
    private struct StubFleet: SupervisionFleetReading {
        var repoList: [SupervisionRepo] = []
        var agentList: [SupervisionFleetAgent] = []

        func repos() async throws -> [SupervisionRepo] { repoList }

        func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent] {
            agentList.filter { repoIDs.contains($0.repo) }
        }
    }

    private struct Fixture {
        let directory: URL
        let filePath: String
        let ledgerPath: String
        let dates: TestDateSource
        let store: SupervisionStore
    }

    private static func makeFixture(
        fleet: StubFleet, seed: SupervisionFile? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("supervision.json")
        let files = SupervisionFileStore(fileURL: fileURL)
        if let seed { try files.save(seed) }
        let ledgerPath = directory.appendingPathComponent("ledger.jsonl").path
        let dates = TestDateSource()
        return Fixture(
            directory: directory,
            filePath: fileURL.path,
            ledgerPath: ledgerPath,
            dates: dates,
            store: SupervisionStore(
                files: files,
                ledger: SupervisionLedgerWriter(path: ledgerPath),
                fleet: fleet,
                now: dates.provider))
    }

    /// A second store over the same two files — what a daemon restart is.
    private static func reopen(_ fixture: Fixture, fleet: StubFleet) -> SupervisionStore {
        SupervisionStore(
            files: SupervisionFileStore(fileURL: URL(fileURLWithPath: fixture.filePath)),
            ledger: SupervisionLedgerWriter(path: fixture.ledgerPath),
            fleet: fleet,
            now: fixture.dates.provider)
    }

    /// The supervision file's bytes, or nil when there is no file.
    ///
    /// **Optional on purpose, and compared as an optional.** An absent file is
    /// not a missing baseline — it is the empty state, the one every fresh
    /// install is in, and `SupervisionFileStore.load()` reads it as exactly the
    /// value an empty file would produce. So "unchanged" has to include "there
    /// were no bytes and there still are none"; unwrapping the baseline with
    /// `#require` instead would demand bytes that ought not to exist and fail
    /// before the refusal under test was even attempted. Comparing optionals
    /// keeps the assertion discriminating in both directions: a refusal that
    /// wrote a file moves nil to non-nil and reddens.
    private func fileBytes(_ fixture: Fixture) -> Data? {
        FileManager.default.contents(atPath: fixture.filePath)
    }

    /// Every ledger line, decoded, in order.
    private func lines(at path: String) throws -> [SupervisionLedgerLine] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return try data.split(separator: 0x0A, omittingEmptySubsequences: true).map { raw in
            try JSONDecoder().decode(SupervisionLedgerLine.self, from: Data(raw))
        }
    }

    /// Every ledger line as raw JSON, for the assertions about explicit nulls.
    private func rawLines(at path: String) throws -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return try data.split(separator: 0x0A, omittingEmptySubsequences: true).map { raw in
            try #require(try JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any])
        }
    }

    private static func repo(_ name: String) -> SupervisionRepo {
        SupervisionRepo(id: UUID(), name: name)
    }

    // MARK: - The brake, both branches

    @Test("An engaged brake means nothing is effectively supervised, marks intact")
    func engagedBrakeSuppressesCoverageWithoutClearingMarks() async throws {
        let web = Self.repo("acme-web")
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [web]),
            seed: SupervisionFile(supervised: ["acme-web"]))

        let engaged = try await fixture.store.status(brake: .engaged)
        #expect(engaged.effectivelySupervising == false)
        #expect(engaged.projects.first?.on == true, "the mark survives the brake")

        let released = try await fixture.store.status(brake: .released)
        #expect(released.effectivelySupervising == true)
        #expect(released.projects.first?.on == true)
    }

    @Test("Each brake direction writes one fleet-wide line carrying no project")
    func brakeChangeWritesAFleetWideLine() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))

        await fixture.store.recordBrakeChange(engaged: true, changed: true)
        fixture.dates.advance(by: 60)
        await fixture.store.recordBrakeChange(engaged: false, changed: true)

        let decoded = try lines(at: fixture.ledgerPath)
        #expect(decoded.map(\.payload) == [.brakeEngaged, .brakeReleased])
        #expect(decoded.allSatisfy { $0.project == nil && $0.mode == nil })

        for raw in try rawLines(at: fixture.ledgerPath) {
            #expect(raw["project"] is NSNull, "a fleet-wide line says null, never omits the key")
            #expect(raw["mode"] is NSNull)
        }
    }

    @Test("A brake gesture that changes nothing writes no line")
    func unchangedBrakeWritesNoLine() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))
        await fixture.store.recordBrakeChange(engaged: true, changed: false)
        await fixture.store.recordBrakeChange(engaged: false, changed: false)
        #expect(try lines(at: fixture.ledgerPath).isEmpty)
    }

    // MARK: - The per-project mark, both branches

    @Test("Turning a project on writes an opening line with the roster already present")
    func markOnWritesRosterSnapshot() async throws {
        let web = Self.repo("acme-web")
        let worktree = UUID()
        let terminal = UUID()
        let fleet = StubFleet(
            repoList: [web],
            agentList: [SupervisionFleetAgent(
                worktree: worktree, terminal: terminal, repo: web.id,
                spawnSource: "claude", transcriptPath: "/tmp/transcript.jsonl")])
        let fixture = try Self.makeFixture(fleet: fleet)

        let result = try await fixture.store.setProjectMark(project: "acme-web", on: true)
        #expect(result.changed)
        #expect(result.on)

        let decoded = try lines(at: fixture.ledgerPath)
        #expect(decoded.count == 1)
        let line = try #require(decoded.first)
        #expect(line.project == "acme-web")
        #expect(line.mode == "attended")
        guard case .projectOn(let roster) = line.payload else {
            Issue.record("expected a projectOn payload, got \(line.payload)")
            return
        }
        #expect(roster == [SupervisionRosterEntry(
            worktree: worktree, terminal: terminal, repo: web.id, project: "acme-web",
            spawnSource: "claude", transcriptPath: "/tmp/transcript.jsonl")])
    }

    @Test("Turning a project off closes the span the opening line started")
    func markOffWritesCoverageSummary() async throws {
        let web = Self.repo("acme-web")
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [web]))

        _ = try await fixture.store.setProjectMark(project: "acme-web", on: true)
        let openedAt = fixture.dates.now
        fixture.dates.advance(by: 3600)
        // A counter the delivery slice will feed; the summary must report it
        // rather than a literal.
        await fixture.store.noteSweepContact(project: "acme-web", at: fixture.dates.now)
        let result = try await fixture.store.setProjectMark(project: "acme-web", on: false)
        #expect(result.changed)

        let decoded = try lines(at: fixture.ledgerPath)
        #expect(decoded.count == 2)
        guard case .projectOff(let coverage) = try #require(decoded.last).payload else {
            Issue.record("expected a projectOff payload")
            return
        }
        #expect(coverage.spanStartedAt == SupervisionInstant(openedAt))
        #expect(coverage.durationSeconds == 3600)
        #expect(coverage.sweepContacts == 1)
        #expect(coverage.briefingsDelivered == 0)
    }

    @Test("An unknown project name is refused rather than marked")
    func markingAnUnknownProjectIsRefused() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))
        await #expect(throws: SupervisionStoreError.unknownProject("acme-platform")) {
            _ = try await fixture.store.setProjectMark(project: "acme-platform", on: true)
        }
        #expect(try lines(at: fixture.ledgerPath).isEmpty)
    }

    // MARK: - Idempotence

    @Test("A mark that already stands as asked writes nothing and reports changed: false")
    func idempotentMarkGestures() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))

        // Off when already off — the untouched state.
        let offAgain = try await fixture.store.setProjectMark(project: "acme-web", on: false)
        #expect(offAgain.changed == false)
        #expect(try lines(at: fixture.ledgerPath).isEmpty)

        _ = try await fixture.store.setProjectMark(project: "acme-web", on: true)
        let onAgain = try await fixture.store.setProjectMark(project: "acme-web", on: true)
        #expect(onAgain.changed == false)
        #expect(try lines(at: fixture.ledgerPath).count == 1, "only the first `on` is a decision")
    }

    @Test("Selecting the mode already selected writes nothing; a real change writes one line")
    func idempotentModeGestures() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))

        let same = try await fixture.store.setMode(project: "acme-web", mode: "attended")
        #expect(same.changed == false)
        #expect(same.declaredModes == SupervisionModeEntry.builtInModes)
        #expect(try lines(at: fixture.ledgerPath).isEmpty)

        let changed = try await fixture.store.setMode(project: "acme-web", mode: "autonomous")
        #expect(changed.changed)
        let decoded = try lines(at: fixture.ledgerPath)
        #expect(decoded.count == 1)
        #expect(decoded.first?.payload == .modeChanged(from: "attended", to: "autonomous"))
        #expect(decoded.first?.mode == "autonomous", "the line's mode is the one now in force")
    }

    @Test("A mode outside the declared list is refused, naming the choices")
    func undeclaredModeIsRefused() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))
        await #expect(throws: SupervisionStoreError.modeNotDeclared(
            project: "acme-web", requested: "friday-freeze",
            declared: SupervisionModeEntry.builtInModes)) {
            _ = try await fixture.store.setMode(project: "acme-web", mode: "friday-freeze")
        }
        #expect(try lines(at: fixture.ledgerPath).isEmpty)
    }

    // MARK: - The loud case

    @Test("A released brake with nothing marked on warns, in words and in a code")
    func releasedBrakeWithNoProjectsOnWarns() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))
        let status = try await fixture.store.status(brake: .released)

        #expect(status.effectivelySupervising == false)
        #expect(status.warnings.map(\.code) == [.noProjectsOn])
        #expect(status.warnings.first?.message
            == "the brake is released but no project is on — nothing is being supervised.")
    }

    @Test("A marked project silences the loud line")
    func markedProjectSilencesTheWarning() async throws {
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [Self.repo("acme-web")]),
            seed: SupervisionFile(supervised: ["acme-web"]))
        let status = try await fixture.store.status(brake: .released)
        #expect(status.effectivelySupervising)
        #expect(status.warnings.isEmpty)
    }

    @Test("An engaged brake is not the noProjectsOn warning")
    func engagedBrakeDoesNotWarnAboutProjects() async throws {
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [Self.repo("acme-web")]))
        let status = try await fixture.store.status(brake: .engaged)
        #expect(status.warnings.isEmpty, "a paused fleet is a stated choice, not a quiet failure")
    }

    @Test("A project whose name cannot be a directory warns and is supervised anyway")
    func unusableProjectNameWarns() async throws {
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [Self.repo("acme/web")]),
            seed: SupervisionFile(supervised: ["acme/web"]))
        let status = try await fixture.store.status(brake: .released)

        #expect(status.warnings.map(\.code) == [.unusableProjectName])
        #expect(status.warnings.first?.message.contains("\"acme/web\"") == true,
                "the message names which ones")
        #expect(status.projects.map(\.name) == ["acme/web"])
        #expect(status.projects.first?.on == true)
        #expect(status.effectivelySupervising, "coverage is not withheld over a display name")
    }

    // MARK: - Untouched and turned-off are one state

    @Test("A project never touched and one turned back off are indistinguishable")
    func untouchedAndTurnedOffRenderIdentically() async throws {
        let web = Self.repo("acme-web")
        let untouched = try Self.makeFixture(fleet: StubFleet(repoList: [web]))
        let turnedOff = try Self.makeFixture(fleet: StubFleet(repoList: [web]))
        _ = try await turnedOff.store.setProjectMark(project: "acme-web", on: true)
        _ = try await turnedOff.store.setProjectMark(project: "acme-web", on: false)

        let a = try await untouched.store.status(brake: .released)
        let b = try await turnedOff.store.status(brake: .released)
        #expect(a.projects == b.projects,
                "a third tier would show up here as a leftover span or a differing flag")
        #expect(b.projects.first?.spanStartedAt == nil)
    }

    @Test("A project turned off by hand still renders exactly off, span or no span")
    func handClearedMarkRendersBareOffDespiteAnOpenLine() async throws {
        let web = Self.repo("acme-web")
        let fleet = StubFleet(repoList: [web])
        let fixture = try Self.makeFixture(fleet: fleet)
        _ = try await fixture.store.setProjectMark(project: "acme-web", on: true)

        // The operator clears the mark in the file itself, so the ledger keeps
        // an opening line with no `off` after it. A restart therefore recovers
        // an open span for a project whose mark is gone — the one arrangement
        // where "off" and "has a span" meet.
        try SupervisionFileStore(fileURL: URL(fileURLWithPath: fixture.filePath))
            .save(SupervisionFile())
        let restarted = Self.reopen(fixture, fleet: fleet)
        try await restarted.load()

        let status = try await restarted.status(brake: .released)
        #expect(status.projects.first?.on == false)
        #expect(status.projects.first?.spanStartedAt == nil,
                "an off project renders exactly off — a span here would be a third state")
    }

    // MARK: - Restart

    @Test("A restart resumes the span from the two files and replays no decision")
    func restartRecoversSpanAndWritesNothing() async throws {
        let web = Self.repo("acme-web")
        let fleet = StubFleet(repoList: [web])
        let fixture = try Self.makeFixture(fleet: fleet)
        _ = try await fixture.store.setProjectMark(project: "acme-web", on: true)
        let openedAt = fixture.dates.now
        let afterFirstRun = try lines(at: fixture.ledgerPath)
        #expect(afterFirstRun.count == 1)

        fixture.dates.advance(by: 7200)
        let restarted = Self.reopen(fixture, fleet: fleet)
        try await restarted.load()

        #expect(try lines(at: fixture.ledgerPath).map(\.id) == afterFirstRun.map(\.id),
                "loading writes no line — reading state back is not re-deciding")
        let status = try await restarted.status(brake: .released)
        #expect(status.projects.first?.on == true)
        #expect(status.projects.first?.spanStartedAt == SupervisionInstant(openedAt))
        #expect(status.effectivelySupervising)
    }

    @Test("A span closed before the restart is not resurrected as open")
    func restartDoesNotReopenAClosedSpan() async throws {
        let web = Self.repo("acme-web")
        let fleet = StubFleet(repoList: [web])
        let fixture = try Self.makeFixture(fleet: fleet)
        _ = try await fixture.store.setProjectMark(project: "acme-web", on: true)
        fixture.dates.advance(by: 60)
        _ = try await fixture.store.setProjectMark(project: "acme-web", on: false)

        let restarted = Self.reopen(fixture, fleet: fleet)
        try await restarted.load()
        let status = try await restarted.status(brake: .released)
        #expect(status.projects.first?.on == false)
        #expect(status.projects.first?.spanStartedAt == nil)
    }

    // MARK: - Reload after a hand edit

    @Test("A hand edit between gestures is picked up, not overwritten")
    func handEditIsReloadedBeforeTheNextGesture() async throws {
        let web = Self.repo("acme-web")
        let api = Self.repo("acme-api")
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [web, api]))
        _ = try await fixture.store.projectList()  // populate the in-memory copy

        // The operator edits the file directly — the whole surface beyond the
        // CLI, by design.
        let edited = SupervisionFile(
            projects: ["acme-platform": SupervisionProjectDeclaration(
                repos: [web.id, api.id], policy: .repo(web.id))])
        try SupervisionFileStore(fileURL: URL(fileURLWithPath: fixture.filePath)).save(edited)

        let listed = try await fixture.store.projectList()
        #expect(listed.projects.map(\.name) == ["acme-platform"])

        // And the next write preserves the edit rather than rewriting it away.
        _ = try await fixture.store.setProjectMark(project: "acme-platform", on: true)
        let onDisk = try SupervisionFileStore(
            fileURL: URL(fileURLWithPath: fixture.filePath)).load()
        #expect(onDisk.projects["acme-platform"]?.repos == [web.id, api.id])
        #expect(onDisk.supervised == ["acme-platform"])
    }

    // MARK: - Projects and moves

    @Test("A declared project and its repos survive a round trip through the file")
    func projectCreateDeclaresAndLists() async throws {
        let web = Self.repo("acme-web")
        let api = Self.repo("acme-api")
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [web, api]))

        let result = try await fixture.store.projectCreate(
            name: "acme-platform", repos: ["acme-web", api.id.uuidString],
            policy: .repo("acme-web"))
        #expect(result.projects.map(\.name) == ["acme-platform"])
        #expect(result.projects.first?.repos.map(\.name) == ["acme-web", "acme-api"])
        #expect(result.projects.first?.policy == .repo(web.id))
    }

    @Test("A display name two repos share is refused, never guessed")
    func ambiguousRepoNameIsRefused() async throws {
        let first = Self.repo("acme-web")
        let second = SupervisionRepo(id: UUID(), name: "acme-web")
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [first, second]))

        await #expect(throws: SupervisionStoreError.ambiguousRepoName(
            "acme-web", repos: [first.id, second.id])) {
            _ = try await fixture.store.projectCreate(
                name: "acme-platform", repos: ["acme-web"], policy: .operator)
        }
    }

    @Test("Moving a project's policy source out is refused and changes nothing")
    func refusedMoveLeavesFileAndMemoryUntouched() async throws {
        let web = Self.repo("acme-web")
        let api = Self.repo("acme-api")
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [web, api]),
            seed: SupervisionFile(projects: ["acme-platform": SupervisionProjectDeclaration(
                repos: [web.id, api.id], policy: .repo(web.id))]))
        let before = fileBytes(fixture)
        let listedBefore = try await fixture.store.projectList()

        await #expect(throws: SupervisionTopologyError.policySourceWouldLeaveProject(
            project: "acme-platform", repo: web.id)) {
            _ = try await fixture.store.projectMove(repo: "acme-web", to: .singleton)
        }

        #expect(fileBytes(fixture) == before, "a refused move leaves the file byte-identical")
        #expect(try await fixture.store.projectList() == listedBefore)
        #expect(try lines(at: fixture.ledgerPath).isEmpty)
    }

    @Test("Moving to a project that does not exist is refused and changes nothing")
    func moveToUnknownProjectLeavesStateUntouched() async throws {
        let web = Self.repo("acme-web")
        let fixture = try Self.makeFixture(fleet: StubFleet(repoList: [web]))
        // Nothing has been declared, so there is no file — and a refused move
        // must leave it that way. `nil == nil` is the assertion, and a store
        // that wrote anything on the way to refusing moves it off nil.
        let before = fileBytes(fixture)
        #expect(before == nil, "the fixture starts from the empty state, which is an absent file")

        await #expect(throws: SupervisionTopologyError.unknownProject(project: "acme-platform")) {
            _ = try await fixture.store.projectMove(repo: "acme-web", to: .project("acme-platform"))
        }
        #expect(fileBytes(fixture) == before)
    }

    @Test("A repo lands in exactly one project across a move, and the emptied one is closed")
    func moveEmptyingAProjectClosesItsSpan() async throws {
        let web = Self.repo("acme-web")
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [web]),
            seed: SupervisionFile(
                projects: ["acme-platform": SupervisionProjectDeclaration(
                    repos: [web.id], policy: .repo(web.id))],
                supervised: ["acme-platform"]))

        let result = try await fixture.store.projectMove(repo: "acme-web", to: .singleton)
        #expect(result.projects.map(\.name) == ["acme-web"], "exactly one project holds the repo")

        let decoded = try lines(at: fixture.ledgerPath)
        #expect(decoded.count == 1)
        #expect(decoded.first?.project == "acme-platform")
        guard case .projectOff = try #require(decoded.first).payload else {
            Issue.record("a vanished project's coverage must be closed on the record")
            return
        }
        let onDisk = try SupervisionFileStore(
            fileURL: URL(fileURLWithPath: fixture.filePath)).load()
        #expect(onDisk.supervised.isEmpty, "a mark must not outlive its project")
    }

    @Test("Deleting a declaration returns its repos to being their own projects")
    func projectDeleteReturnsReposToSingletons() async throws {
        let web = Self.repo("acme-web")
        let api = Self.repo("acme-api")
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [web, api]),
            seed: SupervisionFile(projects: ["acme-platform": SupervisionProjectDeclaration(
                repos: [web.id, api.id], policy: .repo(web.id))]))

        let result = try await fixture.store.projectDelete(name: "acme-platform")
        #expect(result.projects.map(\.name) == ["acme-api", "acme-web"])
    }

    // MARK: - A failed save

    @Test("A save that cannot be written leaves the file and the store unchanged")
    func failedSaveChangesNothing() async throws {
        let web = Self.repo("acme-web")
        let fixture = try Self.makeFixture(
            fleet: StubFleet(repoList: [web]),
            seed: SupervisionFile(supervised: ["acme-web"]))
        _ = try await fixture.store.projectList()
        let before = fileBytes(fixture)

        // Read and traverse but never write: the temp the atomic save needs
        // cannot be created.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        }

        await #expect(throws: (any Error).self) {
            _ = try await fixture.store.setProjectMark(project: "acme-web", on: false)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        #expect(fileBytes(fixture) == before)
        let status = try await fixture.store.status(brake: .released)
        #expect(status.projects.first?.on == true, "the in-memory mark did not move either")
        #expect(try lines(at: fixture.ledgerPath).isEmpty,
                "no line for a decision that never took effect")
    }
}
