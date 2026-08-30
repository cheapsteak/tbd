import Foundation
import TBDShared

/// One shadow peer helper's invocation.
///
/// **Argv is a user-visible surface here, not just an internal calling
/// convention.** The design requires helpers to carry distinctive argv "so `ps`
/// reads sanely and no pattern-kill takes out a sibling", and every field below
/// is spelled out on the command line for that reason rather than passed in the
/// environment: `ps` shows arguments and does not show environment (macOS
/// refuses `ps eww` for another process under SIP, and even for our own it is
/// unreliable). So a `ps` line names the executable, the handle that identifies
/// *which* shadow this is, and the peer name a human recognises.
///
/// The discriminator to pattern-match on is `--handle <handle>`, never the
/// executable name: `pkill -f TBDPeerHelper` takes out every shadow on the
/// machine.
struct PeerHelperOptions: Sendable, Equatable {
    /// The opaque handle TBD minted for this shadow. Never a socket path — the
    /// handle-to-socket table is the daemon's, kept privately, and is what
    /// stops a frame from the far side naming any socket in `/tmp/cc-socks`.
    let handle: String
    /// `<provider>:<worktree display name>`.
    let name: String
    /// The remote session's status, verbatim from its own registry row.
    let status: String
    /// The peer protocol the link negotiated. Frames whose declared protocol
    /// differs are dropped.
    let peerProtocol: Int
    /// A working directory that exists on **this** machine — the worktree the
    /// remote session was adopted into. A remote path would resolve to nothing
    /// locally.
    let cwd: String
    /// Where the shadow's socket is bound. Injected rather than hardcoded so a
    /// test never binds into the `/tmp/cc-socks` every real session on the
    /// machine reads.
    let socketDirectory: URL
    /// The registry directory the record is published in. Injected for the same
    /// reason, and defaulted through `ShadowPeerRecordStore(environment:)` so
    /// it honors `TBD_CLAUDE_HOST_HOME`.
    let sessionsDirectory: URL
    /// A stable session id for this shadow across a rewrite. Minted when absent.
    let sessionID: String?
    /// The agent version to advertise, when the far side reported one. Absent
    /// by default — see `ShadowPeerRecord.version`.
    let version: String?

    static let defaultSocketDirectory = URL(
        fileURLWithPath: "/tmp/cc-socks", isDirectory: true)

    static let usage = """
        usage: TBDPeerHelper --handle <handle> --name <name> [options]

          --handle <handle>       opaque handle TBD minted for this shadow (required)
          --name <name>           peer name, <provider>:<worktree display name> (required)
          --status <status>       initial status (default: idle)
          --peer-protocol <n>     negotiated peer protocol (default: \
        \(PeerBridgeFrameCodec.peerProtocol))
          --cwd <path>            a locally-existing working directory for the record
          --socket-dir <path>     where to bind the shadow's socket (default: \
        \(PeerHelperOptions.defaultSocketDirectory.path))
          --sessions-dir <path>   registry directory (default: the host Claude store)
          --session-id <id>       session id for the record (default: a fresh UUID)
          --version <version>     agent version to advertise (default: omitted)

        Reads control frames as NDJSON on stdin and exits when stdin reaches EOF.
        """

    static func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PeerHelperOptions {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw PeerHelperOptionsError.unexpectedArgument(flag)
            }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                throw PeerHelperOptionsError.missingValue(flag: flag)
            }
            values[String(flag.dropFirst(2))] = arguments[next]
            index = arguments.index(after: next)
        }

        guard let handle = values["handle"], !handle.isEmpty else {
            throw PeerHelperOptionsError.missingRequiredFlag("--handle")
        }
        guard let name = values["name"], !name.isEmpty else {
            throw PeerHelperOptionsError.missingRequiredFlag("--name")
        }

        let peerProtocol: Int
        if let raw = values["peer-protocol"] {
            guard let parsed = Int(raw) else {
                throw PeerHelperOptionsError.notAnInteger(flag: "--peer-protocol", value: raw)
            }
            peerProtocol = parsed
        } else {
            peerProtocol = PeerBridgeFrameCodec.peerProtocol
        }

        let sessionsDirectory = values["sessions-dir"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? ShadowPeerRecordStore(environment: environment).sessionsDirectory

        return PeerHelperOptions(
            handle: handle,
            name: name,
            status: values["status"] ?? "idle",
            peerProtocol: peerProtocol,
            cwd: values["cwd"] ?? FileManager.default.currentDirectoryPath,
            socketDirectory: values["socket-dir"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? Self.defaultSocketDirectory,
            sessionsDirectory: sessionsDirectory,
            sessionID: values["session-id"],
            version: values["version"])
    }
}

/// Failures parsing a helper's argv. A helper that cannot understand its own
/// invocation exits before it binds anything, so there is nothing to reclaim.
enum PeerHelperOptionsError: LocalizedError, Equatable, Sendable {
    case unexpectedArgument(String)
    case missingValue(flag: String)
    case missingRequiredFlag(String)
    case notAnInteger(flag: String, value: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedArgument(let argument):
            return "unexpected argument \"\(argument)\"; every option is --flag value"
        case .missingValue(let flag):
            return "\(flag) needs a value"
        case .missingRequiredFlag(let flag):
            return "\(flag) is required"
        case .notAnInteger(let flag, let value):
            return "\(flag) expects an integer, got \"\(value)\""
        }
    }
}
