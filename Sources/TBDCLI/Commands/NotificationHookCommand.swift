import ArgumentParser
import Foundation
import os
import TBDShared

private let notificationLogger = Logger(subsystem: "com.tbd.cli", category: "hookNotification")

/// `tbd hooks notification` — bridges Claude Code's `Notification` hook into
/// TBD.
///
/// A dumb reporter, on purpose. It lifts the fields it can name, carries the
/// whole payload verbatim, and forwards everything to the daemon: it matches
/// nothing, classifies nothing, and drops nothing on the strength of a field's
/// value. Every fork lives in the daemon's RPC handler, which is compiled and
/// the same for every install — unlike this command's invocation, which sits in
/// a settings file an operator can edit.
///
/// Every failure path is silent and exits 0. Claude Code surfaces a hook's
/// stderr to the user, and a `Notification` hook cannot block or change
/// anything anyway, so noise here would be pure cost.
struct NotificationHookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Internal: bridge Claude Code's Notification hook into TBD",
        shouldDisplay: false
    )

    mutating func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        switch NotificationHookPlan.make(
            stdin: stdin,
            environment: ProcessInfo.processInfo.environment
        ) {
        case .suppressed(let reason):
            notificationLogger.debug("suppressed reason=\(reason.rawValue, privacy: .public)")
        case .forward(let params):
            let client = SocketClient()
            guard client.isDaemonRunning else {
                notificationLogger.debug("suppressed reason=daemonDown")
                return
            }
            do {
                try client.callVoid(method: RPCMethod.terminalNotificationEvent, params: params)
            } catch {
                notificationLogger.debug(
                    "suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Pure core (testable)

/// What the command will do with one hook invocation, decided without touching
/// the socket — so every branch is a unit test rather than a live daemon.
enum NotificationHookPlan {
    case suppressed(Suppression)
    case forward(TerminalNotificationEventParams)

    /// Why nothing was sent. Named rather than boolean so the debug log says
    /// which silence this was.
    enum Suppression: String {
        /// No `TBD_TERMINAL_ID` in the environment — the hook is firing for a
        /// session TBD did not spawn, and there is nothing to route to.
        case noTerminalID
        /// Nothing on stdin, or more than the 1 MiB a hook payload can
        /// plausibly be.
        case unusablePayloadSize
        /// stdin was not a JSON object.
        case malformedPayload
    }

    /// Fields this build can name. Everything is optional and anything else is
    /// ignored: Claude Code's payload extensions are additive, and an older
    /// Claude Code sends neither `notification_type` nor `title`.
    private struct HookPayload: Decodable {
        let message: String?
        let title: String?
        let notification_type: String?
        let cwd: String?
    }

    static func make(stdin: Data, environment: [String: String]) -> NotificationHookPlan {
        guard let terminalIDString = environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            return .suppressed(.noTerminalID)
        }
        // The 1 MiB cap limits *processing*, not the read — the caller has
        // already allocated the buffer. It is a defensive guard against a
        // runaway producer, not a protocol limit.
        guard !stdin.isEmpty, stdin.count <= 1 << 20 else {
            return .suppressed(.unusablePayloadSize)
        }
        // Not a JSON object → there is nothing to route and nothing to say.
        // The command still interprets no *value*: it only refuses input it
        // cannot read at all.
        guard let payload = try? JSONDecoder().decode(HookPayload.self, from: stdin) else {
            return .suppressed(.malformedPayload)
        }
        return .forward(TerminalNotificationEventParams(
            terminalID: terminalID,
            notificationType: payload.notification_type,
            // A payload with no message is reported as an empty one rather
            // than dropped: that a notification fired at all is the fact, and
            // guessing text for it would be worse than carrying none.
            message: payload.message ?? "",
            title: payload.title,
            // Verbatim, byte for byte as it arrived — this is what rides into a
            // briefing, and what lets a later consumer read a field this build
            // does not model.
            rawPayload: String(data: stdin, encoding: .utf8),
            cwd: payload.cwd
        ))
    }
}
