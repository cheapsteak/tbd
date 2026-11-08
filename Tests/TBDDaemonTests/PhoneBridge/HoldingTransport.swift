import Foundation

@testable import TBDDaemonLib

/// A transport over a ``FakeRelay`` whose laptop sockets can hold binary
/// sends, so a test can keep a frame the laptop sends from leaving.
final class HoldingTransport: RelayTransport, @unchecked Sendable {
    private let relay: FakeRelay
    private let lock = NSLock()
    private var holding = false
    /// The one room whose sends are held; nil holds every room's.
    private var heldRoom: String?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(relay: FakeRelay) {
        self.relay = relay
    }

    func connect(url: URL, userAgent: String) async throws -> any RelaySocket {
        let socket = try await relay.connect(url: url, userAgent: userAgent)
        return HoldingSocket(base: socket, transport: self, room: url.lastPathComponent)
    }

    /// From now on, a binary frame a laptop socket sends waits until
    /// `release()`.
    func hold() {
        lock.withLock {
            holding = true
            heldRoom = nil
        }
    }

    /// From now on, a binary frame a laptop socket in `room` sends waits
    /// until `release()`; the other rooms' frames still leave.
    func hold(room: String) {
        lock.withLock {
            holding = true
            heldRoom = room
        }
    }

    /// How many sends are waiting.
    var heldSends: Int {
        lock.withLock { held.count }
    }

    /// Stops holding and lets every waiting send go on. Safe to call twice.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            let waiting = held
            held = []
            return waiting
        }
        for send in waiting {
            send.resume()
        }
    }

    fileprivate func waitWhileHolding(room: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock { () -> Bool in
                guard holding, heldRoom == nil || heldRoom == room else { return false }
                held.append(continuation)
                return true
            }
            if !parked {
                continuation.resume()
            }
        }
    }
}

/// A laptop socket of a ``HoldingTransport``.
private struct HoldingSocket: RelaySocket {
    let base: any RelaySocket
    let transport: HoldingTransport
    /// The relay room the socket is in.
    let room: String

    func send(_ frame: RelayFrame) async throws {
        if case .binary = frame {
            await transport.waitWhileHolding(room: room)
        }
        try await base.send(frame)
    }

    func receive() async throws -> RelayFrame {
        try await base.receive()
    }

    func close(code: Int) async {
        await base.close(code: code)
    }
}
