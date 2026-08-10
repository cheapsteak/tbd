import Foundation
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

        #expect(TmuxManager.tmuxPath(path: toolsDirectory.path) == executable.path)
    }

    @Test
    func doesNotResolveExecutableWhoseDirectoryIsAbsentFromPath() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let toolsDirectory = try fixture.directory(named: "custom-tools")
        let emptyDirectory = try fixture.directory(named: "empty")
        _ = try fixture.tmux(in: toolsDirectory, permissions: 0o755)

        #expect(TmuxManager.tmuxPath(path: emptyDirectory.path) == nil)
    }

    @Test
    func skipsNonExecutableCandidate() throws {
        let fixture = try TmuxPathFixture()
        defer { fixture.remove() }
        let toolsDirectory = try fixture.directory(named: "custom-tools")
        _ = try fixture.tmux(in: toolsDirectory, permissions: 0o644)

        #expect(TmuxManager.tmuxPath(path: toolsDirectory.path) == nil)
    }

    @Test
    func rejectsMissingEmptyAndRelativePathEntries() {
        #expect(TmuxManager.tmuxPath(path: nil) == nil)
        #expect(TmuxManager.tmuxPath(path: "") == nil)
        #expect(TmuxManager.tmuxPath(path: "::relative-tools:") == nil)
    }
}

private struct TmuxPathFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxPathResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func directory(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func tmux(in directory: URL, permissions: Int) throws -> URL {
        let file = directory.appendingPathComponent("tmux")
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
