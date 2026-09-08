import Darwin
import Foundation

/// A one-connection-at-a-time HTTP/1.1 server on `127.0.0.1`, for the suites
/// that drive `ModelProxyClient` without a real proxy.
///
/// Raw sockets rather than NIO: the whole point is to observe what the client
/// puts on the wire — the method, the path, and the exact bytes of the body —
/// and to be able to answer with something a real proxy would never send (a
/// 500, a truncated document, nothing at all). A framework that composed the
/// answer for us would test itself.
///
/// It binds port 0, so every instance gets its own port and two suites running
/// in parallel cannot collide.
final class LoopbackHTTPTestServer: @unchecked Sendable {

    /// One request as it arrived. `body` is the raw bytes, not a parse: an
    /// assertion about `{"token":"…"}` should read the document the client
    /// actually sent.
    struct Request: Sendable, Equatable {
        let method: String
        let path: String
        let body: Data
    }

    /// What to answer with. `nil` from a handler means **answer nothing and
    /// hold the connection open**, which is how the client's request timeout
    /// is exercised without a sleep.
    struct Reply: Sendable {
        let status: Int
        let body: String

        static func ok(_ body: String) -> Reply { Reply(status: 200, body: body) }
    }

    private let listenerFD: Int32
    let port: Int

    private let lock = NSLock()
    private var received: [Request] = []
    private var held: [Int32] = []
    private var stopped = false

    init(handler: @escaping @Sendable (Request) -> Reply?) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno: errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw Failure.bind(errno: saved)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(fd, generic, &length)
            }
        }
        guard named == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw Failure.bind(errno: saved)
        }

        self.listenerFD = fd
        self.port = Int(UInt16(bigEndian: assigned.sin_port))

        Thread.detachNewThread { [self] in serve(handler: handler) }
    }

    enum Failure: Error {
        case socket(errno: Int32)
        case bind(errno: Int32)
    }

    /// Every request that arrived, in order.
    func requests() -> [Request] {
        lock.withLock { received }
    }

    /// Closes the listener and every connection still being held open by a
    /// `nil` reply. Idempotent, so a `defer` and an explicit call can both run.
    func stop() {
        let toClose: [Int32] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            let open = held
            held = []
            return open
        }
        Darwin.close(listenerFD)
        for fd in toClose { Darwin.close(fd) }
    }

    // MARK: - The loop

    private func serve(handler: @escaping @Sendable (Request) -> Reply?) {
        while true {
            let connection = accept(listenerFD, nil, nil)
            guard connection >= 0 else { return }
            let isStopped = lock.withLock { stopped }
            guard !isStopped else {
                Darwin.close(connection)
                return
            }
            handle(connection: connection, handler: handler)
        }
    }

    private func handle(connection: Int32, handler: @escaping @Sendable (Request) -> Reply?) {
        guard let request = readRequest(connection) else {
            Darwin.close(connection)
            return
        }
        lock.withLock { received.append(request) }

        guard let reply = handler(request) else {
            // Held rather than closed: a closed connection is an error the
            // client reports instantly, and the point of a `nil` reply is to
            // make the client spend its timeout.
            let keep = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                held.append(connection)
                return true
            }
            if !keep { Darwin.close(connection) }
            return
        }

        let body = Array(reply.body.utf8)
        let head = """
            HTTP/1.1 \(reply.status) \(Self.reason(for: reply.status))\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        writeAll(connection, Array(head.utf8))
        writeAll(connection, body)
        Darwin.close(connection)
    }

    /// Reads one request: the head up to the blank line, then exactly
    /// `Content-Length` bytes of body. No chunked encoding — the client under
    /// test never sends one, and accepting one would hide it if it started.
    private func readRequest(_ connection: Int32) -> Request? {
        var buffer: [UInt8] = []
        var headEnd: Int?
        while headEnd == nil {
            guard let chunk = readSome(connection, upTo: 4096), !chunk.isEmpty else { return nil }
            buffer.append(contentsOf: chunk)
            headEnd = Self.indexOfBlankLine(in: buffer)
        }
        guard let bodyStart = headEnd else { return nil }

        let headText = String(decoding: buffer[0..<(bodyStart - 4)], as: UTF8.self)
        let lines = headText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }

        var body = Array(buffer[bodyStart...])
        while body.count < contentLength {
            guard let chunk = readSome(connection, upTo: contentLength - body.count), !chunk.isEmpty
            else { break }
            body.append(contentsOf: chunk)
        }

        return Request(
            method: String(fields[0]), path: String(fields[1]), body: Data(body))
    }

    private func readSome(_ connection: Int32, upTo count: Int) -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: count)
        let got = chunk.withUnsafeMutableBytes { raw in
            Darwin.read(connection, raw.baseAddress, count)
        }
        guard got >= 0 else { return nil }
        return Array(chunk[0..<got])
    }

    private func writeAll(_ connection: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(connection, raw.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// The index just past `\r\n\r\n`, or nil while the head is incomplete.
    static func indexOfBlankLine(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 0x0d && bytes[index + 1] == 0x0a && bytes[index + 2] == 0x0d
            && bytes[index + 3] == 0x0a {
            return index + 4
        }
        return nil
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
