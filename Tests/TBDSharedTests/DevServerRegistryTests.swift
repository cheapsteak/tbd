import Foundation
import Testing

@testable import TBDShared

/// A probe whose answers the test chooses.
///
/// The states that decide this feature — a reused pid, a process that exited
/// without being reaped — cannot be produced on demand from a test process, and
/// getting them wrong means telling someone their worktree is safe to archive
/// when it is not (or nagging them when it is).
private struct StubProbe: DevServerProcessProbe {
    var starts: [Int32: Int] = [:]
    var zombies: Set<Int32> = []

    func startEpoch(pid: Int32) -> Int? { starts[pid] }
    func isZombie(pid: Int32) -> Bool { zombies.contains(pid) }
}

private func writeRecord(
    in directory: URL,
    name: String,
    version: Int = 1,
    label: String = "dev",
    root: String,
    command: String = "start the dev server",
    pid: Int = 4242,
    startEpoch: Int = 1_700_000_000
) throws {
    let json = """
        {
          "version": \(version),
          "label": "\(label)",
          "root": "\(root)",
          "command": "\(command)",
          "proc": { "pid": \(pid), "start_epoch": \(startEpoch) },
          "stop": []
        }
        """
    try json.write(
        to: directory.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev-servers-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Liveness

@Test func matchingPidAndStartTimeIsRunning() {
    let probe = StubProbe(starts: [4242: 1_700_000_000])
    #expect(
        DevServerRegistry.liveness(pid: 4242, startEpoch: 1_700_000_000, probe: probe) == .running)
}

@Test func absentPidIsStale() {
    #expect(
        DevServerRegistry.liveness(pid: 4242, startEpoch: 1_700_000_000, probe: StubProbe())
            == .stale)
}

/// The identity is the pair, not the pid. A live pid that started at a different
/// time is a different process, and treating it as the recorded one is how a
/// `.pid`-file scheme ends up pointing at a stranger.
@Test func reusedPidIsStaleNotRunning() {
    let probe = StubProbe(starts: [4242: 1_700_000_000 + 86_400])
    #expect(
        DevServerRegistry.liveness(pid: 4242, startEpoch: 1_700_000_000, probe: probe) == .stale)
}

/// A zombie still reports its original start time, so the pair alone reads a
/// dead server as running forever.
@Test func zombieIsStale() {
    let probe = StubProbe(starts: [4242: 1_700_000_000], zombies: [4242])
    #expect(
        DevServerRegistry.liveness(pid: 4242, startEpoch: 1_700_000_000, probe: probe) == .stale)
}

/// Implementations may truncate or round when deriving whole seconds. A
/// one-second disagreement must not report every live server as dead.
@Test func oneSecondOfSkewIsStillRunning() {
    let probe = StubProbe(starts: [4242: 1_700_000_001])
    #expect(
        DevServerRegistry.liveness(pid: 4242, startEpoch: 1_700_000_000, probe: probe) == .running)
}

@Test func missingIdentityIsIndeterminate() {
    let probe = StubProbe(starts: [4242: 1_700_000_000])
    #expect(DevServerRegistry.liveness(pid: nil, startEpoch: 1, probe: probe) == .indeterminate)
    #expect(DevServerRegistry.liveness(pid: 4242, startEpoch: nil, probe: probe) == .indeterminate)
}

/// A future record's fields cannot be interpreted, so nothing may be concluded
/// from them — least of all that the thing it describes is gone.
@Test func unknownSchemaVersionIsIndeterminateNotStale() {
    let record = DevServerRecord(
        version: 99, label: "dev", root: "/tmp/x", command: "", pid: 4242,
        startEpoch: 1_700_000_000)
    #expect(DevServerRegistry.liveness(of: record, probe: StubProbe()) == .indeterminate)
}

// MARK: - Decoding

@Test func malformedRecordsDoNotDecode() {
    #expect(DevServerRecord.decode(from: Data("not json".utf8)) == nil)
    #expect(DevServerRecord.decode(from: Data(#"{"version": 1}"#.utf8)) == nil)
}

@Test func recordDecodesItsFields() throws {
    let json = """
        {"version":1,"label":"dev","root":"/tmp/wt","command":"display only",
         "proc":{"pid":7,"start_epoch":123}}
        """
    let record = try #require(DevServerRecord.decode(from: Data(json.utf8)))
    #expect(record.label == "dev")
    #expect(record.root == "/tmp/wt")
    #expect(record.command == "display only")
    #expect(record.pid == 7)
    #expect(record.startEpoch == 123)
}

