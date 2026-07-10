import Foundation

/// Shared disk-usage measurement for the orphan-GC collectors.
enum GCDiskUsage {
    /// `du -sk`'s apparent-size measurement for `path`, in bytes (the
    /// reported KB * 1024). `nil` on any failure — spawn error, non-zero
    /// exit, timeout, or unparseable output — since a missing byte count is
    /// never worth blocking or retrying a reap over.
    static func apparentBytes(path: String) async -> Int64? {
        guard let outcome = try? await runBoundedProcess(
            executable: "/usr/bin/du", arguments: ["-sk", path], currentDirectory: nil, timeout: .seconds(60)
        ) else {
            return nil
        }
        guard case .completed(let status, let stdout, _) = outcome, status == 0 else { return nil }
        guard let text = String(data: stdout, encoding: .utf8) else { return nil }
        guard let firstToken = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first,
            let kilobytes = Int64(firstToken)
        else {
            return nil
        }
        return kilobytes * 1024
    }
}
