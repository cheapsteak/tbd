import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. The form logic and state machine behind the Clone Repository sheet.
/// Everything outside the model is injected: the file system answers from a
/// set, the cloner is `FakeCloner`, and the add is a recorder. No git, no
/// daemon, no real paths are touched.
///
/// **Never a real `RepoCloner` here.** Another suite calls
/// `RepoCloner.terminateAll()`, which signals every clone in this test process.
@MainActor
@Suite("CloneRepositoryModel", .fastPassBounded)
struct CloneRepositoryModelTests {

    private static let home = "/Users/acme"
    private static let remoteURL = "https://example.com/acme/widgets.git"

    // MARK: - Validation

    @Test func localPathShowsLocalFolderMessage() async {
        await withDefaults { defaults in
            let model = makeModel(defaults: defaults, recorder: Recorder())
            for text in ["/Users/acme/widgets", "~/widgets"] {
                model.repositoryText = text
                #expect(model.validationMessage == "This is a local folder. Use Local Folder… instead.")
                #expect(model.canClone == false)
            }
        }
    }

    @Test func emptyTextHasNoMessageAndCannotClone() async {
        await withDefaults { defaults in
            let model = makeModel(defaults: defaults, recorder: Recorder())
            model.repositoryText = "   "
            #expect(model.validationMessage == nil)
            #expect(model.canClone == false)
        }
    }

    @Test func folderNameFollowsRepository() async {
        await withDefaults { defaults in
            let model = makeModel(defaults: defaults, recorder: Recorder())
            model.repositoryText = "acme/widgets"
            #expect(model.folderName == "widgets")

            model.folderName = "w2"
            model.repositoryText = "acme/gadgets"
            #expect(model.folderName == "w2")
        }
    }

    @Test func invalidFolderNamesDisableClone() async {
        await withDefaults { defaults in
            let model = makeModel(defaults: defaults, recorder: Recorder())
            model.repositoryText = Self.remoteURL
            // Positive control: the same form with its filled-in name can clone.
            #expect(model.canClone)
            for name in ["", ".", "..", "a/b"] {
                model.folderName = name
                #expect(model.canClone == false, "folder name \(name) must not be clonable")
            }
        }
    }

    @Test func existingDestinationDisablesClone() async {
        await withDefaults { defaults in
            let disk = FakeDisk()
            let model = makeModel(defaults: defaults, recorder: Recorder(), disk: disk)
            model.repositoryText = Self.remoteURL
            #expect(model.canClone)

            disk.existing.insert(model.destinationPath)
            #expect(model.canClone == false)
        }
    }

    // MARK: - The parent folder

    @Test func missingRememberedParentFallsBackToHome() async {
        await withDefaults { defaults in
            defaults.set("/gone", forKey: CloneRepositoryModel.parentDirectoryKey)
            let missing = makeModel(defaults: defaults, recorder: Recorder())
            #expect(missing.parentDirectory == Self.home)

            defaults.set("/Users/acme/code", forKey: CloneRepositoryModel.parentDirectoryKey)
            let disk = FakeDisk()
            disk.existing.insert("/Users/acme/code")
            let remembered = makeModel(defaults: defaults, recorder: Recorder(), disk: disk)
            #expect(remembered.parentDirectory == "/Users/acme/code")
        }
    }

    @Test func startRemembersParent() async {
        await withDefaults { defaults in
            let model = makeModel(defaults: defaults, recorder: Recorder())
            model.repositoryText = Self.remoteURL
            model.parentDirectory = "/Users/acme/code"
            await model.start()
            #expect(defaults.string(forKey: CloneRepositoryModel.parentDirectoryKey) == "/Users/acme/code")
        }
    }

    // MARK: - Outcomes

    @Test func successAddsAndFinishes() async {
        await withDefaults { defaults in
            let recorder = Recorder()
            let model = makeModel(defaults: defaults, recorder: recorder)
            model.repositoryText = Self.remoteURL
            #expect(model.destinationPath == "/Users/acme/widgets")
            await model.start()
            #expect(recorder.clonedURLs == [Self.remoteURL])
            #expect(recorder.destinations == ["/Users/acme/widgets"])
            #expect(recorder.addedPaths == ["/Users/acme/widgets"])
            #expect(model.phase == .done)
        }
    }

    @Test func shortFormUsesResolvedURL() async {
        await withDefaults { defaults in
            let recorder = Recorder()
            let model = makeModel(defaults: defaults, recorder: recorder,
                                  resolvedURL: "git@github.com:acme/widgets.git")
            model.repositoryText = "acme/widgets"
            await model.start()
            #expect(recorder.resolved == ["acme/widgets"])
            #expect(recorder.clonedURLs == ["git@github.com:acme/widgets.git"])
        }
    }

    @Test func gitFailureShowsLinesAndHint() async {
        await withDefaults { defaults in
            let recorder = Recorder()
            let cloner = FakeCloner(outcome: .failed(exitCode: 128, lastErrorLines: ["fatal: nope"]))
            let model = makeModel(defaults: defaults, cloner: cloner, recorder: recorder)
            model.repositoryText = Self.remoteURL
            await model.start()
            guard case .failed(let message) = model.phase else {
                Issue.record("expected .failed, got \(model.phase)")
                return
            }
            #expect(message.contains("fatal: nope"))
            #expect(message.contains(CloneRepositoryModel.failureHint))
            #expect(recorder.addedPaths.isEmpty)
        }
    }

