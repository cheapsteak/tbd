import ArgumentParser
import Foundation
import TBDShared

struct GCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Orphan GC: list reaps, restore a reaped agent worktree, trigger a sweep",
        subcommands: [GCList.self, GCRestore.self, GCSweep.self]
    )
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
            print("\(r.id)  \(r.kind.rawValue)  \(r.worktreePath)  \(size)  \(snap)\(restored)")
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
