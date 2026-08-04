import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Archive bootstrap provenance")
struct ArchiveSafetyClassifierTests {
  /// The bootstrap families are deliberately left untracked rather than
  /// gitignored. Ignored paths never reach the classifier, so ignoring them
  /// here would let this test pass without the manifest doing any work.
  @Test func exactBootstrapFamiliesAndTrackedMutationAreArchiveSafe() async throws {
    let fixture = try await makePublishedFixture(name: "exact", withTrackedConfig: true)
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

  /// `.gitignore` is the user's own declaration that these bytes are
  /// reproducible, and it is the only signal Git offers. Folding ignored paths
  /// in would make every worktree that has ever been built permanently
  /// ineligible for archive, which trains users onto `--force` and bypasses
  /// the unpublished-commit check this classifier exists to enforce.
  @Test func ignoredFileDoesNotBlockArchive() async throws {
    let fixture = try await makePublishedFixture(name: "ignored")
    defer { fixture.cleanup() }

    try write("cache/\n", to: fixture.worktree.appendingPathComponent(".gitignore"))
    try await shell(
      "git add .gitignore && git commit -m ignore-cache && git push",
      at: fixture.worktree
    )
    try write(
      "reproducible build output",
      to: fixture.worktree.appendingPathComponent("cache/notes.txt")
    )

    let report = await classify(fixture)

    #expect(report.isEligible)
    #expect(report.findings.isEmpty)
  }

  /// The boundary is `.gitignore`, not the path family. Bootstrap scaffolding
  /// is untracked by convention rather than ignored, so it still arrives as
  /// `??` and stays subject to the full provenance check.
  @Test func untrackedFileUnderAnIgnoredSiblingStillBlocks() async throws {
    let fixture = try await makePublishedFixture(name: "ignored-sibling")
    defer { fixture.cleanup() }

    try write("cache/\n", to: fixture.worktree.appendingPathComponent(".gitignore"))
    try await shell(
      "git add .gitignore && git commit -m ignore-cache && git push",
      at: fixture.worktree
    )
    try write(
      "reproducible build output",
      to: fixture.worktree.appendingPathComponent("cache/notes.txt")
    )
    try write(
      "unique unpublished bytes",
      to: fixture.worktree.appendingPathComponent(".agents/skills/demo/SKILL.md")
    )

    let report = await classify(fixture)

    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.map(\.path) == [".agents/skills/demo/SKILL.md"])
  }

  @Test func blockingSummaryTruncatesLargePathSets() {
    let findings = (0..<250).map {
      ArchiveArtifactFinding(
        path: String(format: "src/file-%03d.txt", $0),
        category: .uniqueUnpublishedWork,
        reason: "no matching trusted out-of-worktree bootstrap attestation"
      )
    }

    let summary = ArchiveSafetyReport(findings: findings, headIsPublished: true).blockingSummary

    #expect(summary.contains("src/file-000.txt"))
    #expect(summary.contains("and 230 more"))
    #expect(!summary.contains("src/file-249.txt"))
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

  /// Drives force all the way through physical removal on a worktree the
  /// classifier refuses. Asserting only against `beginArchiveWorktree` would
  /// prove nothing — that phase is read-only and mutates nothing whether force
  /// is set or not, so it passes even if force stopped bypassing the gate.
  @Test func explicitForceRemovesAWorktreeTheClassifierWouldBlock() async throws {
    let fixture = try await makePublishedFixture(name: "force")
    defer { fixture.cleanup() }
    try write("unique", to: fixture.worktree.appendingPathComponent("unique.txt"))

    // Precondition: without force, this exact worktree is refused.
    let blocked = await classify(fixture)
    #expect(!blocked.isEligible)
    #expect(blocked.uniqueUnpublishedWork.map(\.path) == ["unique.txt"])

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

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id, force: true)
    try await lifecycle.completeArchiveWorktree(
      worktree: pair.0, repo: pair.1, force: true
    )

    #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived)
    #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  /// The same fixture without force must refuse and leave everything in place,
  /// so the test above attributes removal to force rather than to the fixture.
  @Test func withoutForceTheSameWorktreeIsRefusedAndUntouched() async throws {
    let fixture = try await makePublishedFixture(name: "noforce")
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
      name: "noforce",
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

    await #expect(throws: WorktreeLifecycleError.self) {
      _ = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id)
    }

    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  /// The refusal has to carry its own way out — the app's Archive action never
  /// forces and exposes no override control, so this message is a GUI user's
  /// only route to the escape hatch. It names the real worktree, because a
  /// literal `<name>` is not a command anyone can run.
  @Test func archiveRefusalNamesTheWorktreeAndTheForceEscapeHatch() {
    let message = WorktreeLifecycleError
      .archiveUnsafe(name: "acme-feature", detail: "unique unpublished work: a.txt")
      .description

    #expect(message.contains("unique unpublished work: a.txt"))
    #expect(message.contains("tbd worktree archive acme-feature --force"))
    #expect(!message.contains("<name>"))
  }

