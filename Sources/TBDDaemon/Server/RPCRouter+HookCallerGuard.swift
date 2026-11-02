import Darwin
import Foundation
import os
import TBDShared

private let hookCallerLog = Logger(subsystem: "com.tbd.daemon", category: "hookCaller")

/// The check every hook-only RPC makes before it changes anything: does the
/// process that sent it run inside the tab it names?
///
/// A hook names its tab from `TBD_TERMINAL_ID` or `TBD_WORKTREE_ID`, and both
/// are inherited. A process outside the tab's tree that still carries them —
/// a session hosted by a user-wide daemon one tab happened to start, an agent
/// `nohup`'d from an earlier job — would otherwise drive that tab: rebind its
/// session, clear its dialogs, post its notifications, bind a PR to its
/// worktree. The peer pid cannot be forged (`RPCConnectionContext`), and the
/// `tbd` CLI blocks on the reply, so the peer is alive for the whole check.
///
/// **Only proof refuses.** `HookCallerDescent` answers inside, proven
/// foreign, or can't tell; everything but proven foreign accepts, as every
/// hook was accepted before this check existed. Refusing a real SessionStart
/// would leave the tab on the wrong session, so a picture the daemon cannot
/// see whole — no peer pid, an unreadable table, a tmux or parked row, an
/// ancestry cut short — is never a reason to refuse. That is also why the
/// check fails open where envelope suppression fails closed: suppression
/// grants an elevated action, and a hook event is only an input.
///
/// A refusal is logged at `.info` with the method, the tab or worktree, the
/// peer's pid and executable name, and why. Never the hook's cwd or the
/// caller's argv: checkout paths routinely carry employer and client names.
///
/// Design: `docs/specs/2026-11-01-env-marker-attribution-design.md`, Part 2.
extension RPCRouter {
    /// Whether a hook event naming `terminal` comes from a caller proven to run
    /// outside it. True only for that proof; the handler then replies as it
    /// does for an unknown row and changes nothing.
    func hookCallerRefused(
        method: String, terminal: Terminal, connection: RPCConnectionContext?
    ) async -> Bool {
        let peerPID = connection?.peerPID
        guard let allTerminals = await hookCallerRows(method: method) else { return false }
        let verdict = HookCallerDescent.verdict(
            peerPID: peerPID, terminal: terminal, allTerminals: allTerminals,
            processes: processTableReader())
        return Self.hookCallerVerdictRefuses(
            verdict, method: method, target: "terminal \(terminal.id.uuidString)",
            missed: "the tab's job", peerPID: peerPID)
    }

    /// Whether a hook event naming `worktreeID` comes from a caller proven to
    /// run outside every one of its tabs. `pr.attach` names a worktree, not a
    /// tab, so the caller is inside when it descends from any of the
    /// worktree's rows; proof needs every unparked row to anchor, and a
    /// worktree with none can't tell.
    func hookCallerRefused(
        method: String, worktreeID: UUID, connection: RPCConnectionContext?
    ) async -> Bool {
        let peerPID = connection?.peerPID
        guard let allTerminals = await hookCallerRows(method: method) else { return false }
        let verdict = HookCallerDescent.verdict(
            peerPID: peerPID, worktreeID: worktreeID, allTerminals: allTerminals,
            processes: processTableReader())
        return Self.hookCallerVerdictRefuses(
            verdict, method: method, target: "worktree \(worktreeID.uuidString)",
            missed: "the job of any of its tabs", peerPID: peerPID)
    }

    /// Every terminal row, which the verdict needs to tell a contested job
    /// from an anchoring one. Nil when the read failed: the caller then
    /// accepts, because a row it cannot see is a row it cannot rule out.
    private func hookCallerRows(method: String) async -> [Terminal]? {
        do {
            return try await db.terminals.list()
        } catch {
            hookCallerLog.debug("""
                \(method, privacy: .public): terminal rows unreadable, caller \
                accepted unchecked: \(String(describing: error), privacy: .public)
                """)
            return nil
        }
    }

    /// Logs the verdict and says whether it refuses. `missed` names what a
    /// proven-foreign caller's ancestry did not pass through, for the reason
    /// the refusal line gives.
    private static func hookCallerVerdictRefuses(
        _ verdict: HookCallerVerdict, method: String, target: String, missed: String,
        peerPID: Int32?
    ) -> Bool {
        let pid = peerPID.map { String($0) } ?? "none"
        switch verdict {
        case .inside:
            return false
        case .cannotTell(let uncertainty):
            hookCallerLog.debug("""
                \(method, privacy: .public): cannot tell whether peer pid=\(pid, privacy: .public) \
                runs inside \(target, privacy: .public) (\(uncertainty.rawValue, privacy: .public)); \
                accepted
                """)
            return false
        case .provenForeign:
            let executable = peerPID.map { Self.executableName(pid: $0) } ?? "unknown"
            hookCallerLog.info("""
                \(method, privacy: .public): REFUSED peer pid=\(pid, privacy: .public) \
                (\(executable, privacy: .public)) for \(target, privacy: .public): \
                its whole ancestry reaches launchd without passing through \
                \(missed, privacy: .public); event ignored
                """)
            return true
        }
    }

    /// The executable's short name as the kernel records it (`proc_name`),
    /// for the refusal line. Never the path or the argv, which can carry a
    /// checkout's name.
    private static func executableName(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "unknown" }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? "unknown"
        }
    }
}
