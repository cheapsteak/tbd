/// Where argc, argv and the start of the environment lie in a
/// `sysctl(KERN_PROCARGS2)` buffer, as byte offsets into it.
///
/// The buffer is laid out as the kernel writes it:
///
/// 1. a native-endian `Int32` argc;
/// 2. the executable path and its NUL terminator, padded with NULs so that
///    the path and its terminator fill a whole number of `pathAlignment`
///    bytes, which puts argv at `4 + roundup(pathLength + 1, 8)`;
/// 3. `argc` NUL-terminated arguments;
/// 4. the environment, as NUL-terminated `KEY=value` strings.
///
/// argv starts at that boundary and nowhere else. An empty `argv[0]` is a
/// single NUL there, so its bytes look like padding and only its offset tells
/// it apart: a reader that skips every NUL after the path takes it for
/// padding, steps over `env[0]` as the last argument, and reads every later
/// string one place early. A byte that is not NUL between the path's
/// terminator and the boundary means the buffer is not this layout.
///
/// The layout is exec's: it saves the executable path padded to a pointer's
/// size ahead of the argument and environment strings, and
/// `sysctl(KERN_PROCARGS2)` copies that area out behind argc. Tests that start
/// a process with an empty `argv[0]`, under paths that need each amount of
/// padding, pin it against the real kernel.
///
/// This type holds offsets and nothing else. It never builds a `String`, so
/// each caller decides which bytes, if any, become text, and it never walks
/// the environment: `environmentStart` is only where the environment begins.
/// `ProcessEnvironmentReader` and the daemon's leftover tmux server probe both
/// read the buffer through it.
public struct ProcArgsLayout: Sendable, Equatable {
    /// What the kernel pads the executable path to: the size of a pointer,
    /// 8 bytes for every process on a Mac TBD runs on.
    public static let pathAlignment = 8

    /// The offset of `argv[0]`: the boundary the executable path is padded
    /// to.
    public let argumentsStart: Int

    /// Each argument's bytes, without its terminator, in argv order. There
    /// are exactly as many as the buffer's argc, which is never negative here.
    public let argumentRanges: [Range<Int>]

    /// The offset just past the last argument's terminator, where the
    /// environment begins: `argumentsStart` when argc is zero, and the
    /// buffer's count when the buffer ends there.
    public let environmentStart: Int

    /// The layout of `raw`, or nil when `raw` is too short to hold argc,
    /// claims a negative argc, has no terminator after the executable path,
    /// has a byte that is not NUL in the path's padding or ends inside it, or
    /// ends before argv does.
    public init?(procArgs raw: [UInt8]) {
        guard raw.count >= 4 else { return nil }
        let argc = raw.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        guard let pathEnd = raw[4...].firstIndex(of: 0) else { return nil }
        let alignment = Self.pathAlignment
        let paddedPathLength = (pathEnd + 1 - 4 + alignment - 1) / alignment * alignment
        let argumentsStart = 4 + paddedPathLength
        guard argumentsStart <= raw.count,
              raw[pathEnd..<argumentsStart].allSatisfy({ $0 == 0 }) else { return nil }

        // No capacity is reserved from argc: a malformed buffer can claim any
        // count, and the walk below ends at the buffer's end whatever it says.
        var ranges: [Range<Int>] = []
        var position = argumentsStart
        for _ in 0..<Int(argc) {
            guard position < raw.count,
                  let end = raw[position...].firstIndex(of: 0) else { return nil }
            ranges.append(position..<end)
            position = end + 1
        }
        self.argumentsStart = argumentsStart
        self.argumentRanges = ranges
        self.environmentStart = position
    }
}
