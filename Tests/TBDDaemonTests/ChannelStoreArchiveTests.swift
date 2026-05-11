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

    /// Regression: post and archive used to issue their channel_index
    /// writes *outside* the per-channel lock. If `delete` landed before
    /// `recordPost`, the upsert resurrected the row for a channel whose
    /// JSONL had already been moved to `_archive/` — `tbd channels list`
    /// showed a phantom active channel with no backing file.
    ///
    /// With both DB calls now inside the per-channel lock, the index and
    /// the filesystem can never disagree: either the row exists and the
    /// active file exists, or neither does. This test races the two
    /// operations across multiple iterations to amplify the chance of
    /// catching a regression. It is non-deterministic — the bug doesn't
    /// fire on every run — but with the fix in place it can never
    /// observe the inconsistent state, so it cannot false-positive.
    @Test func archiveDoesNotResurrectIndexRowFromInflightPost() async throws {
        for _ in 0..<10 {
            let (store, tmp, dbPath) = try makeStore()
            defer { try? FileManager.default.removeItem(at: tmp) }

            // Establish the channel so the racing `post` is "update" not "insert".
            _ = try await store.post(name: "ghosted", body: "first",
                                     fromSession: "s", fromLabel: "L")

            // Concurrently kick off another post and an archive. Whichever
            // wins the per-channel lock first, both should leave the index
            // and filesystem in agreement when they're done.
            async let p: () = {
                _ = try? await store.post(name: "ghosted", body: "racing",
                                          fromSession: "s", fromLabel: "L")
            }()
            async let a: () = {
                _ = try? await store.archive(name: "ghosted")
            }()
            _ = await (p, a)

            // Read the index. Either the channel is archived (no row, no
            // active file) OR the post landed first and the channel is
            // still active. The buggy interleaving (row exists but file
            // gone, or file exists but no row) must never be observed.
            let db = try TBDDatabase(path: dbPath)
            let entries = try await db.channels.list(includeArchived: false)
            let activePath = tmp.appendingPathComponent("channels/ghosted.jsonl").path
            let activeFileExists = FileManager.default.fileExists(atPath: activePath)
            let indexHasRow = entries.contains { $0.name == "ghosted" }
            #expect(activeFileExists == indexHasRow,
                    "phantom row: index says active=\(indexHasRow) but file exists=\(activeFileExists)")
        }
    }
}
