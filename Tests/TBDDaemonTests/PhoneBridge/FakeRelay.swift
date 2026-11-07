import Foundation
import TestSupport

@testable import TBDDaemonLib

/// One `connect(url:userAgent:)` call the fake relay saw, failed or not.
struct ConnectAttempt: Sendable, Equatable {
    let url: URL
    let userAgent: String
}

/// Why the fake relay refused a connect or a join.
enum FakeRelayError: Error, Equatable, LocalizedError {
    /// `failNextConnects(_:)` asked for this failure.
    case injectedConnectFailure
    /// The URL is not a laptop room URL with a valid room ID; the real relay
    /// answers 404 for a bad room ID and 400 for a bad role.
    case httpStatus(Int)
    /// Two `receive()` calls were parked on one socket at once, which no
    /// caller should do.
    case concurrentReceive

    var errorDescription: String? {
        switch self {
        case .injectedConnectFailure:
            return "The fake relay refused the connection (injected failure)."
        case .httpStatus(let status):
            return "The fake relay answered HTTP \(status)."
        case .concurrentReceive:
            return "Two receives were parked on one fake relay socket at once."
        }
    }
}

/// An in-process relay that follows relay API v1 and its signal routing, for
/// the phone bridge's tests.
///
/// - **Laptop side.** `connect(url:userAgent:)` is the `RelayTransport` the
///   code under test uses. It records every call in `connectAttempts`, then
///   refuses an injected failure, a URL that is not
///   `<prefix>/v1/rooms/<room ID>?role=laptop` over `ws` or `wss`, or a room
///   ID that does not match `^[A-Za-z0-9_-]{43}$`.
/// - **Phone side.** `joinAsPhone(room:)` returns a ``FakePhoneSocket``.
/// - **Signals.**
///   - A joining socket replaces any open socket of its role, closing the old
///     one with 4000 and sending no `peer-left` for it.
///   - When the other role is present, the relay sends `peer-joined` to the
///     other socket and to the new one.
///   - A phone that joins with no laptop present gets `peer-absent`. A laptop
///     that joins an empty room gets nothing.
///   - When the last socket of a role closes, the other role gets `peer-left`.
/// - **Frames.**
///   - A binary frame goes to the other role, and is dropped when that role
///     is absent. A socket closed from either end cannot send: its `send`
///     throws `RelaySocketClosed`, so nothing it sends after the close is
///     forwarded.
///   - A binary frame over 65,536 bytes is not forwarded: it closes its
///     sender with 1009, and the peer gets `peer-left`.
///   - Client text is never forwarded. `ping` is answered with `pong` while
///     `answersPings` is true.
///
/// A socket the relay closes keeps the frames it was already sent readable,
/// then reports the close; a socket its client closes drops them.
///
/// Every piece of state sits behind one lock, so tests can read the controls
/// synchronously, as `advanceUntil` conditions do.
final class FakeRelay: RelayTransport, @unchecked Sendable {
    /// The relay's largest binary frame (relay API v1).
    static let maxFrameBytes = 65_536

    private let lock = NSLock()
    private var rooms: [String: FakeRelayRoom] = [:]
    private var attempts: [ConnectAttempt] = []
    private var connectFailuresToInject = 0
    private var pingsAnswered = true

    init() {}

    // MARK: Laptop side

    func connect(url: URL, userAgent: String) async throws -> any RelaySocket {
        let endpoint: FakeRelayEndpoint = try locked { wakeups in
            attempts.append(ConnectAttempt(url: url, userAgent: userAgent))
            if connectFailuresToInject > 0 {
                connectFailuresToInject -= 1
                throw FakeRelayError.injectedConnectFailure
            }
            let room = try Self.laptopRoomID(in: url)
            return join(.laptop, room: room, &wakeups)
        }
        return FakeLaptopSocket(relay: self, endpoint: endpoint)
    }

    // MARK: Phone side

    /// A phone socket in `room`, joined the way the loader joins.
    func joinAsPhone(room: String) throws -> FakePhoneSocket {
        guard Self.isValidRoomID(room) else { throw FakeRelayError.httpStatus(404) }
        let endpoint = locked { wakeups in join(.phone, room: room, &wakeups) }
        return FakePhoneSocket(relay: self, endpoint: endpoint)
    }

