import Foundation
import Testing
@testable import TBDShared

// Tier 2: reads a temp file, no daemon and no network.
@Suite("RemoteProviderReservedName")
struct RemoteProviderReservedNameTests {
    private func write(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reserved-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("agent-providers.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// One bad entry must cost that entry, never the file: `load` throws for
    /// the WHOLE registry on a duplicate, and two of its three call sites
    /// swallow that, so a reserved-name collision would otherwise silently
    /// remove every provider the user registered.
    @Test func aReservedEntryIsSkippedAndFlaggedWhileEveryOtherEntryLoads() throws {
        let file = try write(#"""
        [{"name": "acme", "exec": "/usr/bin/acme"},
         {"name": "claude-cloud", "exec": "/usr/bin/impostor"},
         {"name": "other", "exec": "/usr/bin/other"}]
        """#)
        let loaded = try RemoteProviderRegistry.loadEntries(from: file)
        #expect(loaded.configs.map(\.name) == ["acme", "other"])
        #expect(loaded.skippedReservedNames == ["claude-cloud"])
    }

    /// The skip is checked BEFORE the duplicate rule, so two reserved entries
    /// are two skips rather than a duplicate-name failure of the whole file.
    @Test func twoReservedEntriesAreTwoSkipsNotADuplicate() throws {
        let file = try write(#"""
        [{"name": "claude-cloud", "exec": "/a"}, {"name": "claude-cloud", "exec": "/b"}]
        """#)
        let loaded = try RemoteProviderRegistry.loadEntries(from: file)
        #expect(loaded.configs.isEmpty)
        #expect(loaded.skippedReservedNames == ["claude-cloud", "claude-cloud"])
    }

    /// The discriminating half: a duplicate of a NON-reserved name still
    /// rejects the file, so the skip did not weaken the duplicate rule.
    @Test func aDuplicateNonReservedNameStillRejectsTheWholeFile() throws {
        let file = try write(#"[{"name": "acme", "exec": "/a"}, {"name": "acme", "exec": "/b"}]"#)
        #expect(throws: RemoteProviderRegistry.RegistryError.duplicateName("acme")) {
            try RemoteProviderRegistry.loadEntries(from: file)
        }
    }

    @Test func loadKeepsItsSignatureAndDropsTheReservedEntry() throws {
        let file = try write(#"""
        [{"name": "acme", "exec": "/usr/bin/acme"}, {"name": "claude-cloud", "exec": "/x"}]
        """#)
        #expect(try RemoteProviderRegistry.load(from: file).map(\.name) == ["acme"])
    }

    @Test func aMissingFileIsStillNoProvidersRatherThanAnError() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        let loaded = try RemoteProviderRegistry.loadEntries(from: missing)
        #expect(loaded.configs.isEmpty)
        #expect(loaded.skippedReservedNames.isEmpty)
    }

    @Test func isReservedAnswersForBothCases() {
        #expect(RemoteProviderRegistry.isReserved(ClaudeCloudProvider.name))
        #expect(!RemoteProviderRegistry.isReserved("acme"))
    }
}