    @Test func failureHintIsTheSpecCopy() {
        #expect(CloneRepositoryModel.failureHint
            == "Private repo? Make sure git can log in: run `gh auth setup-git` for HTTPS URLs, "
            + "or set up an SSH key for SSH URLs.")
    }

    @Test func addFailureKeepsClone() async {
        await withDefaults { defaults in
            let model = makeModel(defaults: defaults, recorder: Recorder(), addError: BoomError())
            model.repositoryText = Self.remoteURL
            await model.start()
            #expect(model.phase == .addFailed(
                message: "Cloned into \(model.destinationPath), but TBD could not add it: boom. "
                    + "Use Local Folder… to add it."))
        }
    }

    // MARK: - Cancelling

    @Test func dismissCancelsRunningClone() async {
        await withDefaults { defaults in
            let cloner = FakeCloner(holdsUntilCancelled: true)
            let recorder = Recorder()
            let model = makeModel(defaults: defaults, cloner: cloner, recorder: recorder)
            model.repositoryText = Self.remoteURL
            let run = Task { await model.start() }
            await cloner.waitUntilRunning()
            #expect(model.isCloning)

            model.cancel()
            await run.value
            #expect(cloner.cancelCount == 1)
            #expect(model.phase == .editing)
            #expect(recorder.addedPaths.isEmpty)
        }
    }

    @Test func cancelOutsideACloneDoesNothing() async {
        await withDefaults { defaults in
            let cloner = FakeCloner()
            let model = makeModel(defaults: defaults, cloner: cloner, recorder: Recorder())
            model.repositoryText = Self.remoteURL
            model.cancel()
            await model.start()
            #expect(model.phase == .done)
            // `.done` is the state the sheet is in when it closes, and closing
            // calls `cancel()`; that must not reach a cloner that has finished.
            model.cancel()
            #expect(cloner.cancelCount == 0)
            #expect(model.phase == .done)
        }
    }

    @Test func progressLinesReachThePhase() async {
        await withDefaults { defaults in
            let line = "Receiving objects: 45% (1234/2700)"
            let cloner = FakeCloner(progressLines: [line], holdsUntilCancelled: true)
            let model = makeModel(defaults: defaults, cloner: cloner, recorder: Recorder())
            model.repositoryText = Self.remoteURL
            let run = Task { await model.start() }
            await cloner.waitUntilRunning()

            let shown = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await MainActor.run { model.phase == .cloning(progress: line) }
            }
            #expect(shown == .satisfied, "git's progress line never reached the phase")

            model.cancel()
            await run.value
            #expect(model.phase == .editing)
        }
    }

    // MARK: - Fixtures

    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "TBDAppTests.CloneRepositoryModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    private func makeModel(
        defaults: UserDefaults,
        cloner: FakeCloner = FakeCloner(),
        recorder: Recorder,
        disk: FakeDisk = FakeDisk(),
        resolvedURL: String = "https://github.com/acme/widgets.git",
        addError: (any Error)? = nil
    ) -> CloneRepositoryModel {
        CloneRepositoryModel(
            userDefaults: defaults,
            homeDirectory: Self.home,
            fileExists: { path in disk.existing.contains(path) },
            makeCloner: { url, destination in
                recorder.clonedURLs.append(url)
                recorder.destinations.append(destination)
                return cloner
            },
            resolveShortForm: { owner, repo in
                recorder.resolved.append("\(owner)/\(repo)")
                return resolvedURL
            },
            addRepo: { path in
                recorder.addedPaths.append(path)
                if let addError { throw addError }
            })
    }
}

@MainActor
private final class Recorder {
    var clonedURLs: [String] = []
    var destinations: [String] = []
    var resolved: [String] = []
    var addedPaths: [String] = []
}

/// The paths that exist, as far as the model is told.
@MainActor
private final class FakeDisk {
    var existing: Set<String> = []
}

private struct BoomError: LocalizedError {
    var errorDescription: String? { "boom" }
}

/// Stands in for `RepoCloner` and never spawns git. Reports `progressLines`,
/// then either returns `outcome` at once or, with `holdsUntilCancelled`, waits
/// until `cancel()` and returns `.cancelled` — so a test can act mid-clone.
private final class FakeCloner: RepoCloning, @unchecked Sendable {
    private let outcome: CloneOutcome
    private let progressLines: [String]
    private let holdsUntilCancelled: Bool

    private let lock = NSLock()
    private var cancelCalls = 0
    private var cancelled = false
    private var running = false
    private var runningWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?

    init(outcome: CloneOutcome = .succeeded, progressLines: [String] = [], holdsUntilCancelled: Bool = false) {
        self.outcome = outcome
        self.progressLines = progressLines
        self.holdsUntilCancelled = holdsUntilCancelled
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCalls
    }

    func run(onProgress: @escaping @Sendable (String) -> Void) async -> CloneOutcome {
        for line in progressLines {
            onProgress(line)
        }
        markRunning()?.resume()
        guard holdsUntilCancelled else { return outcome }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parkUntilCancelled(continuation)
        }
        return .cancelled
    }

    func cancel() {
        lock.lock()
        cancelCalls += 1
        cancelled = true
        let waiter = cancelWaiter
        cancelWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    /// Returns once `run` has started.
    func waitUntilRunning() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parkUntilRunning(continuation)
        }
    }

    private func markRunning() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        running = true
        let waiter = runningWaiter
        runningWaiter = nil
        return waiter
    }

    private func parkUntilRunning(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if running {
            lock.unlock()
            continuation.resume()
        } else {
            runningWaiter = continuation
            lock.unlock()
        }
    }

    private func parkUntilCancelled(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume()
        } else {
            cancelWaiter = continuation
            lock.unlock()
        }
    }
}
