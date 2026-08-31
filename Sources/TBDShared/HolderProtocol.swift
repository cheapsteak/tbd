import Foundation

public enum HolderProtocolVersion {
    /// Bumped only for a wire-compatible-breaking change. The daemon must
    /// interoperate with every version that has ever shipped, because a
    /// long-lived session keeps running the holder binary it was born with.
    public static let current = 1
    /// Returned to a second concurrent client, which is then disconnected.
    /// A distinct value so "busy" can never be mistaken for a real version.
    public static let busySentinel = -1
}

public struct HolderLaunchRequest: Codable, Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var columns: UInt16
    public var rows: UInt16

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        columns: UInt16,
        rows: UInt16
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.columns = columns
        self.rows = rows
    }
}

/// Identifies the TBD *installation* that spawned a holder.
///
/// Given at spawn, returned by every handshake, and compared before any
/// reclamation. A completed handshake proves a holder is alive, not that it is
/// ours: the default `TBD_HOME` is shared by every checkout on a machine, so
/// "reachable but absent from my database" is exactly what a foreign, healthy
/// session looks like.
///
/// Minted once per installation and persisted in the `config` row — it must
/// identify the installation, not the process, or a restarted daemon could not
/// reclaim the holders it spawned minutes earlier.
public struct HolderOwnerToken: Codable, Sendable, Equatable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum HolderChildStatus: Codable, Sendable, Equatable {
    case alive
    case exited(code: Int32)
    /// The holder could not observe a status — never fabricate one.
    case exitedStatusUnknown
}

public struct HolderChildDescription: Codable, Sendable, Equatable {
    public var childPID: Int32
    public var ttyName: String
    public var status: HolderChildStatus
    public var launch: HolderLaunchRequest
    /// Whoever spawned this holder. Reclamation compares this before killing.
    public var owner: HolderOwnerToken

    public init(
        childPID: Int32,
        ttyName: String,
        status: HolderChildStatus,
        launch: HolderLaunchRequest,
        owner: HolderOwnerToken
    ) {
        self.childPID = childPID
        self.ttyName = ttyName
        self.status = status
        self.launch = launch
        self.owner = owner
    }
}

/// The verbs are spelled `…PTY` rather than `…Master`: SwiftLint's
/// `inclusive_language` rule refuses the POSIX word in a *declaration*, and a
/// suppression on the protocol's central verb is worse than a name whose doc
/// comment says exactly which end of the pty travels. Prose — here and
/// throughout the holder code — still says "pty master", because that is what
/// `forkpty` calls the fd and the rule does not reach comments.
public enum HolderRequest: Codable, Sendable, Equatable {
    /// Report the child without transferring anything.
    case describe
    /// Report the child and hand over a dup of the pty master via SCM_RIGHTS.
    case handOverPTY
    /// Close the pty master and stop reporting, so a killed session cannot be
    /// resurrected. iTerm2's preemptive wait, adopted for the same reason.
    case forget
}

public enum HolderResponse: Codable, Sendable, Equatable {
    case described(HolderChildDescription)
    /// Accompanies the `SCM_RIGHTS` transfer of the pty master fd.
    case handedOverPTY(HolderChildDescription)
    case forgotten
    case rejected(version: Int)
}
