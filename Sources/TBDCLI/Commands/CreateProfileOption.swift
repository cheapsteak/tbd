import Foundation
import TBDShared

/// The resolved choice for a create command's `--profile`: the ID the CLI
/// sends, and the name it prints on the `Profile:` line.
struct CreateProfileChoice: Equatable {
    let id: UUID
    let name: String
}

/// `--profile` on `tbd worktree create` and `tbd terminal create`.
///
/// The keyword `caller`, matched without regard to case, means the profile the
/// calling tab runs on. It is checked before any name, so a profile actually
/// named `caller` is reachable only by its UUID. Anything else goes through the
/// shared `resolveProfile` lookup that `swap-profile` and `continue-in-claude`
/// use.
///
/// The CLI resolves the keyword itself and sends the caller row's `profileID`
/// as an ordinary explicit ID, so the RPC carries IDs only and the daemon
/// checks this ID as it checks any other.
enum CreateProfileOption {
    static let callerKeyword = "caller"

    static let callerOutsideTabMessage =
        "--profile caller works only inside a TBD tab. Name a profile, or leave out --profile."

    static let callerWithoutProfileMessage =
        "This tab runs on the machine's own login, not a TBD profile, so --profile caller "
        + "has nothing to copy. Name a profile, or leave out --profile."

    static let callerRunsCodexMessage =
        "This tab runs Codex, which has no profile, so --profile caller has nothing to copy. "
        + "Name a profile, or leave out --profile."

    /// `reference` is the raw --profile value. `caller` (any case) reads the caller's
    /// row via `callerTerminal`; anything else goes through `resolveProfile`.
    ///
    /// `environment` supplies `TBD_WORKTREE_ID` and `TBD_TERMINAL_ID`, and
    /// `callerTerminal` returns that tab's row, or nil when the worktree has no
    /// such tab. Both are parameters so the keyword is testable without a
    /// daemon.
    static func resolve(
        _ reference: String,
        profiles: [ModelProfileWithUsage],
        environment: [String: String],
        callerTerminal: (_ worktreeID: UUID, _ terminalID: UUID) throws -> TBDShared.Terminal?
    ) throws -> CreateProfileChoice {
        guard reference.lowercased() == callerKeyword else {
            let entry = try resolveProfile(named: reference, in: profiles)
            return CreateProfileChoice(id: entry.profile.id, name: entry.profile.name)
        }
        guard let worktreeID = environment["TBD_WORKTREE_ID"].flatMap({ UUID(uuidString: $0) }),
              let terminalID = environment["TBD_TERMINAL_ID"].flatMap({ UUID(uuidString: $0) })
        else {
            throw CLIError.invalidArgument(callerOutsideTabMessage)
        }
        let row = try callerTerminal(worktreeID, terminalID)
        if let row, row.isCodexTerminal {
            throw CLIError.invalidArgument(callerRunsCodexMessage)
        }
        // A nil profile means the tab runs on the machine's own login. The RPC
        // has no way to ask for that explicitly — a nil ID means "use the
        // normal choice" — so "same as me" cannot be honored.
        guard let profileID = row?.profileID else {
            throw CLIError.invalidArgument(callerWithoutProfileMessage)
        }
        // A profile deleted since the caller started is missing from the list.
        // Its ID is sent anyway, and the daemon refuses it as missing.
        let name = profiles.first(where: { $0.profile.id == profileID })?.profile.name
            ?? profileID.uuidString
        return CreateProfileChoice(id: profileID, name: name)
    }

    /// `resolve` against the running daemon: the profiles come from
    /// `modelProfile.list`, and the caller's row from `terminal.list`.
    static func resolve(
        _ reference: String,
        client: SocketClient,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CreateProfileChoice {
        let list = try client.call(
            method: RPCMethod.modelProfileList,
            resultType: ModelProfileListResult.self
        )
        return try resolve(
            reference,
            profiles: list.profiles,
            environment: environment,
            callerTerminal: { worktreeID, terminalID in
                let rows = try client.call(
                    method: RPCMethod.terminalList,
                    params: TerminalListParams(worktreeID: worktreeID),
                    resultType: [TBDShared.Terminal].self
                )
                return rows.first(where: { $0.id == terminalID })
            }
        )
    }
}
