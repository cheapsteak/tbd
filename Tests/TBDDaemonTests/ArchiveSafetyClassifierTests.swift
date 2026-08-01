import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Archive bootstrap provenance")
struct ArchiveSafetyClassifierTests {
  @Test func exactBootstrapFamiliesAndTrackedMutationAreArchiveSafe() async throws {
    let fixture = try await makePublishedFixture(
      name: "exact", withTrackedConfig: true, ignoresBootstrapPaths: true
    )
    defer { fixture.cleanup() }

    let artifacts = try writeRuntimeOverlay(at: fixture.worktree)
    let manifest = try writeManifest(artifacts: artifacts, at: fixture.worktree)

    let report = await classify(fixture, trustedManifest: manifest)

    #expect(report.isEligible)
    #expect(report.runtimeResidue.count == artifacts.count + 1)  // manifest metadata
    #expect(report.reviewableGeneratedOutput.isEmpty)
    #expect(report.uniqueUnpublishedWork.isEmpty)
  }

  @Test func modifiedRuntimeArtifactBecomesUniqueWork() async throws {
    let fixture = try await makePublishedFixture(name: "drift")
    defer { fixture.cleanup() }

    let agents = fixture.worktree.appendingPathComponent("AGENTS.md")
    try write("generated", to: agents)
    let manifest = try writeManifest(
      artifacts: [try artifact(path: "AGENTS.md", kind: "runtime", file: agents)],
      at: fixture.worktree
    )
    try write("generated plus user edit", to: agents)

    let report = await classify(fixture, trustedManifest: manifest)

    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.map(\.path) == ["AGENTS.md"])
  }

  @Test func unlistedInfrastructureFileRemainsUniqueWork() async throws {
    let fixture = try await makePublishedFixture(name: "extra")
    defer { fixture.cleanup() }

    let agents = fixture.worktree.appendingPathComponent("AGENTS.md")
    try write("generated", to: agents)
    let manifest = try writeManifest(
      artifacts: [try artifact(path: "AGENTS.md", kind: "runtime", file: agents)],
      at: fixture.worktree
    )
    try write(
      "resource \"example\" \"unique\" {}",
      to: fixture.worktree.appendingPathComponent("infrastructure/agent-box.tf")
    )

    let report = await classify(fixture, trustedManifest: manifest)

    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.map(\.path) == ["infrastructure/agent-box.tf"])
  }

  @Test func ignoredUnlistedFileRemainsUniqueWork() async throws {
    let fixture = try await makePublishedFixture(name: "ignored")
    defer { fixture.cleanup() }

    try write("cache/\n", to: fixture.worktree.appendingPathComponent(".gitignore"))
    try await shell(
      "git add .gitignore && git commit -m ignore-cache && git push",
      at: fixture.worktree
    )
    let agents = fixture.worktree.appendingPathComponent("AGENTS.md")
    try write("generated", to: agents)
    let manifest = try writeManifest(
      artifacts: [try artifact(path: "AGENTS.md", kind: "runtime", file: agents)],
      at: fixture.worktree
    )
    try write(
      "unique ignored bytes",
      to: fixture.worktree.appendingPathComponent("cache/notes.txt")
    )

    let report = await classify(fixture, trustedManifest: manifest)

    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.map(\.path) == ["cache/notes.txt"])
  }

  @Test func generatedOutputStaysReviewable() async throws {
    let fixture = try await makePublishedFixture(name: "generated")
    defer { fixture.cleanup() }

    let index = fixture.worktree.appendingPathComponent("generated/index.json")
    try write("{\"entries\":[]}", to: index)
    let manifest = try writeManifest(
      artifacts: [try artifact(path: "generated/index.json", kind: "generatedOutput", file: index)],
      at: fixture.worktree
    )

    let report = await classify(fixture, trustedManifest: manifest)

    #expect(!report.isEligible)
    #expect(report.reviewableGeneratedOutput.map(\.path) == ["generated/index.json"])
    #expect(report.uniqueUnpublishedWork.isEmpty)
  }

  @Test func unknownProvenanceFailsClosed() async throws {
    let fixture = try await makePublishedFixture(name: "unknown")
    defer { fixture.cleanup() }

    let agents = fixture.worktree.appendingPathComponent("AGENTS.md")
    try write("generated", to: agents)
    try writeManifest(
      artifacts: [try artifact(path: "AGENTS.md", kind: "runtime", file: agents)],
      at: fixture.worktree,
      producer: "unknown-producer"
    )

    let report = await ArchiveSafetyClassifier(git: GitManager()).classify(
      worktreePath: fixture.worktree.path
    )

    #expect(!report.isEligible)
    #expect(
      Set(report.uniqueUnpublishedWork.map(\.path))
        == Set([
          ".codex/bootstrap-provenance.json", "AGENTS.md",
        ])
    )
  }

  @Test func advisoryManifestCannotBlessItself() async throws {
    let fixture = try await makePublishedFixture(name: "advisory")
    defer { fixture.cleanup() }
    let agents = fixture.worktree.appendingPathComponent("AGENTS.md")
    try write("generated", to: agents)
    _ = try writeManifest(
      artifacts: [try artifact(path: "AGENTS.md", kind: "runtime", file: agents)],
      at: fixture.worktree
    )

    let report = await classify(fixture)

    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.count == 2)
  }

  @Test func stagedTrackedMutationIsNotBootstrapResidue() async throws {
    let fixture = try await makePublishedFixture(name: "staged", withTrackedConfig: true)
    defer { fixture.cleanup() }
    let artifacts = try writeRuntimeOverlay(at: fixture.worktree)
    let manifest = try writeManifest(artifacts: artifacts, at: fixture.worktree)
    try await shell("git add .codex/config.toml", at: fixture.worktree)

    let report = await classify(fixture, trustedManifest: manifest)

    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.map(\.path).contains(".codex/config.toml"))
  }

  @Test func unpublishedCommitBlocksOtherwiseCleanWorktree() async throws {
    let fixture = try await makePublishedFixture(name: "unpublished")
    defer { fixture.cleanup() }

    try write("not pushed", to: fixture.worktree.appendingPathComponent("local.txt"))
    try await shell("git add local.txt && git commit -m local-only", at: fixture.worktree)

    let report = await ArchiveSafetyClassifier(git: GitManager()).classify(
      worktreePath: fixture.worktree.path
    )

    #expect(!report.isEligible)
    #expect(!report.headIsPublished)
    #expect(report.findings.isEmpty)
  }

  @Test func blockedArchivePreservesDatabaseTerminalsAndDirtyFiles() async throws {
    let fixture = try await makePublishedFixture(name: "preserve")
    defer { fixture.cleanup() }
    try write("unique", to: fixture.worktree.appendingPathComponent("customer-notes.md"))

    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
      path: fixture.repo.path,
      displayName: "acme",
      defaultBranch: "main"
    )
    let worktree = try await db.worktrees.create(
      repoID: repo.id,
      name: "preserve",
      branch: fixture.branch,
      path: fixture.worktree.path,
      tmuxServer: "tbd-test"
    )
    let terminal = try await db.terminals.create(
      worktreeID: worktree.id,
      tmuxWindowID: "@1",
      tmuxPaneID: "%1",
      label: "Codex",
      kind: .codex
    )
    let lifecycle = WorktreeLifecycle(
      db: db,
      git: GitManager(),
      tmux: TmuxManager(dryRun: true),
      hooks: HookResolver()
    )

    await #expect(throws: WorktreeLifecycleError.self) {
      _ = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id)
    }

    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(try await db.terminals.get(id: terminal.id) != nil)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.worktree.appendingPathComponent("customer-notes.md").path
      ))
  }

  @Test func explicitForceRetainsItsArchiveOverride() async throws {
    let fixture = try await makePublishedFixture(name: "force")
    defer { fixture.cleanup() }
    try write("unique", to: fixture.worktree.appendingPathComponent("unique.txt"))

    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
      path: fixture.repo.path,
      displayName: "acme",
      defaultBranch: "main"
    )
    let worktree = try await db.worktrees.create(
      repoID: repo.id,
      name: "force",
      branch: fixture.branch,
      path: fixture.worktree.path,
      tmuxServer: "tbd-test"
    )
    let lifecycle = WorktreeLifecycle(
      db: db,
      git: GitManager(),
      tmux: TmuxManager(dryRun: true),
      hooks: HookResolver()
    )

    _ = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id, force: true)

    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  @Test func removalFailureNeverPublishesArchivedState() async throws {
    let fixture = try await makePublishedFixture(name: "remove-failure")
    defer { fixture.cleanup() }
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
      path: fixture.repo.path, displayName: "acme", defaultBranch: "main")
    let worktree = try await db.worktrees.create(
      repoID: repo.id, name: "remove-failure", branch: fixture.branch,
      path: fixture.worktree.path, tmuxServer: "tbd-test")
    let lifecycle = WorktreeLifecycle(
      db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
      hooks: HookResolver(), archiveSafetyEvaluator: nil,
      worktreeRemover: { _, _ in })

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id, force: true)
    await #expect(throws: WorktreeLifecycleError.self) {
      try await lifecycle.completeArchiveWorktree(
        worktree: pair.0, repo: pair.1, force: true)
    }

    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  @Test func archiveRevalidatesAfterHookBeforeRemoval() async throws {
    let fixture = try await makePublishedFixture(name: "revalidate")
    defer { fixture.cleanup() }
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
      path: fixture.repo.path, displayName: "acme", defaultBranch: "main")
    let worktree = try await db.worktrees.create(
      repoID: repo.id, name: "revalidate", branch: fixture.branch,
      path: fixture.worktree.path, tmuxServer: "tbd-test")
    let reports = ArchiveReportSequence()
    let lifecycle = WorktreeLifecycle(
      db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
      hooks: HookResolver(),
      archiveSafetyEvaluator: { _, _ in await reports.next() },
      worktreeRemover: { _, _ in Issue.record("removal ran after failed revalidation") })

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id)
    await #expect(throws: WorktreeLifecycleError.self) {
      try await lifecycle.completeArchiveWorktree(worktree: pair.0, repo: pair.1)
    }

    #expect(await reports.callCount == 2)
    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  // MARK: - Fixtures

  private struct Fixture {
    let id: UUID
    let temp: URL
    let repo: URL
    let worktree: URL
    let branch: String

    func cleanup() {
      try? FileManager.default.removeItem(at: temp)
    }
  }

  private func makePublishedFixture(
    name: String,
    withTrackedConfig: Bool = false,
    ignoresBootstrapPaths: Bool = false
  ) async throws -> Fixture {
    let (temp, repo) = try await createTestRepoResolvingSymlinks()
    let remote = temp.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try await shell("git init --bare -b main", at: remote)
    try await shell("git remote add origin '\(remote.path)' && git push -u origin main", at: repo)

    let branch = "test/\(name)"
    let worktree = temp.appendingPathComponent("wt-\(name)")
    try await shell("git worktree add -b '\(branch)' '\(worktree.path)' main", at: repo)

    if withTrackedConfig {
      try write(
        "[features]\nlegacy = false\n", to: worktree.appendingPathComponent(".codex/config.toml"))
      try await shell(
        "git add .codex/config.toml && git commit -m tracked-config",
        at: worktree
      )
    }
    if ignoresBootstrapPaths {
      try write(
        ".agents/\n.Codex/\nhooks/\nAGENTS.md\n",
        to: worktree.appendingPathComponent(".gitignore")
      )
      try await shell("git add .gitignore && git commit -m ignore-bootstrap", at: worktree)
    }
    try await shell("git push -u origin '\(branch)'", at: worktree)
    return Fixture(id: UUID(), temp: temp, repo: repo, worktree: worktree, branch: branch)
  }

  private func writeRuntimeOverlay(at worktree: URL) throws -> [[String: Any]] {
    let pathsAndContents = [
      (".agents/skills/example/SKILL.md", "skill"),
      (".codex/hooks.json", "{\"hooks\":{}}"),
      (".Codex/hooks/pre.sh", "#!/bin/sh\n"),
      ("hooks/pre.sh", "#!/bin/sh\n"),
      ("AGENTS.md", "generated instructions"),
    ]
    var artifacts = try pathsAndContents.map { path, contents in
      let url = worktree.appendingPathComponent(path)
      try write(contents, to: url)
      return try artifact(path: path, kind: "runtime", file: url)
    }

    let config = worktree.appendingPathComponent(".codex/config.toml")
    let base = try Data(contentsOf: config)
    try write("[features]\nlegacy = false\ninjected = true\n", to: config)
    var tracked = try artifact(path: ".codex/config.toml", kind: "trackedMutation", file: config)
    tracked["baseSha256"] = ArchiveSafetyClassifier.sha256(base)
    artifacts.append(tracked)
    return artifacts
  }

  private func artifact(path: String, kind: String, file: URL) throws -> [String: Any] {
    [
      "path": path,
      "kind": kind,
      "sha256": ArchiveSafetyClassifier.sha256(try Data(contentsOf: file)),
    ]
  }

  private func writeManifest(
    artifacts: [[String: Any]],
    at worktree: URL,
    producer: String = "agent-bootstrap"
  ) throws -> Data {
    let body: [String: Any] = [
      "schemaVersion": 1,
      "producer": producer,
      "producerVersion": "test-v1",
      "artifacts": artifacts,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
    let path = worktree.appendingPathComponent(ArchiveSafetyClassifier.manifestRelativePath)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: path, options: .atomic)
    return data
  }

  private func classify(
    _ fixture: Fixture,
    trustedManifest: Data? = nil
  ) async -> ArchiveSafetyReport {
    let git = GitManager()
    let attestation: TrustedBootstrapAttestation?
    if let trustedManifest,
      let head = try? await git.headSHA(worktreePath: fixture.worktree.path)
    {
      attestation = TrustedBootstrapAttestation(
        worktreeID: fixture.id,
        headSHA: head,
        producerVersion: "test-v1",
        manifestData: trustedManifest
      )
    } else {
      attestation = nil
    }
    return await ArchiveSafetyClassifier(git: git).classify(
      worktreeID: fixture.id,
      worktreePath: fixture.worktree.path,
      trustedAttestation: attestation
    )
  }

  private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}

private actor ArchiveReportSequence {
  private(set) var callCount = 0

  func next() -> ArchiveSafetyReport {
    callCount += 1
    if callCount == 1 {
      return ArchiveSafetyReport(findings: [], headIsPublished: true)
    }
    return ArchiveSafetyReport(
      findings: [
        ArchiveArtifactFinding(
          path: "hook-output.txt",
          category: .uniqueUnpublishedWork,
          reason: "hook created unique work"
        )
      ],
      headIsPublished: true
    )
  }
}
