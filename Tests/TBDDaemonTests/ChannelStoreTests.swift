import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct ChannelStoreTests {

    private func makeStore() throws -> (ChannelStore, URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("state.db").path
        let db = try TBDDatabase(path: dbPath)
        let store = ChannelStore(channelsDir: tmp.appendingPathComponent("channels"),
                                 index: db.channels)
        return (store, tmp, dbPath)
    }

    @Test func postCreatesFileWithSeq1() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await store.post(name: "help", body: "hi",
                                          fromSession: "s1", fromLabel: "L1")
        #expect(result.seq == 1)

        let file = tmp.appendingPathComponent("channels").appendingPathComponent("help.jsonl")
        let bytes = try Data(contentsOf: file)
        let line = try ChannelMessage.decodeLine(bytes)
        #expect(line.seq == 1)
        #expect(line.body == "hi")
        #expect(line.fromSession == "s1")
        #expect(line.fromLabel == "L1")
    }

    @Test func sequentialPostsIncrementSeq() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r1 = try await store.post(name: "help", body: "one", fromSession: "s", fromLabel: "L")
        let r2 = try await store.post(name: "help", body: "two", fromSession: "s", fromLabel: "L")
        let r3 = try await store.post(name: "help", body: "three", fromSession: "s", fromLabel: "L")
        let seqs: [Int] = [r1.seq, r2.seq, r3.seq]
        #expect(seqs == [1, 2, 3])
    }

    @Test func differentChannelsHaveIndependentSeq() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = try await store.post(name: "alpha", body: "x", fromSession: "s", fromLabel: "L")
        let b = try await store.post(name: "beta",  body: "x", fromSession: "s", fromLabel: "L")
        #expect(a.seq == 1)
        #expect(b.seq == 1)
    }

    @Test func nameIsCaseFolded() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await store.post(name: "Help", body: "x", fromSession: "s", fromLabel: "L")
        _ = try await store.post(name: "HELP", body: "y", fromSession: "s", fromLabel: "L")

        // Both should land in the same file `help.jsonl`.
        let file = tmp.appendingPathComponent("channels/help.jsonl")
        let bytes = try Data(contentsOf: file)
        let lines = bytes.split(separator: 0x0A)
        #expect(lines.count == 2)
    }

    @Test func rejectsInvalidName() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: ChannelNameError.self) {
            _ = try await store.post(name: "../etc/passwd", body: "x",
                                     fromSession: "s", fromLabel: "L")
        }
    }

    @Test func rejectsBodyOver64KB() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let body = String(repeating: "a", count: 64 * 1024 + 1)
        await #expect(throws: ChannelStoreError.self) {
            _ = try await store.post(name: "help", body: body,
                                     fromSession: "s", fromLabel: "L")
        }
    }

    @Test func updatesChannelIndex() async throws {
        let (store, tmp, dbPath) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await store.post(name: "help", body: "x", fromSession: "s", fromLabel: "L")
        _ = try await store.post(name: "help", body: "y", fromSession: "s", fromLabel: "L")

        let db = try TBDDatabase(path: dbPath)
        let entries = try await db.channels.list(includeArchived: false)
        #expect(entries.first?.name == "help")
        #expect(entries.first?.messageCount == 2)
    }

    @Test func concurrentPostsToSameChannelGetUniqueSeq() async throws {
        let (store, tmp, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let count = 20
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<count {
                group.addTask {
                    let r = try await store.post(name: "race", body: "msg-\(i)",
                                                 fromSession: "s", fromLabel: "L")
                    return r.seq
                }
            }
            var seqs: [Int] = []
            for try await seq in group { seqs.append(seq) }
            #expect(Set(seqs).count == count)
            #expect(seqs.min() == 1)
            #expect(seqs.max() == count)
        }
    }
}
