import Foundation
import Testing
@testable import TBDDaemonLib

@Test func testIsValidReturnsFalseForNonexistentSymlink() async {
    let resolver = SSHAgentResolver(
        symlinkPath: "/tmp/tbd-test-nonexistent-\(UUID().uuidString).sock"
    )
    #expect(!(await resolver.isValid()))
}

@Test func testIsValidReturnsFalseForZombieSocket() async throws {
    // Regression: a Unix socket that accepts connect(2) but does not speak the
    // SSH agent protocol (e.g. a stale launchd Listeners socket) must be
    // rejected. Otherwise the periodic refresh skips re-resolving and the
    // tbd-agent.sock symlink remains pointed at a dead agent.
    let socketPath = "/tmp/tbd-test-zombie-\(UUID().uuidString).sock"
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

    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: socketPath
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(symlinkPath: symlinkPath)
    #expect(!(await resolver.isValid()))
}

@Test func testIsValidReturnsFalseForStaleSocket() async throws {
    // Create symlink pointing to a nonexistent socket
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: "/tmp/tbd-nonexistent-socket"
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(symlinkPath: symlinkPath)
    #expect(!(await resolver.isValid()))
}

@Test func testResolveFindsLiveSocket() async throws {
    let socketPath = "/tmp/tbd-test-agent-\(UUID().uuidString).sock"
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

    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(
        symlinkPath: symlinkPath,
        candidatePaths: [socketPath]
    )
    let result = await resolver.resolve()
    #expect(result)

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)
    #expect(target == socketPath)
    // Note: isValid() is intentionally not asserted here — the strengthened
    // check requires a real ssh-agent responding to ssh-add -l, which a plain
    // bound socket cannot satisfy. See testIsValidReturnsFalseForZombieSocket.
}

@Test func testResolveReturnsFalseWhenNoLiveSocket() async {
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(
        symlinkPath: symlinkPath,
        candidatePaths: ["/tmp/nonexistent-socket-1", "/tmp/nonexistent-socket-2"]
    )
    let result = await resolver.resolve()
    #expect(!result)
}

@Test func testResolveUpdatesStaleSymlink() async throws {
    let stalePath = "/tmp/tbd-test-stale-\(UUID().uuidString).sock"
    let livePath = "/tmp/tbd-test-live-\(UUID().uuidString).sock"

    let liveFd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(liveFd >= 0)
    defer {
        close(liveFd)
        unlink(livePath)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    livePath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
            rawPathPtr.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
        }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(liveFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindResult == 0)
    listen(liveFd, 1)

    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: stalePath
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(
        symlinkPath: symlinkPath,
        candidatePaths: [stalePath, livePath]
    )
    let result = await resolver.resolve()
    #expect(result)

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)
    #expect(target == livePath)
}
