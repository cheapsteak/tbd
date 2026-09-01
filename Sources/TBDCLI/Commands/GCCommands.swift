import ArgumentParser
import Foundation
import TBDShared

struct GCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Orphan GC: list reaps, restore a reaped agent worktree, trigger a sweep",
        subcommands: [
            GCList.self, GCRestore.self, GCSweep.self, GCProfileDirs.self,
            GCOrphanProcesses.self, GCHolders.self,
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

/// The soak switch for the orphaned-process collector. It is the one GC phase
/// that signals processes rather than moving bytes, and what it misjudges
/// cannot be restored, so it ships off and is opted into by hand — here rather
/// than by editing `state.db`, which the project's own rules put out of bounds.
struct GCOrphanProcesses: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orphan-processes",
        abstract: "Enable or disable reclaiming processes that outlived their worktree (default off)")
    @Argument(help: "on | off") var state: String
    mutating func run() async throws {
        let enabled: Bool
        switch state.lowercased() {
        case "on", "true", "enable": enabled = true
        case "off", "false", "disable": enabled = false
        default: throw ValidationError("Expected 'on' or 'off', got: \(state)")
        }
        try SocketClient().callVoid(
            method: RPCMethod.configSetGCOrphanProcessesEnabled,
            params: ConfigSetGCOrphanProcessesEnabledParams(enabled: enabled))
        print("Orphan-process GC \(enabled ? "enabled" : "disabled").")
    }
}

/// The soak switch for the holder rendezvous sweep. It unlinks the socket a
/// SIGKILLed pty holder could not unlink, plus that holder's sibling lock and
/// log — files nothing else reclaims, so they accumulate one triple per session
/// forever. It ships off and is opted into by hand, like every other GC phase
/// whose classifier is new.
struct GCHolders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "holders",
        abstract: "Enable or disable unlinking rendezvous files of dead pty holders (default off)")
    @Argument(help: "on | off") var state: String
    mutating func run() async throws {
        let enabled: Bool
        switch state.lowercased() {
        case "on", "true", "enable": enabled = true
        case "off", "false", "disable": enabled = false
        default: throw ValidationError("Expected 'on' or 'off', got: \(state)")
        }
        try SocketClient().callVoid(
            method: RPCMethod.configSetGCHolderRendezvousEnabled,
            params: ConfigSetGCHolderRendezvousEnabledParams(enabled: enabled))
        print("Holder rendezvous GC \(enabled ? "enabled" : "disabled").")
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
            // An orphan-process reap removed nothing from disk, so its
            // worktreePath alone says only where the process lived. The whole
            // point of the field is to say WHAT was killed.
            let process = r.processDescription.map { "  killed→ \($0)" } ?? ""
            print("""
            \(r.id)  \(r.kind.rawValue)  \(r.worktreePath)  \(size)  \
            \(snap)\(restored)\(quarantine)\(process)
            """)
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
