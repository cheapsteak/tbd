import Foundation
import Testing
@testable import TBDApp

@Suite("ExecutableResolver")
struct ExecutableResolverTests {
    @Test func returnsFirstExecutableInPathOrderAsStandardizedAbsolutePath() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let firstDirectory = try fixture.directory(named: "first")
        let secondDirectory = try fixture.directory(named: "second")
        let firstExecutable = try fixture.executable(named: "tmux", in: firstDirectory)
        _ = try fixture.executable(named: "tmux", in: secondDirectory)

        let unstandardizedFirstDirectory = firstDirectory
            .appendingPathComponent("child")
            .appendingPathComponent("..")
        try FileManager.default.createDirectory(
            at: firstDirectory.appendingPathComponent("child"),
            withIntermediateDirectories: false
        )

        #expect(ExecutableResolver.resolve(
            "tmux",
            path: "\(unstandardizedFirstDirectory.path):\(secondDirectory.path)"
        ) == firstExecutable.standardizedFileURL.path)
    }

    @Test func skipsNonExecutableCandidateForLaterExecutable() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let firstDirectory = try fixture.directory(named: "first")
        let secondDirectory = try fixture.directory(named: "second")
        _ = try fixture.file(named: "tmux", in: firstDirectory, permissions: 0o644)
        let secondExecutable = try fixture.executable(named: "tmux", in: secondDirectory)

        #expect(ExecutableResolver.resolve(
            "tmux",
            path: "\(firstDirectory.path):\(secondDirectory.path)"
        ) == secondExecutable.standardizedFileURL.path)
    }

    @Test func handlesDirectoryNamesContainingSpaces() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "tools with spaces")
        let executable = try fixture.executable(named: "tmux", in: directory)

        #expect(ExecutableResolver.resolve("tmux", path: directory.path) == executable.path)
    }

    @Test func ignoresEmptyAndRelativePathEntries() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "absolute")
        let executable = try fixture.executable(named: "tmux", in: directory)

        #expect(ExecutableResolver.resolve(
            "tmux",
            path: ":relative-bin::\(directory.path)"
        ) == executable.path)
    }

    @Test func returnsNilForMissingNilOrEmptyPath() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "empty")

        #expect(ExecutableResolver.resolve("tmux", path: nil) == nil)
        #expect(ExecutableResolver.resolve("tmux", path: "") == nil)
        #expect(ExecutableResolver.resolve("tmux", path: directory.path) == nil)
    }

    @Test func rejectsEmptyAndSlashedExecutableNames() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "bin")
        _ = try fixture.executable(named: "tmux", in: directory)

        #expect(ExecutableResolver.resolve("", path: directory.path) == nil)
        #expect(ExecutableResolver.resolve("tools/tmux", path: directory.path) == nil)
    }

    @Test func doesNotSearchStandardLocationsOutsidePath() throws {
        let fixture = try ExecutableFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "empty")

        #expect(ExecutableResolver.resolve("sh", path: directory.path) == nil)
    }
}

private struct ExecutableFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func directory(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func executable(named name: String, in directory: URL) throws -> URL {
        try file(named: name, in: directory, permissions: 0o755)
    }

    func file(named name: String, in directory: URL, permissions: Int) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: file.path
        )
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