    // MARK: Controls

    /// Every connect call so far, in order, failed ones included.
    var connectAttempts: [ConnectAttempt] {
        lock.withLock { attempts }
    }

    /// Whether the relay answers a client's `ping` with `pong`. True at
    /// first; false makes every socket look half open to its keepalive.
    var answersPings: Bool {
        get { lock.withLock { pingsAnswered } }
        set { lock.withLock { pingsAnswered = newValue } }
    }

    /// Makes the next `count` connect calls throw
    /// `FakeRelayError.injectedConnectFailure`.
    func failNextConnects(_ count: Int) {
        lock.withLock { connectFailuresToInject += count }
    }

    /// The relay closes the room's laptop socket with `code`. The phone gets
    /// `peer-left`, except for 4000, which stands for another laptop socket
    /// replacing this one, as the real relay sends no `peer-left` then.
    func closeLaptop(room: String, code: Int) {
        locked { wakeups in
            guard let laptop = rooms[room]?.laptop else { return }
            closeRemotely(laptop, code: code, &wakeups)
            detach(laptop, announce: code != 4000, &wakeups)
        }
    }

    /// The relay sends `frame` to the room's laptop socket, as if it were a
    /// relay signal. Lets a test send text the relay never sends a laptop,
    /// such as `peer-absent` or a signal a later relay might add.
    func sendToLaptop(room: String, _ frame: RelayFrame) {
        locked { wakeups in
            guard let laptop = rooms[room]?.laptop else { return }
            deliver(frame, to: laptop, &wakeups)
        }
    }

    /// The room's next binary frame from the phone reaches the laptop twice.
    func duplicateNextPhoneFrame(room: String) {
        lock.withLock { rooms[room, default: FakeRelayRoom()].duplicateNextPhoneFrame = true }
    }

    /// The room's next two binary frames from the phone reach the laptop in
    /// the opposite order.
    func swapNextTwoPhoneFrames(room: String) {
        lock.withLock { rooms[room, default: FakeRelayRoom()].swapNextTwoPhoneFrames = true }
    }

    /// Whether the room has an open laptop socket.
    func laptopPresent(room: String) -> Bool {
        lock.withLock { rooms[room]?.laptop != nil }
    }

    /// Every binary frame laptop sockets sent in the room, in order, whether
    /// the relay forwarded it or dropped it for want of a phone.
    func laptopFrames(room: String) -> [Data] {
        lock.withLock { rooms[room]?.laptopFrames ?? [] }
    }

    /// Every text frame laptop sockets sent in the room, in order. The relay
    /// forwards none of them.
    func laptopTexts(room: String) -> [String] {
        lock.withLock { rooms[room]?.laptopTexts ?? [] }
    }

    /// The codes laptop sockets in the room closed themselves with, in order.
    /// A close the relay made is not listed.
    func laptopCloseCodes(room: String) -> [Int] {
        lock.withLock { rooms[room]?.laptopCloseCodes ?? [] }
    }

    /// The rooms that have an open laptop socket.
    func openLaptopRooms() -> Set<String> {
        lock.withLock { Set(rooms.compactMap { $0.value.laptop == nil ? nil : $0.key }) }
    }

    // MARK: Room IDs and URLs

