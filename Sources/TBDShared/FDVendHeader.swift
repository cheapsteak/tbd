import Foundation

/// Structured header accompanying every vended pane fd (JSON-encoded into the
/// `sendmsg` payload). The composite (worktreeID, paneID, attachID) identity
/// is what the app-side receive loop uses to route a received fd to the right
/// waiter — bare pane IDs are only unique within one tmux server, concurrent
/// attaches for different panes interleave on the single sidecar socket, and
/// `attachID` (a per-request nonce the app mints and the daemon echoes)
/// prevents a superseded attach's stale fd from being delivered to a fresh
/// attach for the SAME pane that raced it.
public struct FDVendHeader: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let paneID: String
    public let attachID: UUID
    public init(worktreeID: UUID, paneID: String, attachID: UUID) {
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.attachID = attachID
    }
    /// Stable key used by both sides' demux maps.
    public var routingKey: String { "\(worktreeID.uuidString)/\(paneID)/\(attachID.uuidString)" }
}
