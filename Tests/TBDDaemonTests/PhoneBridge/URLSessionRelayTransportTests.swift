import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// Connects a production transport to a fresh room on `server`, runs `body`
/// with the open socket and its room ID, and closes the socket whatever
/// happens, which also invalidates its session.
private func withRoomSocket(
    _ server: LoopbackRelayServer,
    _ body: (any RelaySocket, String) async throws -> Void
) async throws {
    let room = try PhoneRoom.newToken()
    let socket = try await URLSessionRelayTransport().connect(
        url: PhoneRoom.socketURL(relay: server.baseURL, roomID: room),
        userAgent: PhoneBridgeConstants.userAgent)
    do {
        try await body(socket, room)
    } catch {
        await socket.close(code: 1000)
        throw error
    }
    await socket.close(code: 1000)
}

/// Runs `body` with an info client on its own ephemeral session, and
/// invalidates the session afterwards.
private func withInfoClient(_ body: (URLSessionRelayInfoClient) async throws -> Void) async throws {
    let session = URLSession(configuration: .ephemeral)
    do {
        try await body(URLSessionRelayInfoClient(session: session))
    } catch {
        session.invalidateAndCancel()
        throw error
    }
    session.invalidateAndCancel()
}

/// A loopback URL nothing listens on: a server's address after it has shut
/// down.
private func closedLoopbackURL() async throws -> URL {
    let server = try await LoopbackRelayServer.start()
    let url = server.baseURL
    await server.shutdown()
    return url
}

/// A transport whose requests outlive every bounded wait in a test.
/// URLSession's default request timeout, 60 seconds without data, would
/// otherwise close an unanswered connection inside a 120-second wait, and a
/// connect that leaked its task would look as if it had released it.
private func transportOutlivingEveryWait() -> URLSessionRelayTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = TestDeadlines.saturatedPassSeconds * 5
    return URLSessionRelayTransport(configuration: configuration)
}

/// `url` with its scheme mapped to the WebSocket one, and `path` as its path.
private func socketURL(_ url: URL, path: String) throws -> URL {
    var parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    parts.scheme = "ws"
    parts.path = path
    return try #require(parts.url)
}

@Suite("URLSessionRelayTransport", .fastPassBounded)
struct URLSessionRelayTransportTests {
    // MARK: The socket