    /// Whether `room` matches `^[A-Za-z0-9_-]{43}$`, as the relay requires.
    static func isValidRoomID(_ room: String) -> Bool {
        room.utf8.count == 43 && room.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    /// The room ID in a laptop socket URL, or the status the relay would
    /// answer it with.
    private static func laptopRoomID(in url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "wss" || parts.scheme == "ws",
              parts.host?.isEmpty == false else { throw FakeRelayError.httpStatus(404) }
        let path = parts.percentEncodedPath
        guard !path.contains("//"), let marker = path.range(of: "/v1/rooms/", options: .backwards) else {
            throw FakeRelayError.httpStatus(404)
        }
        let room = String(path[marker.upperBound...])
        guard isValidRoomID(room) else { throw FakeRelayError.httpStatus(404) }
        guard parts.percentEncodedQuery == "role=laptop" else { throw FakeRelayError.httpStatus(400) }
        return room
    }

    // MARK: Socket operations, for the two socket types

    fileprivate func send(_ frame: RelayFrame, from endpoint: FakeRelayEndpoint) throws {
        try locked { wakeups in
            if let code = endpoint.closeCode { throw RelaySocketClosed(code: code) }
            switch frame {
            case .text(let text):
                if endpoint.role == .laptop {
                    rooms[endpoint.room]?.laptopTexts.append(text)
                }
                if text == "ping", pingsAnswered {
                    deliver(.text("pong"), to: endpoint, &wakeups)
                }
            case .binary(let bytes):
                guard bytes.count <= Self.maxFrameBytes else {
                    closeRemotely(endpoint, code: 1009, &wakeups)
                    detach(endpoint, announce: true, &wakeups)
                    return
                }
                if endpoint.role == .laptop {
                    rooms[endpoint.room]?.laptopFrames.append(bytes)
                }
                guard rooms[endpoint.room]?[endpoint.role] === endpoint,
                      let peer = rooms[endpoint.room]?[endpoint.role.other] else { return }
                if endpoint.role == .phone {
                    forwardFromPhone(bytes, to: peer, &wakeups)
                } else {
                    deliver(.binary(bytes), to: peer, &wakeups)
                }
            }
        }
    }

    fileprivate func receive(on endpoint: FakeRelayEndpoint) async throws -> RelayFrame {
        let waiter = FakeRelayReceiveWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RelayFrame, any Error>) in
                let ready: Result<RelayFrame, any Error>? = self.lock.withLock {
                    if waiter.isCancelled { return .failure(CancellationError()) }
                    if !endpoint.inbox.isEmpty { return .success(endpoint.inbox.removeFirst()) }
                    if let code = endpoint.closeCode { return .failure(RelaySocketClosed(code: code)) }
                    if endpoint.waiter != nil { return .failure(FakeRelayError.concurrentReceive) }
                    waiter.continuation = continuation
                    endpoint.waiter = waiter
                    return nil
                }
                if let ready {
                    continuation.resume(with: ready)
                }
            }
        } onCancel: {
            let parked: CheckedContinuation<RelayFrame, any Error>? = self.lock.withLock {
                waiter.isCancelled = true
                guard let continuation = waiter.continuation else { return nil }
                waiter.continuation = nil
                if endpoint.waiter === waiter {
                    endpoint.waiter = nil
                }
                return continuation
            }
            parked?.resume(throwing: CancellationError())
        }
    }

    /// The client closes its own socket: unread frames are dropped, and the
    /// other role gets `peer-left` if this was its role's open socket.
    fileprivate func close(_ endpoint: FakeRelayEndpoint, code: Int) {
        locked { wakeups in
            guard endpoint.closeCode == nil else { return }
            endpoint.closeCode = code
            endpoint.inbox.removeAll()
            wakeParkedReceive(on: endpoint, throwing: RelaySocketClosed(code: code), &wakeups)
            if endpoint.role == .laptop {
                rooms[endpoint.room]?.laptopCloseCodes.append(code)
            }
            detach(endpoint, announce: true, &wakeups)
        }
    }

    fileprivate func takeFrame(from endpoint: FakeRelayEndpoint) -> RelayFrame? {
        lock.withLock { endpoint.inbox.isEmpty ? nil : endpoint.inbox.removeFirst() }
    }

    fileprivate func hasFrameOrClose(_ endpoint: FakeRelayEndpoint) -> Bool {
        lock.withLock { !endpoint.inbox.isEmpty || endpoint.closeCode != nil }
    }

    fileprivate func closeCode(of endpoint: FakeRelayEndpoint) -> Int? {
        lock.withLock { endpoint.closeCode }
    }

    fileprivate func history(of endpoint: FakeRelayEndpoint) -> [RelayFrame] {
        lock.withLock { endpoint.history }
    }

    // MARK: Routing, all under the lock

    /// Runs `body` under the lock, then resumes the receives it woke, which
    /// must never happen while the lock is held.
    private func locked<T>(_ body: (inout [() -> Void]) throws -> T) rethrows -> T {
        var wakeups: [() -> Void] = []
        let result = try lock.withLock { try body(&wakeups) }
        for wake in wakeups {
            wake()
        }
        return result
    }

    private func join(_ role: FakeRelayEndpoint.Role, room: String,
                      _ wakeups: inout [() -> Void]) -> FakeRelayEndpoint {
        let endpoint = FakeRelayEndpoint(room: room, role: role)
        if let replaced = rooms[room]?[role] {
            // Replaced, not left: the other role hears `peer-joined` below
            // and no `peer-left`.
            closeRemotely(replaced, code: 4000, &wakeups)
            if role == .phone {
                rooms[room]?.heldPhoneFrame = nil
            }
        }
        rooms[room, default: FakeRelayRoom()][role] = endpoint
        if let peer = rooms[room]?[role.other] {
            deliver(.text("peer-joined"), to: peer, &wakeups)
            deliver(.text("peer-joined"), to: endpoint, &wakeups)
        } else if role == .phone {
            deliver(.text("peer-absent"), to: endpoint, &wakeups)
        }
        return endpoint
    }

    /// Takes `endpoint` out of its room if it is still its role's open
    /// socket, and tells the other role `peer-left` when `announce` is set.
    private func detach(_ endpoint: FakeRelayEndpoint, announce: Bool, _ wakeups: inout [() -> Void]) {
        guard rooms[endpoint.room]?[endpoint.role] === endpoint else { return }
        rooms[endpoint.room]?[endpoint.role] = nil
        if endpoint.role == .phone {
            rooms[endpoint.room]?.heldPhoneFrame = nil
        }
        if announce, let peer = rooms[endpoint.room]?[endpoint.role.other] {
            deliver(.text("peer-left"), to: peer, &wakeups)
        }
    }

    /// The relay closes `endpoint`: frames it was already sent stay
    /// readable, and a parked receive, which means none are left, learns of
    /// the close now.
    private func closeRemotely(_ endpoint: FakeRelayEndpoint, code: Int, _ wakeups: inout [() -> Void]) {
        guard endpoint.closeCode == nil else { return }
        endpoint.closeCode = code
        wakeParkedReceive(on: endpoint, throwing: RelaySocketClosed(code: code), &wakeups)
    }

    private func deliver(_ frame: RelayFrame, to endpoint: FakeRelayEndpoint, _ wakeups: inout [() -> Void]) {
        guard endpoint.closeCode == nil else { return }
        endpoint.history.append(frame)
        if let waiter = endpoint.waiter, let continuation = waiter.continuation {
            endpoint.waiter = nil
            waiter.continuation = nil
            wakeups.append { continuation.resume(returning: frame) }
        } else {
            endpoint.inbox.append(frame)
        }
    }

    private func wakeParkedReceive(on endpoint: FakeRelayEndpoint, throwing error: any Error,
                                   _ wakeups: inout [() -> Void]) {
        guard let waiter = endpoint.waiter, let continuation = waiter.continuation else { return }
        endpoint.waiter = nil
        waiter.continuation = nil
        wakeups.append { continuation.resume(throwing: error) }
    }

    /// Forwards a phone's binary frame to the laptop, applying a pending
    /// duplicate or swap.
    private func forwardFromPhone(_ bytes: Data, to laptop: FakeRelayEndpoint, _ wakeups: inout [() -> Void]) {
        let room = laptop.room
        if rooms[room]?.duplicateNextPhoneFrame == true {
            rooms[room]?.duplicateNextPhoneFrame = false
            deliver(.binary(bytes), to: laptop, &wakeups)
            deliver(.binary(bytes), to: laptop, &wakeups)
            return
        }
        if rooms[room]?.swapNextTwoPhoneFrames == true {
            guard let held = rooms[room]?.heldPhoneFrame else {
                rooms[room]?.heldPhoneFrame = bytes
                return
            }
            rooms[room]?.swapNextTwoPhoneFrames = false
            rooms[room]?.heldPhoneFrame = nil
            deliver(.binary(bytes), to: laptop, &wakeups)
            deliver(.binary(held), to: laptop, &wakeups)
            return
        }
        deliver(.binary(bytes), to: laptop, &wakeups)
    }
}

