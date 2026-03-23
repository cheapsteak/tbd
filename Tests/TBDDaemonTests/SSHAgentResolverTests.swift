import Foundation
import Testing
@testable import TBDDaemonLib

@Test func testIsValidReturnsFalseForNonexistentSymlink() {
    let resolver = SSHAgentResolver(
        symlinkPath: "/tmp/tbd-test-nonexistent-\(UUID().uuidString).sock"
    )
    #expect(!resolver.isValid())
}

@Test func testIsValidReturnsTrueForLiveSocket() throws {
    // Create a real Unix domain socket
    let socketPath = "/tmp/tbd-test-\(UUID().uuidString).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer {
        close(fd)
        unlink(socketPath)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
            rawPathPtr.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
        }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindResult == 0)
    listen(fd, 1)

    // Create symlink pointing to the socket
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: socketPath
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(symlinkPath: symlinkPath)
    #expect(resolver.isValid())
}

@Test func testIsValidReturnsFalseForStaleSocket() throws {
    // Create symlink pointing to a nonexistent socket
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: "/tmp/tbd-nonexistent-socket"
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(symlinkPath: symlinkPath)
    #expect(!resolver.isValid())
}
