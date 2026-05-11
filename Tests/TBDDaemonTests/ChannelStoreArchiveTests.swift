import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct ChannelStoreArchiveTests {

    private func makeStore() throws -> (ChannelStore, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-csa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("state.db").path
        let db = try TBDDatabase(path: dbPath)
        let store = ChannelStore(channelsDir: tmp.appendingPathComponent("channels"),
                                 index: db.channels)
        return (store, tmp, dbPath)
    }

    @Test func archiveMovesFileToArchiveDir() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await store.post(name: "old", body: "x", fromSession: "s", fromLabel: "L")
        let archived = try await store.archive(name: "old")

        let activePath = tmp.appendingPathComponent("channels/old.jsonl").path
        #expect(FileManager.default.fileExists(atPath: activePath) == false)
        #expect(FileManager.default.fileExists(atPath: archived) == true)
        #expect(archived.contains("/_archive/old-"))
        #expect(archived.hasSuffix(".jsonl"))
    }

    @Test func archiveRemovesIndexRow() async throws {
        let (store, tmp, dbPath) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await store.post(name: "old", body: "x", fromSession: "s", fromLabel: "L")
        _ = try await store.archive(name: "old")

        let db = try TBDDatabase(path: dbPath)
        let entries = try await db.channels.list(includeArchived: false)
        #expect(entries.isEmpty)
    }

    @Test func archiveRemovesLockSidecar() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await store.post(name: "old", body: "x", fromSession: "s", fromLabel: "L")
        _ = try await store.archive(name: "old")
        let lockPath = tmp.appendingPathComponent("channels/old.lock").path
        #expect(FileManager.default.fileExists(atPath: lockPath) == false)
    }

    @Test func reusingArchivedNameStartsAtSeq1() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await store.post(name: "phoenix", body: "first life",
                                 fromSession: "s", fromLabel: "L")
        _ = try await store.post(name: "phoenix", body: "still first",
                                 fromSession: "s", fromLabel: "L")
        _ = try await store.archive(name: "phoenix")

        let r = try await store.post(name: "phoenix", body: "rebirth",
                                     fromSession: "s", fromLabel: "L")
        #expect(r.seq == 1)
    }

    @Test func archiveOfMissingChannelThrows() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: ChannelStoreError.self) {
            _ = try await store.archive(name: "ghost")
        }
    }
}
