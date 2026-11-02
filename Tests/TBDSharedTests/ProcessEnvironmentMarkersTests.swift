import Darwin
import Foundation
import Testing

@testable import TBDShared

/// The KERN_PROCARGS2 parser, run on literal buffers laid out the way the
/// kernel lays them out, plus two cases that ask the real kernel. Failure
/// messages never include buffer contents: environments hold secrets.
@Suite("Process environment markers")
struct ProcessEnvironmentMarkersTests {
    /// A buffer as the kernel lays it out: argc, exec path, two NULs of
    /// padding, argv strings, then env strings (each NUL-terminated).
    private static func bytes(
        argc: Int32? = nil, exec: String = "/bin/x", argv: [String] = ["x"], env: [String]
    ) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: argc ?? Int32(argv.count)) { out.append(contentsOf: $0) }
        out.append(contentsOf: Array(exec.utf8))
        out.append(contentsOf: [0, 0])
        for arg in argv { out.append(contentsOf: Array(arg.utf8)); out.append(0) }
        for entry in env { out.append(contentsOf: Array(entry.utf8)); out.append(0) }
        return out
    }

    @Test func bothMarkersAreRead() {
        let raw = Self.bytes(env: ["PATH=/bin", "TBD_WORKTREE_ID=W", "SECRET=s", "TBD_TERMINAL_ID=T"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: "W", terminalID: "T"))
    }

    @Test func oneMarkerIsEnough() {
        let raw = Self.bytes(env: ["TBD_TERMINAL_ID=T"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: nil, terminalID: "T"))
    }

    @Test func readableWithoutMarkersIsNoMarkers() {
        let raw = Self.bytes(env: ["PATH=/bin", "HOME=/h"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .noMarkers)
    }

    @Test func zeroEntriesIsHidden() {
        #expect(ProcessEnvironmentReader.parse(procArgs: Self.bytes(env: [])) == .hidden)
    }

    @Test func aShortBufferIsHidden() {
        #expect(ProcessEnvironmentReader.parse(procArgs: []) == .hidden)
        #expect(ProcessEnvironmentReader.parse(procArgs: [1, 0]) == .hidden)
    }

    @Test func argvIsNeverReadAsEnvironment() {
        let raw = Self.bytes(argv: ["x", "TBD_WORKTREE_ID=FORGED"], env: ["PATH=/bin"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .noMarkers)
    }

    @Test func anEmptyValueIsAbsent() {
        let raw = Self.bytes(env: ["TBD_WORKTREE_ID=", "PATH=/bin"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .noMarkers)
    }

    /// Fails against a lossy decode, which repairs the value into replacement
    /// characters and reports a marker TBD never wrote.
    @Test func aValueThatIsNotUTF8IsAbsent() {
        var raw = Self.bytes(env: ["PATH=/bin"])
        raw.append(contentsOf: Array("TBD_WORKTREE_ID=".utf8) + [0xFF, 0xFE, 0])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .noMarkers)
    }

    @Test func theWholeKeyMustMatch() {
        let raw = Self.bytes(env: ["XTBD_WORKTREE_ID=W", "TBD_WORKTREE_ID_OLD=W", "PATH=/bin"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .noMarkers)
    }

    @Test func theFirstOccurrenceWins() {
        let raw = Self.bytes(env: ["TBD_WORKTREE_ID=first", "TBD_WORKTREE_ID=second"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: "first", terminalID: nil))
    }

    @Test func aFailedCallIsHidden() {
        #expect(ProcessEnvironmentReader.markers(pid: Int32.max) == .hidden)
        #expect(ProcessEnvironmentReader.procArgs(pid: Int32.max) == nil)
    }

    @Test func theRealCallReadsThisProcess() throws {
        let raw = try #require(ProcessEnvironmentReader.procArgs(pid: getpid()))
        #expect(raw.count > 4)
    }
}
