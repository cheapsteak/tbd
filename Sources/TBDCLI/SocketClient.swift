import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import TBDShared

/// Errors that can occur when communicating with the daemon.
enum SocketClientError: Error, CustomStringConvertible {
    case daemonNotRunning
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case invalidResponse

    var description: String {
        switch self {
        case .daemonNotRunning:
            return "TBD daemon is not running. Start it with: tbdd"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .sendFailed(let msg):
            return "Send failed: \(msg)"
        case .receiveFailed(let msg):
            return "Receive failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from daemon"
        }
    }
}

/// A simple synchronous Unix domain socket client that connects to the TBD daemon.
/// Uses raw POSIX sockets for simplicity in a one-shot CLI context.
struct SocketClient: Sendable {
    let socketPath: String

    init(socketPath: String = TBDConstants.socketPath) {
        self.socketPath = socketPath
    }

    /// Check if the daemon socket exists (quick check before connecting).
    var isDaemonRunning: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Send an RPC request to the daemon and return the response.
    func send(_ request: RPCRequest) throws -> RPCResponse {
        guard isDaemonRunning else {
            throw SocketClientError.daemonNotRunning
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketClientError.connectionFailed("Could not create socket")
        }
        defer { close(fd) }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketClientError.connectionFailed("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw SocketClientError.daemonNotRunning
        }

        // Encode request as JSON + newline
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        var message = requestData
        message.append(contentsOf: [0x0A]) // newline

        // Send
        let sent = message.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress!, buffer.count, 0)
        }
        guard sent == message.count else {
            throw SocketClientError.sendFailed("Sent \(sent) of \(message.count) bytes")
        }

        // Read response (read until we get a newline or connection closes)
        var responseData = Data()
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = recv(fd, buffer, bufferSize, 0)
            if bytesRead < 0 {
                throw SocketClientError.receiveFailed("recv failed with errno \(errno)")
            }
            if bytesRead == 0 {
                break // Connection closed
            }
            responseData.append(buffer, count: bytesRead)
            // Check if we got a newline (end of JSON response)
            if responseData.contains(0x0A) {
                break
            }
        }

        // Trim trailing newline
        if let newlineIndex = responseData.firstIndex(of: 0x0A) {
            responseData = responseData[responseData.startIndex..<newlineIndex]
        }

        guard !responseData.isEmpty else {
            throw SocketClientError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RPCResponse.self, from: responseData)
    }

    /// Send an RPC request, decode the result, and throw on error response.
    func call<P: Encodable, R: Decodable>(
        method: String, params: P, resultType: R.Type
    ) throws -> R {
        let request = try RPCRequest(method: method, params: params)
        let response = try send(request)
        guard response.success else {
            throw CLIError.rpcError(response.error ?? "Unknown error")
        }
        return try response.decodeResult(resultType)
    }

    /// Send an RPC request that returns no meaningful result.
    func callVoid<P: Encodable>(method: String, params: P) throws {
        let request = try RPCRequest(method: method, params: params)
        let response = try send(request)
        guard response.success else {
            throw CLIError.rpcError(response.error ?? "Unknown error")
        }
    }

    /// Send an RPC request with no params.
    func call<R: Decodable>(method: String, resultType: R.Type) throws -> R {
        let request = RPCRequest(method: method)
        let response = try send(request)
        guard response.success else {
            throw CLIError.rpcError(response.error ?? "Unknown error")
        }
        return try response.decodeResult(resultType)
    }
}

/// General CLI errors.
enum CLIError: Error, CustomStringConvertible {
    case rpcError(String)
    case invalidArgument(String)

    var description: String {
        switch self {
        case .rpcError(let msg):
            return "Error: \(msg)"
        case .invalidArgument(let msg):
            return msg
        }
    }
}
