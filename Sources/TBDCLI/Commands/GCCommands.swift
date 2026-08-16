import ArgumentParser
import Foundation
import TBDShared

struct GCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Orphan GC: list reaps, restore a reaped agent worktree, trigger a sweep",
        subcommands: [
            GCList.self, GCRestore.self, GCSweep.self, GCProfileDirs.self,
            GCSupervisionDesks.self,
        ]
    )
}

/// The soak switch for the profile-dir collector. It quarantines orphaned
/// `~/tbd/profiles/<uuid>/` directories, which hold per-profile credentials and
/// user content, so it ships off and is opted into by hand.
struct GCProfileDirs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile-dirs",
        abstract: "Enable or disable reclaiming orphaned model-profile config dirs (default off)")
    @Argument(help: "on | off") var state: String
    mutating func run() async throws {
        let enabled: Bool
        switch state.lowercased() {
        case "on", "true", "enable": enabled = true
        case "off", "false", "disable": enabled = false
        default: throw ValidationError("Expected 'on' or 'off', got: \(state)")
        }
        try SocketClient().callVoid(method: RPCMethod.configSetGCProfileDirsEnabled,
                                    params: ConfigSetGCProfileDirsEnabledParams(enabled: enabled))
        print("Profile-dir GC \(enabled ? "enabled" : "disabled").")
    }
}

/// The soak switch for the supervision-desk collector. It archives the scratch
/// space of a hosted supervisor whose session is gone and drops its record, so
/// it ships off and is opted into by hand — the same shape `profile-dirs` uses.
struct GCSupervisionDesks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supervision-desks",
        abstract: "Enable or disable reclaiming orphaned supervision desks (default off)")
    @Argument(help: "on | off") var state: String
    mutating func run() async throws {
        let enabled: Bool
        switch state.lowercased() {
        case "on", "true", "enable": enabled = true
        case "off", "false", "disable": enabled = false
        default: throw ValidationError("Expected 'on' or 'off', got: \(state)")
        }
        try SocketClient().callVoid(
            method: RPCMethod.configSetGCSupervisionDesksEnabled,
            params: ConfigSetGCSupervisionDesksEnabledParams(enabled: enabled))
        print("Supervision-desk GC \(enabled ? "enabled" : "disabled").")
    }
}

struct GCList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List reap records")
    @Option(name: .long, help: "Filter by repo root path") var repo: String?
    @Flag(name: .long, help: "Output JSON") var json = false
    mutating func run() async throws {
        let client = SocketClient()
        let records: [ReapRecord] = try client.call(method: RPCMethod.gcList,
                                                    params: GCListParams(repoPath: repo),
                                                    resultType: [ReapRecord].self)
        if json { printJSON(records); return }
        if records.isEmpty { print("No reap records."); return }
        for r in records {
            let size = r.apparentBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
            let snap = r.snapshotRef != nil ? "snapshot ✓" : "clean"
            let restored = r.restoredAt != nil ? " (restored)" : ""
            // A quarantined reap has no restore path, so this is the only
            // handle a user has on the data before retention expires — print it.
            let quarantine = r.quarantinePath.map { "  quarantined→ \($0)" } ?? ""
            print("\(r.id)  \(r.kind.rawValue)  \(r.worktreePath)  \(size)  \(snap)\(restored)\(quarantine)")
        }
    }
}

struct GCRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore a reaped agent worktree")
    @Argument(help: "Reap record ID (from 'tbd gc list')") var id: String
    mutating func run() async throws {
        guard let uuid = UUID(uuidString: id) else { throw ValidationError("Not a UUID: \(id)") }
        try SocketClient().callVoid(method: RPCMethod.gcRestore, params: GCRestoreParams(recordID: uuid))
        print("Restored.")
    }
}

struct GCSweep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sweep", abstract: "Run an orphan-GC sweep now")
    @Flag(name: .long, help: "Print the plan without deleting anything") var dryRun = false
    mutating func run() async throws {
        let result: GCSweepResult = try SocketClient().call(method: RPCMethod.gcSweepNow,
                                                            params: GCSweepNowParams(dryRun: dryRun),
                                                            resultType: GCSweepResult.self)
        for line in result.planned { print(line) }
        print(dryRun ? "(dry run — nothing deleted)" : "Reaped \(result.reaped) item(s).")
    }
}
