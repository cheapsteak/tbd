import Darwin
import Foundation

/// What another process's environment says about which TBD terminal it was
/// started under.
///
/// Three outcomes, not two, because "I could not look" and "I looked and the
/// markers are not there" justify opposite actions: a sweep that treats an
/// unreadable environment as a negative would reclaim processes it never
/// examined, and one that treats it as a positive would never reclaim
/// anything. `.hidden` is the first of those; it carries no evidence either
/// way.
public enum ProcessEnvironmentMarkers: Sendable, Equatable {
    /// At least one of the two markers was present with a non-empty value.
    case markers(worktreeID: String?, terminalID: String?)
    /// The environment was readable and holds neither marker.
    case noMarkers
    /// The environment could not be read: the call failed, the process is
    /// protected, or the buffer held no environment entries at all.
    case hidden
}

/// Reads `TBD_WORKTREE_ID` and `TBD_TERMINAL_ID` from a process's environment
/// through `sysctl(KERN_PROCARGS2)`.
///
/// **Environments hold secrets, so the parser reads bytes and keeps nothing
/// else.** It never builds a `String` for any entry other than the two marker
/// keys' values, never retains the buffer past `parse`, and never logs. A
/// caller cannot ask it for anything it does not need.
///
/// Layout of the buffer (the same one `docs/research/2026-10-30-herdr/procenv_probe.py`
/// parses): a native-endian `Int32` argc, the executable path and its NUL
/// terminator, NUL padding, `argc` NUL-terminated argv strings, then the
/// environment as NUL-terminated `KEY=value` strings.
public enum ProcessEnvironmentReader {
    public static let worktreeKey = "TBD_WORKTREE_ID"
    public static let terminalKey = "TBD_TERMINAL_ID"

    private static let worktreePrefix = Array((worktreeKey + "=").utf8)
    private static let terminalPrefix = Array((terminalKey + "=").utf8)

    /// The raw `KERN_PROCARGS2` buffer for `pid`, or nil when the kernel
    /// refuses (no such process, not permitted, or a process it hides).
    public static func procArgs(pid: pid_t) -> [UInt8]? {
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        let sized = argmaxMib.withUnsafeMutableBufferPointer { mib in
            sysctl(mib.baseAddress, 2, &argmax, &argmaxSize, nil, 0)
        }
        // A failed sizing call falls back to the 1 MiB the kernel has long
        // used as its default; the real read below still reports its own errors.
        let capacity = (sized == 0 && argmax > 0) ? Int(argmax) : 1 << 20

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var buffer = [UInt8](repeating: 0, count: capacity)
        var size = capacity
        let rc = mib.withUnsafeMutableBufferPointer { name in
            buffer.withUnsafeMutableBytes { out in
                sysctl(name.baseAddress, 3, out.baseAddress, &size, nil, 0)
            }
        }
        guard rc == 0, size >= 0, size <= capacity else { return nil }
        return Array(buffer[0..<size])
    }

    /// Extract the two markers from a `KERN_PROCARGS2` buffer.
    ///
    /// Only an entry whose key is exactly one of the two names counts; the
    /// first occurrence wins; an empty value counts as absent. A buffer too
    /// short to hold argc, one that ends before argv does, and one with zero
    /// environment entries are all `.hidden` — a live process always has at
    /// least `PATH`-like entries, so none means the kernel withheld them.
    public static func parse(procArgs raw: [UInt8]) -> ProcessEnvironmentMarkers {
        guard raw.count >= 4 else { return .hidden }
        let argc = raw.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return .hidden }

        var pos = 4
        // Executable path.
        guard let execEnd = nextNul(in: raw, from: pos) else { return .hidden }
        pos = execEnd
        // The padding after the path cannot be told from an empty argv[0], so
        // an empty argv[0] is skipped along with it; argv content is never
        // inspected, only stepped over.
        while pos < raw.count, raw[pos] == 0 { pos += 1 }

        for _ in 0..<Int(argc) {
            guard let end = nextNul(in: raw, from: pos) else { return .hidden }
            pos = end + 1
        }

        var entries = 0
        var worktree: String?
        var terminal: String?
        while pos < raw.count {
            guard let end = nextNul(in: raw, from: pos), end > pos else { break }
            entries += 1
            if worktree == nil, let value = value(in: raw, pos..<end, after: worktreePrefix) {
                worktree = value
            } else if terminal == nil, let value = value(in: raw, pos..<end, after: terminalPrefix) {
                terminal = value
            }
            pos = end + 1
        }

        if entries == 0 { return .hidden }
        if worktree == nil && terminal == nil { return .noMarkers }
        return .markers(worktreeID: worktree, terminalID: terminal)
    }

    /// Read `pid`'s markers. An unreadable process is `.hidden`.
    public static func markers(pid: pid_t) -> ProcessEnvironmentMarkers {
        guard let raw = procArgs(pid: pid) else { return .hidden }
        return parse(procArgs: raw)
    }

    private static func nextNul(in raw: [UInt8], from start: Int) -> Int? {
        guard start <= raw.count else { return nil }
        return raw[start...].firstIndex(of: 0)
    }

    /// The non-empty value of the entry in `range` when it starts with
    /// `prefix` (`KEY=`), else nil. Compares bytes; builds a `String` only for
    /// a matching entry's value.
    ///
    /// A value that is not valid UTF-8 is nil, the same as an absent one.
    /// TBD writes these markers as UUID strings, so such a value was never
    /// TBD's, and repairing it into replacement characters would hand the
    /// judge a marker that names nothing. Absent is the side that keeps: a
    /// readable environment whose markers are all absent reads `.noMarkers`.
    private static func value(in raw: [UInt8], _ range: Range<Int>, after prefix: [UInt8]) -> String? {
        guard range.count > prefix.count else { return nil }
        for (offset, byte) in prefix.enumerated() where raw[range.lowerBound + offset] != byte {
            return nil
        }
        return String(bytes: raw[(range.lowerBound + prefix.count)..<range.upperBound], encoding: .utf8)
    }
}
