import Foundation
import Observation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "cloneRepository")

/// The form logic and state machine behind `CloneRepositorySheet`.
///
/// It lives outside the view so its rules — what the repository text means,
/// when the folder name follows it, when Clone is allowed, and what each clone
/// outcome shows — can be tested without a SwiftUI host. Everything that
/// touches the outside world is injected: the file system check, the cloner,
/// the GitHub short-form lookup and the `repo.add` call.
@MainActor
@Observable
final class CloneRepositoryModel {
    enum Phase: Equatable {
        case editing
        /// `progress` is git's most recent progress line, empty until git
        /// reports one.
        case cloning(progress: String)
        /// git failed; the message is git's last error lines and `failureHint`.
        case failed(message: String)
        /// The clone worked but `repo.add` did not. The clone is kept.
        case addFailed(message: String)
        case done
    }

    /// The last parent folder a clone went into. A per-person convenience that
    /// nobody else reads, so it lives in `UserDefaults`.
    static let parentDirectoryKey = "cloneRepositoryParentDirectory"

    /// Shown under every git failure. The same text whatever the cause: TBD
    /// does not try to read the cause out of git's output.
    static let failureHint =
        "Private repo? Make sure git can log in: run `gh auth setup-git` for HTTPS URLs, "
        + "or set up an SSH key for SSH URLs."

    static let localFolderMessage = "This is a local folder. Use Local Folder… instead."

    static let destinationExistsMessage = "Something already exists at this destination."

    /// A URL or `owner/repo`. Each change refills `folderName` from the parsed
    /// source, until the person edits the folder name themselves.
    var repositoryText: String = "" {
        didSet {
            guard repositoryText != oldValue, !folderNameEdited else { return }
            fillingFolderName = true
            folderName = parsedSource.cloneFolderName ?? ""
            fillingFolderName = false
        }
    }

    var parentDirectory: String

    var folderName: String = "" {
        didSet {
            guard !fillingFolderName, folderName != oldValue else { return }
            // Clearing the field hands it back to the repository text.
            folderNameEdited = !folderName.isEmpty
        }
    }

    private(set) var phase: Phase = .editing

    @ObservationIgnored private var folderNameEdited = false
    @ObservationIgnored private var fillingFolderName = false

    /// The clone in flight, so `cancel()` can reach it.
    @ObservationIgnored private var activeCloner: (any RepoCloning)?
    /// Set by `cancel()` during a clone, for the window before the cloner
    /// exists (while a short form is being resolved).
    @ObservationIgnored private var cancelRequested = false
    /// Tags progress lines with the `start()` that asked for them, so a line
    /// that reaches the main actor late never lands on a later run.
    @ObservationIgnored private var runID = 0

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let fileExists: @MainActor (String) -> Bool
    @ObservationIgnored private let makeCloner: @MainActor (_ url: String, _ destination: String) -> any RepoCloning
    @ObservationIgnored private let resolveShortForm: @MainActor (_ owner: String, _ repo: String) async -> String
    @ObservationIgnored private let addRepo: @MainActor (_ path: String) async throws -> Void

    init(userDefaults: UserDefaults, homeDirectory: String,
         fileExists: @escaping @MainActor (String) -> Bool,
         makeCloner: @escaping @MainActor (_ url: String, _ destination: String) -> any RepoCloning,
         resolveShortForm: @escaping @MainActor (_ owner: String, _ repo: String) async -> String,
         addRepo: @escaping @MainActor (_ path: String) async throws -> Void) {
        self.userDefaults = userDefaults
        self.fileExists = fileExists
        self.makeCloner = makeCloner
        self.resolveShortForm = resolveShortForm
        self.addRepo = addRepo
        // A remembered folder that has since gone falls back to home rather
        // than offering a destination whose parent does not exist.
        if let remembered = userDefaults.string(forKey: Self.parentDirectoryKey), fileExists(remembered) {
            parentDirectory = remembered
        } else {
            parentDirectory = homeDirectory
        }
    }

    // MARK: - Form state

    /// The app has no working folder, so nothing it is given is ever a local
    /// path; text that looks like one is pointed at Local Folder… instead.
    private var parsedSource: RepoSource {
        RepoSource.parse(repositoryText, pathExists: { _ in false })
    }

