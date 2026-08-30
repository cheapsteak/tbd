import Foundation
import os
import TBDShared

/// Persists stack samples from hang events to disk in `~/Library/Logs/TBD/hang-stacks/`.
/// One file per hang event. Supports appending resamples during sustained hangs.
final class HangStackWriter: @unchecked Sendable {
    static let shared = HangStackWriter()

    private static let logger = Logger(subsystem: "com.tbd.app", category: "hang-stack-writer")

    /// Directory where hang stack files are written.
    private let baseDir: URL

    /// URL of the currently open hang file, if any.
    private var currentHangFileURL: URL?

    /// Handle to the current hang file for appending.
    private var currentFileHandle: FileHandle?

    /// Whether the write-time retention cap is armed. Mirrors the daemon's
    /// `Config.gcHangStacksEnabled`, pushed in by `AppState`.
    ///
    /// Starts `false` and stays `false` whenever the daemon is unreachable —
    /// the keep-biased direction, and the same answer the unset column gives.
    private var retentionEnabled = false

    /// Lock protecting the file handle, the URL, and `retentionEnabled`.
    private let lock = OSAllocatedUnfairLock<()>(initialState: ())

    init(baseDir: URL? = nil) {
        // The default comes from `HangStackRetention` rather than being derived
        // here, so this writer and the daemon's `HangStackCollector` can never
        // end up bounding two different directories.
        self.baseDir = baseDir ?? HangStackRetention.defaultBaseDirectory
    }

    /// Arm or disarm the write-time retention cap. Called by `AppState` with
    /// the daemon's resolved `Config.gcHangStacksEnabled`, on launch and on
    /// every config-change delta.
    func setRetentionEnabled(_ enabled: Bool) {
        lock.withLock { retentionEnabled = enabled }
    }

    deinit {
        try? currentFileHandle?.close()
    }

    /// Begin a new hang file with the initial sample.
    /// Returns the URL written, or nil on failure.
    func recordHangStart(stallMs: UInt64, snapshot: HangWatchdogSnapshot, frames: [MainThreadSampler.Frame]) -> URL? {
        // Close any previous hang file with a superseded marker.
        recordHangSuperseded()

        // Create the hang-stacks directory if needed.
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create hang-stacks directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Generate filename: hang-<yyyy-MM-dd-HHmmss>-<pid>.txt
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime, .withTimeZone]
        let timestamp = formatter.string(from: Date())
        // Extract just the date and time portion without timezone.
        let dateTimeOnly = timestamp.split(separator: "T").joined(separator: "-")
            .replacingOccurrences(of: ":", with: "")
        let pid = ProcessInfo.processInfo.processIdentifier
        let filename = "hang-\(dateTimeOnly)-\(pid).txt"

        let fileURL = baseDir.appendingPathComponent(filename)

        // Write the header.
        var content = ""
        content += "=== TBD Hang Stack Sample ===\n"
        content += "Timestamp: \(Date())\n"
        content += "PID: \(pid)\n"
        content += "Stall duration: \(stallMs) ms\n"
        content += "\nApp Context:\n"
        content += "  Focused terminal: \(snapshot.focusedTerminalIDShort ?? "-")\n"
        content += "  Pane: \(snapshot.paneLabel ?? "-")\n"
        content += "  Item count: \(snapshot.transcriptItemCount ?? -1)\n"
        content += "\nMain Thread Stack:\n"
        content += MainThreadSampler.format(frames)
        content += "\n\n"

