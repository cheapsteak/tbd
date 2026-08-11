import Foundation
import TBDShared
import Testing
@testable import TBDDaemonLib

@Suite("Tmux PATH resolution")
struct TmuxPathResolutionTests {
    @Test
    func resolvesExecutableFromNonstandardPathDirectory() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let toolsDirectory = try fixture.directory(named: "custom tools")
        let executable = try fixture.tmux(in: toolsDirectory, permissions: 0o755)

        #expect(TmuxManager.tmuxPath(
            path: toolsDirectory.path,
            configurationURL: fixture.configurationURL
        ) == executable.path)
    }

    @Test
    func doesNotResolveExecutableWhoseDirectoryIsAbsentFromPath() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let toolsDirectory = try fixture.directory(named: "custom-tools")
        let emptyDirectory = try fixture.directory(named: "empty")
        _ = try fixture.tmux(in: toolsDirectory, permissions: 0o755)

        #expect(TmuxManager.tmuxPath(
            path: emptyDirectory.path,
            configurationURL: fixture.configurationURL
        ) == nil)
    }

    @Test
    func skipsNonExecutableCandidate() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let toolsDirectory = try fixture.directory(named: "custom-tools")
        _ = try fixture.tmux(in: toolsDirectory, permissions: 0o644)

        #expect(TmuxManager.tmuxPath(
            path: toolsDirectory.path,
            configurationURL: fixture.configurationURL
        ) == nil)
    }

    @Test
    func rejectsMissingEmptyAndRelativePathEntries() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }

        #expect(TmuxManager.tmuxPath(path: nil, configurationURL: fixture.configurationURL) == nil)
        #expect(TmuxManager.tmuxPath(path: "", configurationURL: fixture.configurationURL) == nil)
        #expect(TmuxManager.tmuxPath(
            path: "::relative-tools:",
            configurationURL: fixture.configurationURL
        ) == nil)
    }

    @Test
    func resolvesSavedFallbackAfterPathMiss() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let emptyDirectory = try fixture.directory(named: "empty")
        let savedExecutable = try fixture.tmux(
            named: "saved-tmux",
            in: fixture.root,
            permissions: 0o755
        )
        try savedExecutable.path.write(
            to: fixture.configurationURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(TmuxManager.tmuxPath(
            path: emptyDirectory.path,
            configurationURL: fixture.configurationURL
        ) == savedExecutable.path)
    }

    @Test
    func rejectsInvalidSavedFallbackAfterPathMiss() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let emptyDirectory = try fixture.directory(named: "empty")
        let savedFile = try fixture.tmux(
            named: "saved-tmux",
            in: fixture.root,
            permissions: 0o644
        )
        try savedFile.path.write(
            to: fixture.configurationURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(TmuxManager.tmuxPath(
            path: emptyDirectory.path,
            configurationURL: fixture.configurationURL
        ) == nil)
    }
}

private struct TmuxPathFixture {
    let root: URL
    let configurationURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxPathResolutionTests-\(UUID().uuidString)", isDirectory: true)
        configurationURL = root.appendingPathComponent("tmux-executable-path")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func directory(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func tmux(named name: String = "tmux", in directory: URL, permissions: Int) throws -> URL {
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