  /// A failing hook is the user's own script breaking, not a safety refusal.
  /// Reporting it as one would send an ordinary scripting bug to `--force`,
  /// the single flag that also skips every content and publication check.
  @Test func hookFailureIsReportedSeparatelyFromASafetyRefusal() {
    let hook = WorktreeLifecycleError
      .archiveHookFailed(name: "acme-feature", detail: "exited 1")
      .description
    let unsafe = WorktreeLifecycleError
      .archiveUnsafe(name: "acme-feature", detail: "unique unpublished work: a.txt")
      .description

    #expect(hook.contains("Archive hook failed"))
    #expect(hook.contains("exited 1"))
    #expect(!hook.contains("Archive blocked"))
    #expect(hook != unsafe)
  }

  @Test func nonzeroArchiveHookBlocksBeforeTerminalTeardown() async throws {
    let fixture = try await makePublishedFixture(name: "hook-failure")
    defer { fixture.cleanup() }
    let hook = fixture.worktree.appendingPathComponent(".worktree-hooks/archive")
    try write("#!/bin/bash\necho preserve-step-failed >&2\nexit 23\n", to: hook)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: hook.path)

    let commands = OrderLog()
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
      path: fixture.repo.path, displayName: "acme", defaultBranch: "main")
    let worktree = try await db.worktrees.create(
      repoID: repo.id, name: "hook-failure", branch: fixture.branch,
      path: fixture.worktree.path, tmuxServer: "tbd-test")
    let terminal = try await db.terminals.create(
      worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
    let lifecycle = WorktreeLifecycle(
      db: db,
      git: GitManager(),
      tmux: TmuxManager(dryRun: true, dryRunRecorder: { args in
        if args.contains("kill-window") { commands.record("kill") }
      }),
      hooks: HookResolver(),
      archiveSafetyEvaluator: { _, _ in
        ArchiveSafetyReport(findings: [], headIsPublished: true)
      },
      worktreeRemover: { _, _ in Issue.record("removal ran after failed hook") }
    )

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id)
    do {
      try await lifecycle.completeArchiveWorktree(worktree: pair.0, repo: pair.1)
      Issue.record("archive unexpectedly succeeded")
    } catch let error as WorktreeLifecycleError {
      #expect(error.description.contains("Archive hook failed"))
      #expect(error.description.contains("preserve-step-failed"))
    }

    #expect(commands.all.isEmpty)
    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(try await db.terminals.get(id: terminal.id) != nil)
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  @Test func regularFileReadRejectsSymlinkedComponents() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-openat-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-openat-outside-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try write("outside", to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("file-link"), withDestinationURL: outside)
    let realDirectory = root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try write("outside", to: realDirectory.appendingPathComponent("artifact"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("directory-link"), withDestinationURL: realDirectory)

    let classifier = ArchiveSafetyClassifier(git: GitManager())
    #expect(classifier.regularFileData(rootPath: root.path, relativePath: "file-link") == nil)
    #expect(classifier.regularFileData(
      rootPath: root.path, relativePath: "directory-link/artifact") == nil)
  }

  @Test func regularFileReadStaysOnOpenedDescriptorDuringPathSwap() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-openat-race-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-openat-race-outside-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let artifact = root.appendingPathComponent("artifact")
    let parked = root.appendingPathComponent("artifact-opened")
    try write("trusted-bytes", to: artifact)
    try write("replacement-bytes", to: outside)

    let data = ArchiveSafetyClassifier(git: GitManager()).regularFileData(
      rootPath: root.path,
      relativePath: "artifact",
      afterOpen: {
        do {
          try FileManager.default.moveItem(at: artifact, to: parked)
          try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: outside)
        } catch {
          Issue.record("could not arrange descriptor race: \(error)")
        }
      }
    )

    #expect(data == Data("trusted-bytes".utf8))
  }

  @Test func regularFileReadStaysOnOpenedDescriptorDuringParentSwap() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-openat-parent-race-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("directory")
    let parked = root.appendingPathComponent("directory-opened")
    let replacement = root.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    try write("trusted-bytes", to: directory.appendingPathComponent("artifact"))
    try write("replacement-bytes", to: replacement.appendingPathComponent("artifact"))

    let data = ArchiveSafetyClassifier(git: GitManager()).regularFileData(
      rootPath: root.path,
      relativePath: "directory/artifact",
      afterOpen: {
        do {
          try FileManager.default.moveItem(at: directory, to: parked)
          try FileManager.default.createSymbolicLink(
            at: directory, withDestinationURL: replacement)
        } catch {
          Issue.record("could not arrange parent descriptor race: \(error)")
        }
      }
    )

    #expect(data == Data("trusted-bytes".utf8))
  }

  /// A repository with no remote configured must still be archivable. Requiring
  /// a remote-tracking branch there refuses every archive forever, which is the
  /// always-refuses failure this design argues against — and `git worktree
  /// remove` keeps the branch, so the commits survive either way.
  @Test func localOnlyRepoWithNoRemoteIsStillEligible() async throws {
    let (temp, repo) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: temp) }
    let worktree = temp.appendingPathComponent("wt-local")
    try await shell("git worktree add -b test/local '\(worktree.path)' main", at: repo)

    let report = await ArchiveSafetyClassifier(git: GitManager())
      .classify(worktreePath: worktree.path)

    #expect(report.headIsPublished)
    #expect(report.isEligible)
  }

  /// The no-remote fallback relaxes only the publication question. Content
  /// still has to be clean, or the gate would be trivially bypassable by
  /// deleting a remote.
  @Test func localOnlyRepoStillBlocksOnDirtyContent() async throws {
    let (temp, repo) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: temp) }
    let worktree = temp.appendingPathComponent("wt-local-dirty")
    try await shell("git worktree add -b test/local-dirty '\(worktree.path)' main", at: repo)
    try write("unique unpublished bytes", to: worktree.appendingPathComponent("notes.txt"))

    let report = await ArchiveSafetyClassifier(git: GitManager())
      .classify(worktreePath: worktree.path)

    #expect(report.headIsPublished)
    #expect(!report.isEligible)
    #expect(report.uniqueUnpublishedWork.map(\.path) == ["notes.txt"])
  }

  /// The common case carries no manifest at all. Naming a missing bootstrap
  /// attestation there describes machinery the user has never encountered.
  @Test func plainDirtyContentGetsAPlainReason() async throws {
    let fixture = try await makePublishedFixture(name: "plain-reason")
    defer { fixture.cleanup() }
    try write("draft", to: fixture.worktree.appendingPathComponent("notes.txt"))

    let report = await classify(fixture)

    #expect(report.uniqueUnpublishedWork.map(\.reason) == ["uncommitted or untracked content"])
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
    let terminal = try await db.terminals.create(
      worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
    let subscriptions = StateSubscriptionManager()
    let deltas = DeltaLog()
    subscriptions.addSubscriber { data in
      if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
        deltas.append(delta)
      }
      return true
    }
    let lifecycle = WorktreeLifecycle(
      db: db, git: GitManager(), tmux: TmuxManager(
        dryRun: true, dryRunCapturePane: { _, _ in "preserved output" }),
      hooks: HookResolver(), subscriptions: subscriptions, archiveSafetyEvaluator: nil,
      worktreeRemover: { _, _ in })

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id, force: true)
    await #expect(throws: WorktreeLifecycleError.self) {
      try await lifecycle.completeArchiveWorktree(
        worktree: pair.0, repo: pair.1, force: true)
    }

    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(try await db.terminals.get(id: terminal.id) == nil)
    #expect(try await db.terminalHistory.list(worktreeID: worktree.id).count == 1)
    #expect(deltas.terminalRemovals == [terminal.id])
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
    let terminal = try await db.terminals.create(
      worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
    let subscriptions = StateSubscriptionManager()
    let deltas = DeltaLog()
    subscriptions.addSubscriber { data in
      if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
        deltas.append(delta)
      }
      return true
    }
    let reports = ArchiveReportSequence()
    let lifecycle = WorktreeLifecycle(
      db: db, git: GitManager(), tmux: TmuxManager(
        dryRun: true, dryRunCapturePane: { _, _ in "preserved output" }),
      hooks: HookResolver(), subscriptions: subscriptions,
      archiveSafetyEvaluator: { _, _ in await reports.next() },
      worktreeRemover: { _, _ in Issue.record("removal ran after failed revalidation") })

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id)
    await #expect(throws: WorktreeLifecycleError.self) {
      try await lifecycle.completeArchiveWorktree(worktree: pair.0, repo: pair.1)
    }

    #expect(await reports.callCount == 2)
    #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
    #expect(try await db.terminals.get(id: terminal.id) == nil)
    #expect(try await db.terminalHistory.list(worktreeID: worktree.id).count == 1)
    #expect(deltas.terminalRemovals == [terminal.id])
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
  }

  /// The worktree's own terminals must be silenced after the archive hook but
  /// before the final revalidation and forced removal. A live agent that outlives
  /// the last check can create a file in the gap before `git worktree remove
  /// --force` runs, and that file is then discarded with nothing having
  /// observed it — the exact loss this classifier exists to prevent.
  @Test func terminalsAreSilencedBeforeRevalidationAndRemoval() async throws {
    let fixture = try await makePublishedFixture(name: "ordering")
    defer { fixture.cleanup() }

    let events = OrderLog()
    let hookMarker = fixture.temp.appendingPathComponent("archive-hook-ran")
    let hook = fixture.worktree.appendingPathComponent(".worktree-hooks/archive")
    try write("#!/bin/bash\ntouch '\(hookMarker.path)'\n", to: hook)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: hook.path)
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
      path: fixture.repo.path, displayName: "acme", defaultBranch: "main")
    let worktree = try await db.worktrees.create(
      repoID: repo.id, name: "ordering", branch: fixture.branch,
      path: fixture.worktree.path, tmuxServer: "tbd-test")
    _ = try await db.terminals.create(
      worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

    let lifecycle = WorktreeLifecycle(
      db: db,
      git: GitManager(),
      tmux: TmuxManager(
        dryRun: true,
        dryRunRecorder: { args in
          if args.contains("kill-window") {
            if FileManager.default.fileExists(atPath: hookMarker.path) {
              events.record("hook")
            }
            events.record("kill")
          }
        }
      ),
      hooks: HookResolver(),
      archiveSafetyEvaluator: { _, _ in
        events.record("classify")
        return ArchiveSafetyReport(findings: [], headIsPublished: true)
      },
      worktreeRemover: { _, path in
        events.record("remove")
        try FileManager.default.removeItem(atPath: path)
      }
    )

    let pair = try await lifecycle.beginArchiveWorktree(worktreeID: worktree.id)
    try await lifecycle.completeArchiveWorktree(worktree: pair.0, repo: pair.1)

    // Phase 1 gates, the hook finishes, the window dies, then revalidation
    // attests a worktree nothing can still be writing to before removal.
    #expect(events.all == ["classify", "hook", "kill", "classify", "remove"])
  }

  // MARK: - Fixtures

  /// Synchronous ordered event log — `dryRunRecorder` is a non-async
  /// `@Sendable` closure, so this cannot be an actor.
  final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) {
      lock.lock()
      defer { lock.unlock() }
      events.append(event)
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return events
    }
  }

  final class DeltaLog: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []
    func append(_ delta: StateDelta) {
      lock.lock()
      defer { lock.unlock() }
      deltas.append(delta)
    }
    var terminalRemovals: [UUID] {
      lock.lock()
      defer { lock.unlock() }
      return deltas.compactMap { delta in
        guard case .terminalRemoved(let removal) = delta else { return nil }
        return removal.terminalID
      }
    }
  }

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
    withTrackedConfig: Bool = false
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
    try await shell("git push -u origin '\(branch)'", at: worktree)
    return Fixture(id: UUID(), temp: temp, repo: repo, worktree: worktree, branch: branch)
  }

  private func writeRuntimeOverlay(at worktree: URL) throws -> [[String: Any]] {
    let pathsAndContents = [
      (".agents/skills/example/SKILL.md", "skill"),
      (".codex/hooks.json", "{\"hooks\":{}}"),
      (".codex/hooks/pre.sh", "#!/bin/sh\n"),
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
