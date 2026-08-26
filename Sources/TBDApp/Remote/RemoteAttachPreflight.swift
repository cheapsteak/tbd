import Foundation
import TBDShared

/// Resolves a remote-session selection to the exact command that will attach
/// to it — or to a named reason it cannot.
///
/// **Exact match on the registry key, or nothing.** The resolution has no
/// expression for a fallback: there is no "closest provider", no match on
/// `describe.name`, no single-registered-provider shortcut. That is
/// deliberate. A caller that quietly attaches to a different backend than the
/// one the user selected produces the worst failure this subsystem has —
/// work done confidently against the wrong control plane — and the cheapest
/// way to make it impossible is to give the code no way to say it.
///
/// It also replaces a silent skip. `RemoteAttachPager` used to `continue`
/// past a selection whose provider it couldn't resolve: no tab, no error, no
/// log line, and a blank pane where the terminal should be. Every branch here
/// ends in something a user can read and act on.
///
/// Pure, with the filesystem behind an injected probe, so every diagnosis is
/// assertable without spawning anything.
enum RemoteAttachPreflight {
    enum Diagnosis: Equatable {
        /// Attachable: spawn `config.argv + ["attach", sessionID]`.
        case ready(RemoteProviderConfig)
        /// No registry entry by that name. A renamed or removed entry, or a
        /// mirror row that outlived the registration it came from.
        case providerNotRegistered(provider: String)
        /// The session id exists — under a different registry entry. Names
        /// both, because this is the failure a user is most likely to be
        /// misreading as "attach is broken".
        case sessionBelongsToAnotherProvider(requested: String, actual: String, sessionID: String)
        /// The provider does not declare the `attach` capability.
        case attachUnsupported(provider: String)
        /// The registry entry's executable isn't there — the missing
        /// local-transport-dependency case.
        case executableMissing(provider: String, command: String)
        /// It is there and is not executable by this user.
        case executableNotRunnable(provider: String, command: String)

        /// The provider config to spawn, or nil for every diagnosis that
        /// isn't `.ready`.
        var readyConfig: RemoteProviderConfig? {
            if case .ready(let config) = self { return config }
            return nil
        }

        var title: String {
            switch self {
            case .ready: return "Ready to attach"
            case .providerNotRegistered: return "Provider not registered"
            case .sessionBelongsToAnotherProvider: return "Session belongs to another provider"
            case .attachUnsupported: return "Attach not supported"
            case .executableMissing: return "Attach command not found"
            case .executableNotRunnable: return "Attach command not executable"
            }
        }

        /// One actionable sentence. Every one names the provider, because the
        /// motivating confusion is precisely not knowing which provider a
        /// surface is talking about.
        var detail: String {
            switch self {
            case .ready(let config):
                return "Attaching through \(config.name)."
            case .providerNotRegistered(let provider):
                return "No provider named \"\(provider)\" is registered in "
                    + "~/tbd/agent-providers.json. TBD will not attach through a different "
                    + "provider on its behalf. Re-register it under that exact name, or dismiss "
                    + "the session."
            case .sessionBelongsToAnotherProvider(let requested, let actual, let sessionID):
                return "Session \"\(sessionID)\" is reported by \"\(actual)\", not \"\(requested)\". "
                    + "Open it under \(actual); TBD will not attach to another provider's session."
            case .attachUnsupported(let provider):
                return "\"\(provider)\" does not declare the attach capability, so TBD never "
                    + "invokes its attach verb. Use the log view, or send input, if those are "
                    + "declared."
            case .executableMissing(let provider, let command):
                return "\"\(provider)\" is registered to run \(command), which does not exist on "
                    + "this machine. Install the provider (or its transport helper), or correct "
                    + "the exec path in ~/tbd/agent-providers.json."
            case .executableNotRunnable(let provider, let command):
                return "\"\(provider)\" is registered to run \(command), which exists but is not "
                    + "executable by this user. Fix its permissions (chmod +x) and try again."
            }
        }
    }

    /// Whether the registry entry's executable can be run, and if not, why.
    enum ExecutableStatus: Equatable {
        case runnable
        case missing
        case notExecutable
    }

    /// Resolves `selection` against the registry and the mirror.
    ///
    /// `sessions` is used for ONE thing: to tell "no such provider" apart
    /// from "that session lives somewhere else". It never contributes a
    /// provider to attach through.
    static func resolve(
        selection: RemoteSessionSelection,
        providers: [RemoteProviderStatus],
        sessions: [RemoteSessionInfo],
        probe: (RemoteProviderConfig) -> ExecutableStatus = { RemoteAttachPreflight.probeExecutable($0.exec) }
    ) -> Diagnosis {
        guard let provider = providers.first(where: { $0.config.name == selection.provider }) else {
            // Say the more useful of the two things: if some OTHER registered
            // provider reports this session id, the user is one click from
            // the session they wanted.
            if let owner = sessions.first(where: {
                $0.payload.id == selection.sessionID && $0.provider != selection.provider
            }) {
                return .sessionBelongsToAnotherProvider(
                    requested: selection.provider, actual: owner.provider,
                    sessionID: selection.sessionID)
            }
            return .providerNotRegistered(provider: selection.provider)
        }

        // The session id is not in this provider's mirror, but is in
        // another's. Registered-and-healthy is no excuse to attach: the
        // provider would be asked for an id it never reported.
        let mineHasSession = sessions.contains {
            $0.provider == selection.provider && $0.payload.id == selection.sessionID
        }
        if !mineHasSession,
           let owner = sessions.first(where: {
               $0.payload.id == selection.sessionID && $0.provider != selection.provider
           }) {
            return .sessionBelongsToAnotherProvider(
                requested: selection.provider, actual: owner.provider,
                sessionID: selection.sessionID)
        }

        guard provider.describe?.capabilities.contains("attach") == true else {
            return .attachUnsupported(provider: provider.config.name)
        }

        let command = RemoteProviderIdentityPresentation.commandLine(provider.config)
        switch probe(provider.config) {
        case .missing:
            return .executableMissing(provider: provider.config.name, command: command)
        case .notExecutable:
            return .executableNotRunnable(provider: provider.config.name, command: command)
        case .runnable:
            return .ready(provider.config)
        }
    }

    /// The default filesystem probe.
    ///
    /// A registry `exec` may be an absolute or relative path, or a bare
    /// command name the login shell resolves on `PATH` — the contract only
    /// says TBD execs it. Both are checked the way the spawn itself will
    /// resolve them, so this never reports missing for a provider that would
    /// in fact have run.
    static func probeExecutable(
        _ exec: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ExecutableStatus {
        guard !exec.isEmpty else { return .missing }
        if exec.contains("/") {
            return probePath(exec, fileManager: fileManager)
        }
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var sawFile = false
        for directory in searchPath where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(exec)
            switch probePath(candidate, fileManager: fileManager) {
            case .runnable: return .runnable
            case .notExecutable: sawFile = true
            case .missing: continue
            }
        }
        // A name found on PATH but never executable is a permissions problem;
        // a name found nowhere is an installation problem.
        return sawFile ? .notExecutable : .missing
    }

    private static func probePath(_ path: String, fileManager: FileManager) -> ExecutableStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing
        }
        return fileManager.isExecutableFile(atPath: path) ? .runnable : .notExecutable
    }
}