        do {
            if let data = content.data(using: .utf8) {
                try data.write(to: fileURL, options: [.atomic])
            }

            let opened: URL? = lock.withLock { () in
                do {
                    currentHangFileURL = fileURL
                    currentFileHandle = try FileHandle(forWritingTo: fileURL)
                    Self.logger.info("Recorded hang start to \(fileURL.lastPathComponent, privacy: .public)")
                    return fileURL
                } catch {
                    Self.logger.error("Failed to open hang file for writing: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            guard let opened else { return nil }
            trimToRetentionCap(keeping: opened)
            return opened
        } catch {
            Self.logger.error("Failed to write hang stack: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Append a resample to the current open hang file. No-op if no current file.
    func recordResample(elapsedMs: UInt64, frames: [MainThreadSampler.Frame]) {
        lock.withLock {
            guard let fileHandle = currentFileHandle else {
                return
            }

            var content = ""
            content += "\n--- Resample at +\(elapsedMs) ms ---\n"
            content += MainThreadSampler.format(frames)
            content += "\n"

            if let data = content.data(using: .utf8) {
                do {
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                } catch {
                    Self.logger.error("Failed to append resample: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Close the current hang file with a recovery line. Idempotent.
    func recordHangRecovery(totalStallMs: UInt64) {
        lock.withLock {
            guard let fileHandle = currentFileHandle,
                  currentHangFileURL != nil else {
                return
            }

            var content = ""
            if totalStallMs > 0 {
                content += "\n=== Hang recovered ===\n"
                content += "Total stall duration: \(totalStallMs) ms\n"
            }

            if let data = content.data(using: .utf8) {
                do {
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                } catch {
                    Self.logger.error("Failed to write recovery marker: \(error.localizedDescription, privacy: .public)")
                }
            }

            do {
                try fileHandle.close()
            } catch {
                Self.logger.error("Failed to close hang file: \(error.localizedDescription, privacy: .public)")
            }

            currentFileHandle = nil
            currentHangFileURL = nil
        }
    }

    /// Trims the hang-stacks directory to the newest `HangStackRetention.maxFiles`
    /// files, after a new one has been written. No-op unless the mirrored
    /// `Config.gcHangStacksEnabled` flag is armed.
    ///
    /// **Count only** — the age half of the policy belongs to the daemon's
    /// hourly sweep, and the writer should do one cheap thing. This bound
    /// exists because the hourly sweep genuinely leaves a gap: a hang storm can
    /// write hundreds of files between two passes.
    ///
    /// Runs on the watchdog's background utility queue, never the main thread,
    /// and in steady state enumerates a directory the sweep has already bounded
    /// to ~1000 entries. The whitelist is the same one the collector uses, so
    /// nothing the writer did not produce is ever a candidate; the file just
    /// written and the one currently open for resamples are both excluded
    /// explicitly, even though a newest-first ranking already puts them far
    /// inside the cap.
    private func trimToRetentionCap(keeping justWritten: URL) {
        let (enabled, openFile) = lock.withLock { () in (retentionEnabled, currentHangFileURL) }
        guard enabled else { return }

        let keys: [URLResourceKey] = [
            .contentModificationDateKey, .creationDateKey, .isRegularFileKey,
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        var files: [(url: URL, date: Date)] = []
        for url in entries {
            guard HangStackRetention.isHangStackFilename(url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate ?? values.creationDate else { continue }
            files.append((url, date))
        }
        guard files.count > HangStackRetention.maxFiles else { return }

        files.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        var removed = 0
        for entry in files.dropFirst(HangStackRetention.maxFiles) {
            if entry.url == justWritten || entry.url == openFile { continue }
            // Anchored right before the delete, the same check the collector
            // makes: the path must resolve to an immediate child of the base.
            guard HangStackRetention.isImmediateChild(entry.url, of: baseDir) else { continue }
            do {
                try FileManager.default.removeItem(at: entry.url)
                removed += 1
            } catch {
                Self.logger.debug("""
                Failed to trim hang stack \(entry.url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
        if removed > 0 {
            Self.logger.info("""
            Trimmed \(removed, privacy: .public) hang-stack file(s) to the newest \
            \(HangStackRetention.maxFiles, privacy: .public)
            """)
        }
    }

    /// Close the current hang file with a superseded marker. Used when a new hang is detected
    /// while a previous hang file is still open. Idempotent.
    private func recordHangSuperseded() {
        lock.withLock {
            guard let fileHandle = currentFileHandle,
                  currentHangFileURL != nil else {
                return
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime, .withTimeZone]
            let timestamp = formatter.string(from: Date())

            let content = "\n=== Hang file superseded by new hang at \(timestamp) ===\n"

            if let data = content.data(using: .utf8) {
                do {
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                } catch {
                    Self.logger.error("Failed to write superseded marker: \(error.localizedDescription, privacy: .public)")
                }
            }

            do {
                try fileHandle.close()
            } catch {
                Self.logger.error("Failed to close superseded hang file: \(error.localizedDescription, privacy: .public)")
            }

            currentFileHandle = nil
            currentHangFileURL = nil
        }
    }
}
