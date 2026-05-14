import Foundation
import os

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

    /// Lock protecting the file handle and URL.
    private let lock = OSAllocatedUnfairLock<()>(initialState: ())

    init(baseDir: URL? = nil) {
        if let baseDir = baseDir {
            self.baseDir = baseDir
        } else {
            // Default: ~/Library/Logs/TBD/hang-stacks/
            let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
            self.baseDir = libraryURL.appendingPathComponent("Logs/TBD/hang-stacks")
        }
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

            return lock.withLock { () in
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
