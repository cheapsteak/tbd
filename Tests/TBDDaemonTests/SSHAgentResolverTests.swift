import Foundation
import Testing
@testable import TBDDaemonLib
import TestSupport

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

// MARK: - Candidate discovery
//
// These drive `discoverCandidates()` directly: which sockets `resolve()` would
// probe, in what order. Every source is injected, so nothing here asks the
// real launchd, reads the real `SSH_AUTH_SOCK`, or runs `ssh-add`.

/// A fresh root under the run's scratch dir, short enough that a
/// `com.apple.launchd.*/Listeners` socket bound inside it fits darwin's
/// 104-byte `sun_path`.
private func makeDiscoveryRoot() throws -> String {
    let root = fencedScratchRoot(prefix: "ssha")
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

/// Binds `<base>/com.apple.launchd.<label>/Listeners`, laid out the way launchd
/// lays out a login session's agent socket, stamps it with `mtime`, and returns
/// its path. Nothing listens behind it: discovery only stats the file.
private func makeLaunchdListener(in base: String, label: String, mtime: Date) throws -> String {
    let dir = "\(base)/com.apple.launchd.\(label)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/Listeners"
    try #require(HolderRendezvousFixture.bindAndAbandon(at: path))
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
    return path
}

@Test func testDiscoveryFindsLaunchdSocketAlone() async {
    let launchd = "/tmp/tbd-test-launchd-\(UUID().uuidString).sock"
    let resolver = SSHAgentResolver(
        symlinkPath: "/tmp/tbd-test-link-\(UUID().uuidString).sock",
        launchdLookup: { launchd },
        inheritedSocketPath: nil,
        globBaseDirectories: []
    )
    #expect(await resolver.discoverCandidates() == [launchd])
}

@Test func testDiscoveryFindsInheritedSocketAlone() async {
    let inherited = "/tmp/tbd-test-inherited-\(UUID().uuidString).sock"
    let resolver = SSHAgentResolver(
        symlinkPath: "/tmp/tbd-test-link-\(UUID().uuidString).sock",
        launchdLookup: { nil },
        inheritedSocketPath: inherited,
        globBaseDirectories: []
    )
    #expect(await resolver.discoverCandidates() == [inherited])
}

@Test func testDiscoveryFindsGlobSocketAlone() async throws {
    let root = try makeDiscoveryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let globbed = try makeLaunchdListener(in: root, label: "A", mtime: Date())

    let resolver = SSHAgentResolver(
        symlinkPath: "\(root)/link.sock",
        launchdLookup: { nil },
        inheritedSocketPath: nil,
        globBaseDirectories: [root]
    )
    #expect(await resolver.discoverCandidates() == [globbed])
}

@Test func testDiscoveryOrdersLaunchdThenInheritedThenGlob() async throws {
    // Named so the expected order is neither ascending nor descending by path.
    let root = try makeDiscoveryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let launchd = "\(root)/from-launchd.sock"
    let inherited = "\(root)/inherited.sock"
    let globbed = try makeLaunchdListener(in: root, label: "A", mtime: Date())

    let resolver = SSHAgentResolver(
        symlinkPath: "\(root)/link.sock",
        launchdLookup: { launchd },
        inheritedSocketPath: inherited,
        globBaseDirectories: [root]
    )
    #expect(await resolver.discoverCandidates() == [launchd, inherited, globbed])
}

@Test func testDiscoveryCollapsesDuplicateCandidates() async throws {
    // On a healthy login session all three sources name the same socket:
    // launchctl prints it with a trailing newline, the inherited variable may
    // spell it differently, and the glob finds it. It is probed once, under
    // launchd's spelling.
    let root = try makeDiscoveryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let globbed = try makeLaunchdListener(in: root, label: "A", mtime: Date())
    let respelled = "\(root)/com.apple.launchd.A/../com.apple.launchd.A/Listeners"

    let resolver = SSHAgentResolver(
        symlinkPath: "\(root)/link.sock",
        launchdLookup: { globbed + "\n" },
        inheritedSocketPath: respelled,
        globBaseDirectories: [root]
    )
    #expect(await resolver.discoverCandidates() == [globbed])
}

@Test func testDiscoverySkipsInheritedSymlinkPath() async throws {
    // A daemon restarted from a TBD shell inherits SSH_AUTH_SOCK set to the
    // symlink itself, or to a link that leads to it. Repointing the symlink
    // at either would make it a loop.
    let root = try makeDiscoveryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let symlinkPath = "\(root)/link.sock"
    let alias = "\(root)/alias.sock"
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: symlinkPath)

    for inherited in [symlinkPath, alias] {
        let resolver = SSHAgentResolver(
            symlinkPath: symlinkPath,
            launchdLookup: { nil },
            inheritedSocketPath: inherited,
            globBaseDirectories: []
        )
        #expect(await resolver.discoverCandidates() == [], "inherited \(inherited)")
    }
}

@Test func testDiscoveryIgnoresEmptyAndRelativeValues() async {
    // `launchctl getenv` prints an empty line when launchd has no value, and
    // a relative path names no fixed socket.
    let cases: [(launchd: String?, inherited: String?)] = [
        (launchd: "\n", inherited: ""),
        (launchd: "agent.sock", inherited: "  "),
    ]
    for (launchd, inherited) in cases {
        let resolver = SSHAgentResolver(
            symlinkPath: "/tmp/tbd-test-link-\(UUID().uuidString).sock",
            launchdLookup: { launchd },
            inheritedSocketPath: inherited,
            globBaseDirectories: []
        )
        #expect(await resolver.discoverCandidates() == [])
    }
}

@Test func testDiscoveryGlobsEveryBaseDirectoryNewestFirst() async throws {
    // macOS 27 puts the login agent's socket under /private/var/run, where
    // earlier releases used /private/tmp. Two temp bases stand in for them,
    // with a missing one between. The newer socket sits in the later base, so
    // newest-first across bases is distinguishable from base order.
    let root = try makeDiscoveryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let tmpBase = "\(root)/t"
    let runBase = "\(root)/r"
    let now = Date()
    let older = try makeLaunchdListener(in: tmpBase, label: "Old", mtime: now.addingTimeInterval(-3600))
    let newer = try makeLaunchdListener(in: runBase, label: "New", mtime: now)

    // Neither a regular file named Listeners nor a socket outside a
    // com.apple.launchd.* directory is a candidate.
    let fileDir = "\(tmpBase)/com.apple.launchd.File"
    try FileManager.default.createDirectory(atPath: fileDir, withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: "\(fileDir)/Listeners", contents: Data()))
    let otherDir = "\(runBase)/other.X"
    try FileManager.default.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
    try #require(HolderRendezvousFixture.bindAndAbandon(at: "\(otherDir)/Listeners"))

    let resolver = SSHAgentResolver(
        symlinkPath: "\(root)/link.sock",
        launchdLookup: { nil },
        inheritedSocketPath: nil,
        globBaseDirectories: [tmpBase, "\(root)/missing", runBase]
    )
    #expect(await resolver.discoverCandidates() == [newer, older])
}

@Test func testDefaultGlobBasesCoverTmpAndVarRun() {
    #expect(SSHAgentResolver.defaultGlobBaseDirectories == ["/private/tmp", "/private/var/run"])
}