/// A phone's socket on a ``FakeRelay``.
struct FakePhoneSocket: Sendable {
    let room: String
    private let relay: FakeRelay
    private let endpoint: FakeRelayEndpoint

    fileprivate init(relay: FakeRelay, endpoint: FakeRelayEndpoint) {
        self.room = endpoint.room
        self.relay = relay
        self.endpoint = endpoint
    }

    /// Sends one frame. Throws `RelaySocketClosed` once the socket has closed.
    func send(_ frame: RelayFrame) throws {
        try relay.send(frame, from: endpoint)
    }

    /// Closes the socket from the phone's end.
    func close(code: Int = 1000) {
        relay.close(endpoint, code: code)
    }

    /// The code the socket closed with, from either end; nil while open.
    var closeCode: Int? {
        relay.closeCode(of: endpoint)
    }

    /// The next frame the relay sent this socket. Throws `RelaySocketClosed`
    /// once the socket has closed and every earlier frame has been read, and
    /// ``FakePhoneSocketTimeout``, naming every frame this socket has been
    /// sent, when nothing arrives within `timeout`.
    func next(timeout: Duration = TestDeadlines.saturatedPass) async throws -> RelayFrame {
        let outcome = await pollUntilTrue(timeout: timeout) { relay.hasFrameOrClose(endpoint) }
        if let frame = relay.takeFrame(from: endpoint) { return frame }
        if let code = relay.closeCode(of: endpoint) { throw RelaySocketClosed(code: code) }
        if outcome == .cancelled { throw CancellationError() }
        throw FakePhoneSocketTimeout(room: room, waited: timeout, seen: relay.history(of: endpoint))
    }
}

