import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct ChannelStoreRecoveryTests {

    private func makeStore() throws -> (ChannelStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-csr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("state.db").path
        let db = try TBDDatabase(path: dbPath)
        let store = ChannelStore(channelsDir: tmp.appendingPathComponent("channels"),
                                 index: db.channels)
        return (store, tmp)
    }

    @Test func recoversFromTornLastLine() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Post two messages so we have known good content.
        _ = try await store.post(name: "rec", body: "m1", fromSession: "s", fromLabel: "L")
        _ = try await store.post(name: "rec", body: "m2", fromSession: "s", fromLabel: "L")

        // Append a half-written line to simulate a crash mid-write.
        let path = tmp.appendingPathComponent("channels/rec.jsonl").path
        let truncated = "{\"seq\":3,\"ts\":\"2026-".data(using: .utf8)!
        let fd = open(path, O_WRONLY | O_APPEND)
        _ = truncated.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)

        // Make a new store (simulating daemon restart).
        let dbPath2 = tmp.appendingPathComponent("state.db").path
        let db2 = try TBDDatabase(path: dbPath2)
        let store2 = ChannelStore(channelsDir: tmp.appendingPathComponent("channels"),
                                  index: db2.channels)

        // Next post should be seq 3 (torn line is dropped); file should
        // contain exactly 3 valid JSONL lines.
        let r = try await store2.post(name: "rec", body: "m3",
                                      fromSession: "s", fromLabel: "L")
        #expect(r.seq == 3)

        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let lines = bytes.split(separator: 0x0A).filter { !$0.isEmpty }
        #expect(lines.count == 3)
        for line in lines {
            _ = try ChannelMessage.decodeLine(Data(line))
        }
    }

    @Test func emptyFileReturnsZeroSeq() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create an empty file.
        let dir = tmp.appendingPathComponent("channels")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("empty.jsonl").path
        FileManager.default.createFile(atPath: path, contents: nil)

        let r = try await store.post(name: "empty", body: "first",
                                     fromSession: "s", fromLabel: "L")
        #expect(r.seq == 1)
    }

    @Test func recoveryHandlesNoFinalNewline() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Manually write one good line and one trailing partial line with no newline at all.
        let dir = tmp.appendingPathComponent("channels")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("nonl.jsonl").path
        let good = ChannelMessage(seq: 1, ts: Date(), fromSession: "s", fromLabel: "L", body: "ok")
        var content = try good.encodeLine()
        content.append(contentsOf: Array("{\"partial".utf8))
        try content.write(to: URL(fileURLWithPath: path))

        let r = try await store.post(name: "nonl", body: "next",
                                     fromSession: "s", fromLabel: "L")
        #expect(r.seq == 2)
    }
}
