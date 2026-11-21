import Foundation
import TBDShared
import os

/// Files under the daemon's runtime directory (`TBDConstants.runtimeDir`)
/// that no current build writes. The daemon removes them at startup so copies
/// left by an older build don't accumulate; no other sweep matches them.
///
/// Four kinds, each matched exactly:
///
/// - `statusline-tee.sh` — a shared statusline tee script.
/// - `statusline-capture-<key>.json` — one session's capture from that script,
///   and its publish temp `statusline-capture-<key>.json.<pid>.tmp.json`.
///   `<key>` is a sanitized session key (`[A-Za-z0-9_-]`, see
///   `TBDConstants.sanitizedSessionKey`) and `<pid>` is decimal. A name of any
///   other shape is left alone, so nothing else in the directory can match.
/// - `nightwatch-leases/` — a directory of lease credential files, removed
///   with its contents.
/// - `continue-in-claude-packet-<terminal>-<request>.txt` — a continuation
///   packet Continue in Claude staged for a launching shell to read.
///   `<terminal>` and `<request>` are UUIDs; a name of any other shape is left
///   alone.
///
/// Idempotent and non-fatal: an absent directory or file is no change, and a
/// removal that fails is logged and skipped without stopping the others.
struct RetiredRuntimeFiles {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "startup")

    static let teeScriptName = "statusline-tee.sh"
    static let leaseCredentialDirectoryName = "nightwatch-leases"
    static let capturePrefix = "statusline-capture-"
    static let captureSuffix = ".json"
    static let packetPrefix = "continue-in-claude-packet-"
    static let packetSuffix = ".txt"

    let runtimeDir: URL

    init(runtimeDir: URL = TBDConstants.runtimeDir) {
        self.runtimeDir = runtimeDir
    }

    /// Remove every retired file present in `runtimeDir`.
    ///
    /// - Returns: how many entries were removed — a directory counts once.
    ///   Zero means there was nothing to remove or every removal failed.
    @discardableResult
    func removeAll() -> Int {
        let fm = FileManager.default
        var names = [Self.teeScriptName, Self.leaseCredentialDirectoryName]
        if let entries = try? fm.contentsOfDirectory(atPath: runtimeDir.path) {
            names += entries.filter(Self.isStatuslineCapture).sorted()
            names += entries.filter(Self.isContinuationPacket).sorted()
        }

        var removed = 0
        for name in names {
            let path = runtimeDir.appendingPathComponent(name).path
            // `attributesOfItem` does not follow a symlink, so a link is seen
            // (and removed) as the link itself.
            guard (try? fm.attributesOfItem(atPath: path)) != nil else { continue }
            do {
                try fm.removeItem(atPath: path)
                removed += 1
                Self.logger.info("Removed retired runtime file \(path, privacy: .public)")
            } catch {
                Self.logger.error(
                    "Failed to remove retired runtime file \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return removed
    }

    /// Whether `name` is a statusline capture or its publish temp:
    /// `statusline-capture-<key>.json` or
    /// `statusline-capture-<key>.json.<pid>.tmp.json`.
    static func isStatuslineCapture(_ name: String) -> Bool {
        guard name.hasPrefix(capturePrefix), name.hasSuffix(captureSuffix),
              name.count > capturePrefix.count + captureSuffix.count
        else { return false }
        let middle = name.dropFirst(capturePrefix.count).dropLast(captureSuffix.count)
        let parts = middle.split(separator: ".", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return isSessionKey(parts[0])
        case 4:
            return isSessionKey(parts[0]) && parts[1] == "json"
                && isDecimal(parts[2]) && parts[3] == "tmp"
        default:
            return false
        }
    }

    /// Whether `name` is a continuation packet:
    /// `continue-in-claude-packet-<terminal>-<request>.txt`, both UUIDs.
    static func isContinuationPacket(_ name: String) -> Bool {
        guard name.hasPrefix(packetPrefix), name.hasSuffix(packetSuffix) else { return false }
        let middle = Array(name.dropFirst(packetPrefix.count).dropLast(packetSuffix.count))
        let uuidLength = 36
        guard middle.count == uuidLength * 2 + 1, middle[uuidLength] == "-" else { return false }
        return UUID(uuidString: String(middle[..<uuidLength])) != nil
            && UUID(uuidString: String(middle[(uuidLength + 1)...])) != nil
    }

    /// A key is sanitized exactly when sanitizing it changes nothing — one
    /// implementation of the character set, shared with every path builder.
    private static func isSessionKey(_ text: Substring) -> Bool {
        let key = String(text)
        return !key.isEmpty && TBDConstants.sanitizedSessionKey(key) == key
    }

    private static func isDecimal(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}
