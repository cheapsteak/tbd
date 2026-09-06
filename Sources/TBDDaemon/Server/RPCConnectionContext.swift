import Foundation

/// What the daemon knows about the socket a request arrived on, as opposed to
/// what the request says about itself.
///
/// One field, and it is the only fact on this path that cannot be forged:
/// `LOCAL_PEERPID` is a property of the **socket**, not of the bytes on it, so
/// the kernel names the process that actually connected. Contrast
/// `ActuationActor`, which travels IN the request and is a self-declaration the
/// daemon has never verified — it records which door an act came through and
/// carries no authority.
///
/// Absent — a nil context, or a nil `peerPID` — means "not established". Every
/// consumer must read that as no, never as probably fine: this is the input to
/// an authorization decision and it has exactly two answers.
///
/// `public` only because it names a parameter of `RPCRouter.handleRaw` and
/// `RPCRouter.handle`, which are public. Its member and initializer stay
/// internal: the only thing entitled to mint one is the socket server that read
/// the pid from the kernel.
public struct RPCConnectionContext: Sendable, Equatable {
    /// The pid the kernel reports for the peer of this connection, read once at
    /// accept. Nil when the option could not be read, or when the request did
    /// not arrive over a socket at all.
    let peerPID: Int32?

    init(peerPID: Int32?) { self.peerPID = peerPID }
}
