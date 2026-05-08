import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct LegacyHookScannerTests {

    @Test func detectsTBDNotifyEntryInWrappedFormat() {
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "tbd notify --type response_complete"]
                        ]
                    ]
                ]
            ]
        ]
        let entries = LegacyHookScanner.detectEntries(in: settings)
        #expect(entries.count == 1)
        #expect(entries.first?.event == "Stop")
    }

    @Test func detectsTBDNotifyEntryInBareFormat() {
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["type": "command", "command": "tbd notify"]
                ]
            ]
        ]
        let entries = LegacyHookScanner.detectEntries(in: settings)
        #expect(entries.count == 1)
    }

    @Test func detectsSessionEventEntry() {
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "tbd session-event"]]]
                ]
            ]
        ]
        let entries = LegacyHookScanner.detectEntries(in: settings)
        #expect(entries.count == 1)
        #expect(entries.first?.event == "SessionStart")
    }

    @Test func ignoresUnrelatedEntries() {
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "echo hi"]]]
                ]
            ]
        ]
        let entries = LegacyHookScanner.detectEntries(in: settings)
        #expect(entries.isEmpty)
    }

    @Test func stripsWrappedAndBareEntries() {
        var settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "tbd notify --type response_complete"]]],
                    ["hooks": [["type": "command", "command": "echo keep me"]]],
                    ["type": "command", "command": "tbd notify --type error"]
                ],
                "SessionStart": [
                    ["matcher": "*", "hooks": [["type": "command", "command": "tbd session-event"]]]
                ]
            ],
            "model": "claude-opus"
        ]
        let removed = LegacyHookScanner.stripEntries(from: &settings)
        #expect(removed == 3)

        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        // The non-tbd matcher should still be present.
        #expect(stop.count == 1)
        // The SessionStart key should have been removed because the only
        // entry in it was a TBD entry.
        #expect(hooks["SessionStart"] == nil)
        // Unrelated top-level keys preserved.
        #expect(settings["model"] as? String == "claude-opus")
    }

    @Test func removeGlobalEntriesIsNoOpWhenFileMissing() throws {
        let path = NSTemporaryDirectory() + "tbd-legacy-missing-\(UUID().uuidString).json"
        let result = try LegacyHookScanner.removeGlobalEntries(at: path)
        #expect(result.removedCount == 0)
        #expect(result.backupPath == nil)
    }

    @Test func removeGlobalEntriesWritesBackupOnce() throws {
        let path = NSTemporaryDirectory() + "tbd-legacy-\(UUID().uuidString).json"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + SettingsJSONSafety.backupSuffix)
        }
        let original: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "tbd notify"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: original)
        try data.write(to: URL(fileURLWithPath: path))

        let r1 = try LegacyHookScanner.removeGlobalEntries(at: path)
        #expect(r1.removedCount == 1)
        #expect(r1.backupPath == path + SettingsJSONSafety.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: r1.backupPath!))

        // After removal, the file no longer contains marker entries.
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: after) as? [String: Any] ?? [:]
        #expect(LegacyHookScanner.detectEntries(in: parsed).isEmpty)

        // Re-running is a no-op on the live file but the backup must
        // still preserve the FIRST original.
        let r2 = try LegacyHookScanner.removeGlobalEntries(at: path)
        #expect(r2.removedCount == 0)
        let backupBytes = try Data(contentsOf: URL(fileURLWithPath: path + SettingsJSONSafety.backupSuffix))
        let backupDict = try JSONSerialization.jsonObject(with: backupBytes) as? [String: Any] ?? [:]
        // Original (legacy entry) preserved in the backup.
        #expect(!LegacyHookScanner.detectEntries(in: backupDict).isEmpty)
    }
}
