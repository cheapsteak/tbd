import Darwin
import Foundation
import Testing
import TestSupport

@testable import TBDShared

/// The KERN_PROCARGS2 parser, run on literal buffers laid out the way the
/// kernel lays them out, plus cases that ask the real kernel. Failure
/// messages never include buffer contents: environments hold secrets.
@Suite("Process environment markers")
struct ProcessEnvironmentMarkersTests {
    /// A buffer as the kernel lays it out: argc; the exec path and its NUL,
    /// padded with NULs so the two fill a multiple of 8 bytes; argv strings;
    /// env strings; then the empty entry that ends the environment and one of
    /// the strings the kernel puts after it. Every string is NUL-terminated.
    /// With `closed` false the buffer stops after the last env string, as the
    /// kernel cuts the buffer of a process whose environment it withholds.
    private static func bytes(
        argc: Int32? = nil, exec: String = "/bin/x", argv: [String] = ["x"], env: [String],
        closed: Bool = true
    ) -> [UInt8] {
        bytes(argc: argc, exec: exec, argv: argv, envBytes: env.map { Array($0.utf8) }, closed: closed)
    }

    /// `bytes(argc:exec:argv:env:closed:)` with each env entry given as raw
    /// bytes.
    private static func bytes(
        argc: Int32? = nil, exec: String = "/bin/x", argv: [String] = ["x"], envBytes: [[UInt8]],
        closed: Bool = true
    ) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: argc ?? Int32(argv.count)) { out.append(contentsOf: $0) }
        out.append(contentsOf: Array(exec.utf8))
        out.append(0)
        while (out.count - 4) % 8 != 0 { out.append(0) }
        for arg in argv { out.append(contentsOf: Array(arg.utf8)); out.append(0) }
        for entry in envBytes { out.append(contentsOf: entry); out.append(0) }
        guard closed else { return out }
        out.append(0)
        out.append(contentsOf: Array("ptr_munge=".utf8))
        out.append(contentsOf: [0, 0, 0, 0])
        return out
    }

    /// Exec paths of 10 to 17 bytes, which with the terminator need each of
    /// the eight amounts of padding, none to seven bytes, each paired with its
    /// amount. The repeated slashes only lengthen the path: the kernel keeps
    /// it as it was given.
    static let pathsNeedingEachPadding: [(String, Int)] = [
        ("/bin/sleep", 5),
        ("/bin//sleep", 4),
        ("/bin///sleep", 3),
        ("/bin////sleep", 2),
        ("/bin/////sleep", 1),
        ("/bin//////sleep", 0),
        ("/bin///////sleep", 7),
        ("/bin////////sleep", 6),
    ]

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
        let raw = Self.bytes(envBytes: [Array("PATH=/bin".utf8), Array("TBD_WORKTREE_ID=".utf8) + [0xFF, 0xFE]])
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

    // MARK: - Where argv ends

    /// Fails against a reader that skips every NUL after the path: it takes
    /// the empty `argv[0]` for padding, steps over `env[0]` as the last
    /// argument, and loses the marker in it.
    @Test func anEmptyArgvZeroLeavesTheFirstEntryReadable() {
        let raw = Self.bytes(argv: ["", "30"], env: ["TBD_WORKTREE_ID=W", "TBD_TERMINAL_ID=T"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: "W", terminalID: "T"))
    }

    /// argv starts at the padded boundary for every amount of padding, so an
    /// empty `argv[0]` is read in place and `env[0]` stays the first entry.
    @Test("an empty argv[0] is read in place for each amount of path padding",
          arguments: pathsNeedingEachPadding)
    func anEmptyArgvZeroIsReadInPlace(exec: String, padding: Int) throws {
        let raw = Self.bytes(exec: exec, argv: ["", "30"], env: ["TBD_WORKTREE_ID=W", "PATH=/bin"])

        let layout = try #require(ProcArgsLayout(procArgs: raw))
        let argumentLengths = layout.argumentRanges.map(\.count)
        #expect(layout.argumentsStart == 4 + exec.utf8.count + 1 + padding)
        #expect(argumentLengths == [0, 2])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: "W", terminalID: nil))
    }

    /// A byte that is not NUL anywhere in the path's padding means the buffer
    /// is not the kernel's layout, so nothing in it is evidence. The last two
    /// offsets fail against a reader that skips NULs and walks on from the
    /// first byte that is not one: that reader still finds `env[0]`.
    @Test("a byte in the path's padding that is not NUL is hidden", arguments: 0..<5)
    func aByteInThePaddingIsHidden(offset: Int) {
        var raw = Self.bytes(exec: "/bin/sleep", argv: ["x"], env: ["TBD_WORKTREE_ID=W", "PATH=/bin"])
        raw[4 + "/bin/sleep".utf8.count + 1 + offset] = UInt8(ascii: "x")
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .hidden)
    }

    @Test func aBufferThatEndsBeforeArgvDoesIsHidden() {
        let whole = Self.bytes(exec: "/bin/sleep", argv: ["sleep", "30"], env: ["TBD_WORKTREE_ID=W"])
        // Inside the path's padding, bytes 15 to 19.
        #expect(ProcessEnvironmentReader.parse(procArgs: Array(whole.prefix(17))) == .hidden)
        // Inside the last argument, before its terminator.
        #expect(ProcessEnvironmentReader.parse(procArgs: Array(whole.prefix(27))) == .hidden)
    }

    @Test func aNegativeArgcIsHidden() {
        let raw = Self.bytes(argc: -1, env: ["TBD_WORKTREE_ID=W"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .hidden)
    }

    /// A process can be started with no arguments at all, and its environment
    /// then starts at the padded boundary.
    @Test func anArgcOfZeroReadsTheEnvironmentFromTheBoundary() throws {
        let raw = Self.bytes(exec: "/bin/sleep", argv: [], env: ["TBD_WORKTREE_ID=W", "TBD_TERMINAL_ID=T"])

        let layout = try #require(ProcArgsLayout(procArgs: raw))
        #expect(layout.argumentRanges.isEmpty)
        #expect(layout.environmentStart == layout.argumentsStart)
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: "W", terminalID: "T"))
    }

    /// Fails against a reader that skips every NUL after the path: it takes
    /// both empty arguments for padding and steps over both markers as the
    /// last two arguments.
    @Test func twoEmptyLeadingArgumentsAreBothArguments() {
        let raw = Self.bytes(argv: ["", "", "30"], env: ["TBD_WORKTREE_ID=W", "TBD_TERMINAL_ID=T"])
        #expect(ProcessEnvironmentReader.parse(procArgs: raw) == .markers(worktreeID: "W", terminalID: "T"))
    }

    // MARK: - Where the environment ends

    /// The kernel's buffer for a protected process with an empty `argv[0]`:
    /// cut after `env[0]`, with the terminal marker withheld behind it.
    /// Fails against a reader that takes the start of the environment for
    /// all of it, which reports the worktree marker alone.
    @Test func anEnvironmentTheBufferCutsOffIsHidden() {
        let cut = Self.bytes(argv: ["", "30"], env: ["TBD_WORKTREE_ID=W"], closed: false)
        #expect(ProcessEnvironmentReader.parse(procArgs: cut) == .hidden)

        // Ending inside an entry, before its terminator, is cut off too.
        let unterminated = Self.bytes(argv: ["x"], env: ["TBD_TERMINAL_ID=T", "TBD_WORKTREE_ID=W"], closed: false)
        #expect(ProcessEnvironmentReader.parse(procArgs: Array(unterminated.dropLast())) == .hidden)
    }

    /// The kernel's buffer for a protected process whose `argv[0]` is not
    /// empty: cut straight after argv, an empty argument later in it
    /// included.
    @Test func aBufferCutAfterArgvIsHidden() {
        let cut = Self.bytes(argv: ["sh", "", "30"], env: [], closed: false)
        #expect(ProcessEnvironmentReader.parse(procArgs: cut) == .hidden)
    }

    // MARK: - The real kernel

    @Test func aFailedCallIsHidden() {
        #expect(ProcessEnvironmentReader.markers(pid: Int32.max) == .hidden)
        #expect(ProcessEnvironmentReader.procArgs(pid: Int32.max) == nil)
    }

    /// The alarm for a kernel or libSystem change that would silently stop
    /// marker-based reclaim. The reader ends the environment at the empty
    /// entry measured after it, and the kernel does not promise that entry:
    /// it is alignment padding plus the NULs left where startup code zeroed
    /// some of the strings the kernel adds after the environment. Were it to
    /// go, every readable environment would read `.hidden`, which the
    /// orphan-process judge treats as neutral, so nothing else would fail.
    /// This test process is not a platform binary, and `scripts/test.sh`
    /// gives it a real environment, so its own environment must read as
    /// something other than `.hidden`.
    @Test func theRealCallReadsThisProcess() throws {
        let raw = try #require(ProcessEnvironmentReader.procArgs(pid: getpid()))
        #expect(raw.count > 4)
        let own = ProcessEnvironmentReader.markers(pid: getpid())
        #expect(own != .hidden)
    }

    /// The real kernel's layout, for the reader: `/bin/sleep` started with an
    /// empty `argv[0]` under exec paths that need each amount of padding, and
    /// with the worktree marker as `env[0]`. Whatever the padding, `argv[0]`
    /// sits at the padded boundary and the environment starts right after
    /// argv, at `env[0]`, or at the buffer's end when the kernel cut it there.
    ///
    /// `/bin/sleep` is an Apple platform binary, and the kernel withholds such
    /// a process's environment by cutting the buffer after argv. Measured on
    /// macOS 27, it finds argv by skipping every NUL after the executable
    /// path, so an empty `argv[0]` merges with the padding there and the cut
    /// lands one string late: the buffer holds the worktree marker and ends
    /// before the terminal one. A kernel that counts argv from the boundary
    /// cuts right after it instead, and leaves no entry at all. The reader
    /// calls either `.hidden`: the environment is cut off. A kernel that gives
    /// the whole environment shows both markers.
    ///
    /// Only this test's own environment is in the child, and the buffer is
    /// still never part of a failure message.
    @Test("a real process started with an empty argv[0] has its environment start right after argv",
          arguments: pathsNeedingEachPadding)
    func aRealProcesssEnvironmentStartsRightAfterArgv(path: String, padding: Int) throws {
        let worktree = UUID().uuidString
        let terminal = UUID().uuidString
        let worktreeEntry = "\(ProcessEnvironmentReader.worktreeKey)=\(worktree)"
        let child = try ExactArgvChild(
            path: path, argv: ["", "30"],
            environment: [worktreeEntry, "\(ProcessEnvironmentReader.terminalKey)=\(terminal)"])
        defer { child.end() }

        let read = ProcessEnvironmentReader.procArgs(pid: child.pid)
        let raw = try #require(read)
        let parsed = ProcArgsLayout(procArgs: raw)
        let layout = try #require(parsed)
        let argumentLengths = layout.argumentRanges.map(\.count)
        #expect(layout.argumentsStart == 4 + path.utf8.count + 1 + padding)
        #expect(argumentLengths == [0, 2])
        let startsAtTheFirstEntry = raw[layout.environmentStart...]
            .starts(with: Array(worktreeEntry.utf8) + [0])
        let cutRightAfterArgv = layout.environmentStart == raw.count
        #expect(startsAtTheFirstEntry || cutRightAfterArgv)

        let markers = ProcessEnvironmentReader.markers(pid: child.pid)
        let whole = ProcessEnvironmentMarkers.markers(worktreeID: worktree, terminalID: terminal)
        #expect(markers == .hidden || markers == whole)
    }
}