/// A ``FakePhoneSocket/next(timeout:)`` that waited out its budget.
struct FakePhoneSocketTimeout: Error, CustomStringConvertible, LocalizedError {
    let room: String
    let waited: Duration
    /// Every frame the socket was sent, read or not, in order.
    let seen: [RelayFrame]

    var description: String {
        let frames = seen.map { frame -> String in
            switch frame {
            case .text(let text):
                return "text \"\(text)\""
            case .binary(let bytes):
                return "binary (\(bytes.count) bytes)"
            }
        }
        return "the phone socket in room \(room) got no frame within \(waited); "
            + "frames it was sent: [\(frames.joined(separator: ", "))]"
    }

    var errorDescription: String? { description }
}

/// The laptop's socket on a ``FakeRelay``.
private struct FakeLaptopSocket: RelaySocket {
    let relay: FakeRelay
    let endpoint: FakeRelayEndpoint

    func send(_ frame: RelayFrame) async throws {
        try relay.send(frame, from: endpoint)
    }

    func receive() async throws -> RelayFrame {
        try await relay.receive(on: endpoint)
    }

    func close(code: Int) async {
        relay.close(endpoint, code: code)
    }
}

/// The relay's side of one client socket. Every field is guarded by the
/// owning ``FakeRelay``'s lock.
private final class FakeRelayEndpoint: @unchecked Sendable {
    enum Role: Sendable {
        case laptop, phone

        var other: Role { self == .laptop ? .phone : .laptop }
    }

    let room: String
    let role: Role
    /// Frames sent to this socket and not read yet.
    var inbox: [RelayFrame] = []
    /// Every frame sent to this socket, for diagnostics.
    var history: [RelayFrame] = []
    /// The close code, from either end; nil while open.
    var closeCode: Int?
    /// A receive parked on an empty inbox.
    var waiter: FakeRelayReceiveWaiter?

    init(room: String, role: Role) {
        self.room = room
        self.role = role
    }
}

/// One parked `receive()`. Guarded by the relay's lock; a class so the
/// receive and its cancellation handler, which can run in either order, see
/// the same state.
private final class FakeRelayReceiveWaiter: @unchecked Sendable {
    var continuation: CheckedContinuation<RelayFrame, any Error>?
    var isCancelled = false
}

/// One room's sockets and the frames the tests inspect. Guarded by the
/// relay's lock.
private struct FakeRelayRoom {
    var laptop: FakeRelayEndpoint?
    var phone: FakeRelayEndpoint?
    var laptopFrames: [Data] = []
    var laptopTexts: [String] = []
    var laptopCloseCodes: [Int] = []
    var duplicateNextPhoneFrame = false
    var swapNextTwoPhoneFrames = false
    var heldPhoneFrame: Data?

    subscript(role: FakeRelayEndpoint.Role) -> FakeRelayEndpoint? {
        get { role == .laptop ? laptop : phone }
        set {
            if role == .laptop {
                laptop = newValue
            } else {
                phone = newValue
            }
        }
    }
}
