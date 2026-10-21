import Foundation
import Testing
@testable import TBDDaemonLib

/// The one-time removal of the retired model proxy's `proxy` and `streams`
/// directories. Every test runs against its own temporary base directory, never
/// the developer's real TBD home.
@Suite("ProxyLeftoverCleanup")
struct ProxyLeftoverCleanupTests {
    let fm = FileManager.default

    private func makeBase() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("proxy-leftovers-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeFile(_ url: URL) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func removesBothLeftoverDirectories() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        let proxy = base.appendingPathComponent("proxy", isDirectory: true)
        let streams = base.appendingPathComponent("streams", isDirectory: true)
        try makeFile(proxy.appendingPathComponent("proxy.pid"))
        try makeFile(proxy.appendingPathComponent("routes/route.json"))
        try makeFile(streams.appendingPathComponent("terminal.jsonl"))

        let removed = ProxyLeftoverCleanup(baseDirectory: base).run()

        #expect(!fm.fileExists(atPath: proxy.path))
        #expect(!fm.fileExists(atPath: streams.path))
        #expect(Set(removed.map(\.lastPathComponent)) == ["proxy", "streams"])
    }

    @Test func removesOneWhenOnlyOneExists() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        let streams = base.appendingPathComponent("streams", isDirectory: true)
        try makeFile(streams.appendingPathComponent("terminal.jsonl"))

        let removed = ProxyLeftoverCleanup(baseDirectory: base).run()

        #expect(!fm.fileExists(atPath: streams.path))
        #expect(removed.map(\.lastPathComponent) == ["streams"])
    }

    @Test func isANoOpWhenNeitherExists() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }

        let removed = ProxyLeftoverCleanup(baseDirectory: base).run()

        #expect(removed.isEmpty)
        #expect(fm.fileExists(atPath: base.path), "the base directory itself is never removed")
        #expect(try fm.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test func isANoOpWhenTheBaseDirectoryIsMissing() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("proxy-leftovers-missing-\(UUID().uuidString)", isDirectory: true)

        let removed = ProxyLeftoverCleanup(baseDirectory: base).run()

        #expect(removed.isEmpty)
        #expect(!fm.fileExists(atPath: base.path))
    }

    @Test func leavesSiblingsUntouched() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        try makeFile(base.appendingPathComponent("proxy/proxy.pid"))
        try makeFile(base.appendingPathComponent("streams/terminal.jsonl"))
        let siblings = [
            base.appendingPathComponent("state.db"),
            base.appendingPathComponent("sessions/s1/transcript-stream.json"),
            base.appendingPathComponent("holders/h1.lock"),
            base.appendingPathComponent("proxy-notes/keep.txt"),
            base.appendingPathComponent("streams.bak"),
        ]
        for sibling in siblings { try makeFile(sibling) }

        ProxyLeftoverCleanup(baseDirectory: base).run()

        for sibling in siblings {
            #expect(fm.fileExists(atPath: sibling.path), "\(sibling.lastPathComponent) must survive")
        }
        #expect(!fm.fileExists(atPath: base.appendingPathComponent("proxy").path))
        #expect(!fm.fileExists(atPath: base.appendingPathComponent("streams").path))
    }
}