    private var trimmedText: String {
        repositoryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var looksLikeLocalPath: Bool {
        trimmedText.hasPrefix("/") || trimmedText.hasPrefix("~")
    }

    /// Why the repository text cannot be cloned; nil when it can, or when the
    /// field is empty.
    var validationMessage: String? {
        if trimmedText.isEmpty { return nil }
        if looksLikeLocalPath { return Self.localFolderMessage }
        if case .invalid(let reason) = parsedSource { return reason }
        return nil
    }

    /// Where the clone goes: the parent folder plus the folder name.
    var destinationPath: String {
        parentDirectory.hasSuffix("/") ? parentDirectory + folderName : parentDirectory + "/" + folderName
    }

    var destinationExists: Bool {
        Self.isValidFolderName(folderName) && fileExists(destinationPath)
    }

    var isCloning: Bool {
        if case .cloning = phase { return true }
        return false
    }

    var canClone: Bool {
        guard !isCloning, cloneSource != nil, Self.isValidFolderName(folderName) else { return false }
        return !fileExists(destinationPath)
    }

    /// The failure text the sheet shows, if the last attempt failed.
    var failureMessage: String? {
        switch phase {
        case .failed(let message), .addFailed(let message): return message
        case .editing, .cloning, .done: return nil
        }
    }

    /// The parsed text when it names something to clone, else nil.
    private var cloneSource: RepoSource? {
        guard !trimmedText.isEmpty, !looksLikeLocalPath else { return nil }
        switch parsedSource {
        case .remote, .githubShortForm: return parsedSource
        case .local, .invalid: return nil
        }
    }

    private static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// `url` fit for a persisted log line. A `scheme://` URL loses everything
    /// up to the last `@` of its authority — the user and password, which can
    /// carry an access token. An scp-like `user@host:path` has no password
    /// field and passes through unchanged.
    nonisolated static func loggableURL(_ url: String) -> String {
        guard let scheme = url.range(of: "://") else { return url }
        let authority = url[scheme.upperBound...].prefix { $0 != "/" }
        guard let at = authority.lastIndex(of: "@") else { return url }
        return String(url[..<scheme.upperBound]) + String(url[url.index(after: at)...])
    }

    // MARK: - Cloning

    /// Remembers the parent folder, clones, and adds the clone to TBD.
    func start() async {
        guard canClone, let source = cloneSource else { return }
        let destination = destinationPath
        userDefaults.set(parentDirectory, forKey: Self.parentDirectoryKey)
        runID += 1
        let thisRun = runID
        cancelRequested = false
        phase = .cloning(progress: "")

        let url: String
        switch source {
        case .remote(let remoteURL, _):
            url = remoteURL
        case .githubShortForm(let owner, let repo):
            url = await resolveShortForm(owner, repo)
        case .local, .invalid:
            phase = .editing
            return
        }
        if cancelRequested {
            phase = .editing
            return
        }

        let cloner = makeCloner(url, destination)
        activeCloner = cloner
        let outcome = await cloner.run { line in
            // git's progress arrives on the cloner's reader thread.
            Task { @MainActor in
                self.showProgress(line, runID: thisRun)
            }
        }
        activeCloner = nil

        switch outcome {
        case .succeeded:
            do {
                try await addRepo(destination)
                phase = .done
            } catch {
                logger.error("repo.add failed after clone into \(destination, privacy: .public): \(error, privacy: .public)")
                phase = .addFailed(message: "Cloned into \(destination), but TBD could not add it: "
                    + "\(error.localizedDescription). Use Local Folder… to add it.")
            }
        case .failed(let exitCode, let lastErrorLines):
            let loggedURL = Self.loggableURL(url)
            logger.error("git clone exited \(exitCode, privacy: .public) for \(loggedURL, privacy: .public)")
            let gitText = lastErrorLines.isEmpty
                ? "git clone failed with exit status \(exitCode)."
                : lastErrorLines.joined(separator: "\n")
            phase = .failed(message: gitText + "\n\n" + Self.failureHint)
        case .cancelled:
            phase = .editing
        case .refusedDestinationExists:
            phase = .failed(message: Self.destinationExistsMessage)
        }
    }

    /// Stops a running clone. The cloner removes the partial folder, and the
    /// phase returns to `.editing` once the clone has stopped. Does nothing
    /// outside a clone — closing the sheet after a clone finished calls this
    /// too.
    func cancel() {
        guard isCloning else { return }
        cancelRequested = true
        activeCloner?.cancel()
    }

    private func showProgress(_ line: String, runID: Int) {
        guard runID == self.runID, isCloning else { return }
        phase = .cloning(progress: line)
    }
}