// MARK: - Selecting what would be stranded by an archive

@Test func runningInWorktreeFindsOnlyThatWorktree() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeRecord(in: dir, name: "a", label: "mine", root: "/tmp/wt-a")
    try writeRecord(in: dir, name: "b", label: "theirs", root: "/tmp/wt-b", pid: 5151)

    let registry = DevServerRegistry(
        probe: StubProbe(starts: [4242: 1_700_000_000, 5151: 1_700_000_000]))
    let running = registry.running(inWorktree: "/tmp/wt-a", directory: dir)

    #expect(running.map(\.label) == ["mine"])
}

/// Only `running` counts. A definitively-dead record describes nothing that an
/// archive could strand, and one that cannot be read is not evidence either —
/// warning on those trains people to click through the warning.
@Test func staleAndIndeterminateRecordsAreNotReportedAsRunning() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeRecord(in: dir, name: "gone", label: "gone", root: "/tmp/wt", pid: 1111)
    try writeRecord(
        in: dir, name: "future", version: 99, label: "future", root: "/tmp/wt", pid: 2222)
    try "not json".write(
        to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

    // No pid is alive.
    let registry = DevServerRegistry(probe: StubProbe())
    #expect(registry.running(inWorktree: "/tmp/wt", directory: dir).isEmpty)

    // …but all three are still visible in the full listing, so a malformed
    // record is never silently indistinguishable from no record at all.
    #expect(registry.all(directory: dir).count == 3)
}

/// A record is written with a fully-resolved root while a worktree path can
/// arrive through a symlinked ancestor. Comparing the raw strings would report
/// "nothing running" for every worktree under such a path — the failure would
/// look exactly like the feature working.
@Test func worktreePathsAreComparedAfterResolvingSymlinks() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let real = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-real-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: real) }

    let link = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: link) }

    try writeRecord(in: dir, name: "a", label: "dev", root: real.resolvingSymlinksInPath().path)

    let registry = DevServerRegistry(probe: StubProbe(starts: [4242: 1_700_000_000]))
    #expect(registry.running(inWorktree: link.path, directory: dir).map(\.label) == ["dev"])
}

@Test func anAbsentRegistryDirectoryIsEmptyNotAnError() {
    let registry = DevServerRegistry(probe: StubProbe())
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("definitely-absent-\(UUID().uuidString)")
    #expect(registry.all(directory: missing).isEmpty)
    #expect(registry.running(inWorktree: "/tmp/wt", directory: missing).isEmpty)
}

// MARK: - Location

@Test func directoryHonoursXDGStateHome() {
    let url = DevServerRegistry.directory(
        environment: ["XDG_STATE_HOME": "/tmp/state"],
        home: URL(fileURLWithPath: "/tmp/test-home"))
    #expect(url.path == "/tmp/state/dev-servers")
}

@Test func directoryFallsBackToTheHomeDefault() {
    let url = DevServerRegistry.directory(
        environment: [:], home: URL(fileURLWithPath: "/tmp/test-home"))
    #expect(url.path == "/tmp/test-home/.local/state/dev-servers")
}

/// An empty value is not a value. Treating it as one yields `/dev-servers` at
/// the filesystem root, which silently reads nothing forever.
@Test func directoryIgnoresAnEmptyXDGStateHome() {
    let url = DevServerRegistry.directory(
        environment: ["XDG_STATE_HOME": ""], home: URL(fileURLWithPath: "/tmp/test-home"))
    #expect(url.path == "/tmp/test-home/.local/state/dev-servers")
}

// MARK: - The real probe is wired to the kernel

/// The stub above is what makes the interesting cases reachable; this is what
/// stops the suite passing against a probe that answers `nil` for everything.
@Test func realProbeAnswersForThisProcessAndNotForAnUnallocatablePid() {
    let probe = SysctlDevServerProbe()
    let mine = probe.startEpoch(pid: ProcessInfo.processInfo.processIdentifier)
    #expect(mine != nil)
    if let mine {
        #expect(mine <= Int(Date().timeIntervalSince1970))
    }
    #expect(probe.isZombie(pid: ProcessInfo.processInfo.processIdentifier) == false)
    #expect(probe.startEpoch(pid: 4_194_303) == nil)
}