    @Test func connectSendsTheUserAgentAndRoomPath() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { _, room in
                let roomRequests = server.requests.filter { $0.path.hasPrefix("/v1/rooms/") }
                #expect(roomRequests.map(\.path) == ["/v1/rooms/\(room)"])
                #expect(roomRequests.first?.query == "role=laptop")
                #expect(roomRequests.first?.userAgent == PhoneBridgeConstants.userAgent)
            }
        }
    }

    @Test func binaryEchoesAndPingIsAnswered() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { socket, _ in
                try await socket.send(.binary(Data([1, 2, 3])))
                let echo = try await socket.receive()
                #expect(echo == .binary(Data([1, 2, 3])))
                try await socket.send(.text("ping"))
                let pong = try await socket.receive()
                #expect(pong == .text("pong"))
            }
        }
    }

    @Test func aFrameOfTheRelaysFullSizeComesBack() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { socket, _ in
                let frame = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
                try await socket.send(.binary(frame))
                let echo = try await socket.receive()
                #expect(echo == .binary(frame))
            }
        }
    }

    @Test func aMessageOverTheSizeLimitEndsTheSocket() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { socket, _ in
                // URLSession's own limit is 1 MiB; the transport's is the
                // relay's frame limit plus 1,024 bytes.
                let frame = Data(count: URLSessionRelayTransport.maximumMessageSize + 1)
                try await socket.send(.binary(frame))
                await #expect(throws: RelaySocketClosed.self) { _ = try await socket.receive() }
            }
        }
    }

    @Test func aServerCloseSurfacesItsCodeAndKeepsSurfacingIt() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { socket, _ in
                try await socket.send(.text("close-4000"))
                await #expect(throws: RelaySocketClosed(code: 4000)) { _ = try await socket.receive() }
                // A closed socket never goes back to the task: every later
                // receive and send reports the same close.
                await #expect(throws: RelaySocketClosed(code: 4000)) { _ = try await socket.receive() }
                await #expect(throws: RelaySocketClosed(code: 4000)) { try await socket.send(.text("ping")) }
            }
        }
    }

    @Test func aLocalCloseWakesAParkedReceiveAndEndsTheSocket() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { socket, _ in
                let parked = Task { try await socket.receive() }
                // The receive is parked or about to be; either way the close
                // ends it.
                await socket.close(code: 1000)
                await #expect(throws: RelaySocketClosed(code: 1000)) { _ = try await parked.value }
                await #expect(throws: RelaySocketClosed(code: 1000)) { _ = try await socket.receive() }
                await #expect(throws: RelaySocketClosed(code: 1000)) { try await socket.send(.binary(Data([1]))) }
                // Closing again does nothing.
                await socket.close(code: 4000)
                await #expect(throws: RelaySocketClosed(code: 1000)) { _ = try await socket.receive() }
            }
        }
    }

    @Test func aCancelledReceiveLosesNoFrame() async throws {
        try await withLoopbackRelay { server in
            try await withRoomSocket(server) { socket, _ in
                let cancelled = Task { try await socket.receive() }
                cancelled.cancel()
                await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
                // A task receive the cancelled call started may still be in
                // flight; the frame it brings goes to the next receive.
                try await socket.send(.binary(Data([7])))
                let first = try await socket.receive()
                #expect(first == .binary(Data([7])))
                try await socket.send(.binary(Data([8])))
                let second = try await socket.receive()
                #expect(second == .binary(Data([8])))
            }
        }
    }

    @Test func aRefusedConnectThrows() async throws {
        let url = try await closedLoopbackURL()
        let room = try PhoneRoom.newToken()
        await #expect(throws: (any Error).self) {
            _ = try await URLSessionRelayTransport().connect(
                url: PhoneRoom.socketURL(relay: url, roomID: room), userAgent: PhoneBridgeConstants.userAgent)
        }
    }

    @Test func anAnswerOtherThan101Throws() async throws {
        try await withLoopbackRelay { server in
            // The server refuses to upgrade any path outside /v1/rooms/ and
            // answers 404.
            let url = try socketURL(server.baseURL, path: "/v1/elsewhere")
            await #expect(throws: (any Error).self) {
                _ = try await URLSessionRelayTransport().connect(url: url, userAgent: PhoneBridgeConstants.userAgent)
            }
            #expect(server.requests.contains { $0.path == "/v1/elsewhere" })
        }
    }

    @Test func aCancelledConnectThrowsAndReleasesItsConnection() async throws {
        try await withLoopbackRelay { server in
            let url = try socketURL(server.baseURL, path: "/v1/silent")
            let connect = Task {
                try await transportOutlivingEveryWait().connect(url: url, userAgent: PhoneBridgeConstants.userAgent)
            }
            let deadline = TestDeadlines.saturatedPass
            switch await pollUntilTrue(timeout: deadline, { server.silentConnections == 1 }) {
            case .satisfied:
                break
            case .cancelled:
                connect.cancel()
                throw CancellationError()
            case .timedOut:
                connect.cancel()
                throw BoundedWaitTimeout(what: "the connect to reach the server",
                                         observed: "requests \(server.requests)", deadline: deadline)
            }
            connect.cancel()
            await #expect(throws: CancellationError.self) { _ = try await connect.value }
            // The cancelled connect cancelled its task, which closes the
            // connection rather than leaving it open in a live session. The
            // request timeout outlasts this wait, so only that cancel can
            // close it in time.
            switch await pollUntilTrue(timeout: deadline, { server.silentConnections == 0 }) {
            case .satisfied, .cancelled:
                break
            case .timedOut:
                throw BoundedWaitTimeout(what: "the cancelled connect to close its connection",
                                         observed: "\(server.silentConnections) still open", deadline: deadline)
            }
        }
    }

    @Test func aURLThatIsNotAWebSocketURLIsRefusedBeforeAnyRequest() async throws {
        let error = await #expect(throws: URLError.self) {
            _ = try await URLSessionRelayTransport().connect(
                url: URL(string: "https://acme-relay.acme.workers.dev/v1/rooms/x")!,
                userAgent: PhoneBridgeConstants.userAgent)
        }
        #expect(error?.code == .unsupportedURL)
    }

    // MARK: The relay info check

    @Test func infoReadsATBDRelay() async throws {
        try await withLoopbackRelay { server in
            try await withInfoClient { client in
                let info = try await client.info(relay: server.baseURL)
                #expect(info == PhoneRelayInfo(name: "tbd-relay", version: "1.0.0", api: [1]))
            }
            let infoRequests = server.requests.filter { $0.path == "/v1/info" }
            #expect(infoRequests.map(\.method) == ["GET"])
            #expect(infoRequests.first?.userAgent == PhoneBridgeConstants.userAgent)
        }
    }

    @Test func infoKeepsTheRelayPathAndDropsATrailingSlash() async throws {
        try await withLoopbackRelay { server in
            let relay = try #require(URL(string: server.baseURL.absoluteString + "/"))
            try await withInfoClient { client in
                _ = try await client.info(relay: relay)
            }
            #expect(server.requests.map(\.path) == ["/v1/info"])
        }
    }

    @Test func infoFailuresAreNamed() async throws {
        try await withLoopbackRelay { server in
            try await withInfoClient { client in
                server.setInfoResponse(status: 500, body: "{}")
                await #expect(throws: PhoneBridgeError.relayCheckFailed("HTTP 500")) {
                    _ = try await client.info(relay: server.baseURL)
                }
                server.setInfoResponse(status: 200, body: "hello")
                await #expect(throws: PhoneBridgeError.notATBDRelay) {
                    _ = try await client.info(relay: server.baseURL)
                }
                // The check reads the relay every time: a fixed relay is
                // seen as fixed at once.
                server.setInfoResponse(status: 200, body: #"{"name":"tbd-relay","version":"1.1.0","api":[1]}"#)
                let version = try await client.info(relay: server.baseURL).version
                #expect(version == "1.1.0")
            }
        }
    }

    @Test func anUnreachableRelayIsACheckFailure() async throws {
        let url = try await closedLoopbackURL()
        try await withInfoClient { client in
            let error = await #expect(throws: PhoneBridgeError.self) { _ = try await client.info(relay: url) }
            guard case .relayCheckFailed(let detail) = error else {
                Issue.record("expected relayCheckFailed, got \(String(describing: error))")
                return
            }
            #expect(!detail.isEmpty)
            #expect(error?.localizedDescription == "Could not reach the relay: \(detail)")
        }
    }

    // MARK: Compatibility and versions

    @Test func compatibilityNeedsTheNameAndAPI1() throws {
        try RelayCompatibility.check(.init(name: "tbd-relay", version: "1.0.0", api: [1]))
        try RelayCompatibility.check(.init(name: "tbd-relay", version: "2.0.0", api: [1, 2]))
        #expect(throws: PhoneBridgeError.unsupportedRelayAPI([2])) {
            try RelayCompatibility.check(.init(name: "tbd-relay", version: "2.0.0", api: [2]))
        }
        #expect(throws: PhoneBridgeError.notATBDRelay) {
            try RelayCompatibility.check(.init(name: "other", version: "1.0.0", api: [1]))
        }
    }

    @Test func errorDescriptionsNameTheProblem() {
        #expect(PhoneBridgeError.relayCheckFailed("HTTP 500").localizedDescription
            == "Could not reach the relay: HTTP 500")
        #expect(PhoneBridgeError.notATBDRelay.localizedDescription == "That address is not a TBD relay.")
        #expect(PhoneBridgeError.unsupportedRelayAPI([2]).localizedDescription
            == "This relay offers API [2], but this TBD needs API 1. Deploy the relay again from the guide.")
    }

    @Test func versionComparison() {
        #expect(PhoneRelayVersion.isOlder("0.9.0", than: "1.0.0") == true)
        #expect(PhoneRelayVersion.isOlder("1.0.0", than: "1.0.0") == false)
        #expect(PhoneRelayVersion.isOlder("1.10.0", than: "1.9.0") == false)
        #expect(PhoneRelayVersion.isOlder("1.9.9", than: "1.10.0") == true)
        #expect(PhoneRelayVersion.isOlder("2.0.0", than: "1.99.99") == false)
        #expect(PhoneRelayVersion.isOlder("banana", than: "1.0.0") == nil)
        #expect(PhoneRelayVersion.isOlder("1.0.0", than: "1.0") == nil)
        #expect(PhoneRelayVersion.isOlder("1.0.0-beta", than: "1.0.0") == nil)
        #expect(PhoneRelayVersion.isOlder("1..0", than: "1.0.0") == nil)
        #expect(PhoneRelayVersion.isOlder("+1.0.0", than: "2.0.0") == nil)
    }
}
