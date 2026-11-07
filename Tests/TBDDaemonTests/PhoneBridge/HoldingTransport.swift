import Foundation

@testable import TBDDaemonLib

/// A transport over a ``FakeRelay`` whose laptop sockets can hold binary
/// sends, so a test can keep a frame the laptop sends from leaving.
final class HoldingTransport: RelayTransport, @unchecked Sendable {
    private let relay: FakeRelay
    private let lock = NSLock()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(relay: FakeRelay) {
        self.relay = relay
    }

    func connect(url: URL, userAgent: String) async throws -> any RelaySocket {
        let socket = try await relay.connect(url: url, userAgent: userAgent)
        return HoldingSocket(base: socket, transport: self)
    }

    /// From now on, a binary frame a laptop socket sends waits until
    /// `release()`.
    func hold() {
        lock.withLock { holding = true }
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

    fileprivate func waitWhileHolding() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock { () -> Bool in
                guard holding else { return false }
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

    func send(_ frame: RelayFrame) async throws {
        if case .binary = frame {
            await transport.waitWhileHolding()
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
