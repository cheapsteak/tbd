import Foundation

/// One WebSocket frame on a relay socket.
///
/// Binary frames carry the phone channel's bytes; text frames carry the
/// relay's signals (`peer-joined`, `peer-left`, `peer-absent`) and the
/// `ping`/`pong` keepalive.
enum RelayFrame: Sendable, Equatable {
    case binary(Data)
    case text(String)
}

/// Thrown by ``RelaySocket/receive()`` once the socket has closed, from
/// either end. `code` is the WebSocket close code when one is known: 4000
/// means another socket of the same role replaced this one, and 1009 that
/// this socket sent a frame over the relay's size limit.
struct RelaySocketClosed: Error, Equatable, LocalizedError {
    let code: Int?

    var errorDescription: String? {
        guard let code else { return "The relay socket closed." }
        return "The relay socket closed with code \(code)."
    }
}

/// One open WebSocket to a relay room.
protocol RelaySocket: Sendable {
    /// Sends one frame. Throws once the socket has closed.
    func send(_ frame: RelayFrame) async throws
    /// The next frame, in arrival order. Throws ``RelaySocketClosed`` once the
    /// socket has closed and every frame that arrived before the close has
    /// been read.
    func receive() async throws -> RelayFrame
    /// Closes the socket with `code`. Closing a closed socket does nothing.
    func close(code: Int) async
}

/// Opens relay sockets. Production uses `URLSession`; tests use an
/// in-process fake.
protocol RelayTransport: Sendable {
    /// Opens a WebSocket to `url`, sending `userAgent` as the `User-Agent`
    /// header. Returns once the socket is open.
    func connect(url: URL, userAgent: String) async throws -> any RelaySocket
}
