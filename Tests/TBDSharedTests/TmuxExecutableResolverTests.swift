import Foundation
import Testing
@testable import TBDShared

@Suite("Tmux executable resolver")
struct TmuxExecutableResolverTests {
    @Test func pathReturnsFirstExecutableAndWinsOverSavedFallback() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let firstDirectory = try fixture.directory(named: "first")
        let secondDirectory = try fixture.directory(named: "second")
        let first = try fixture.executable(named: "tmux", in: firstDirectory)
        _ = try fixture.executable(named: "tmux", in: secondDirectory)
        let saved = try fixture.executable(named: "saved-tmux", in: fixture.root)
        try saved.path.write(to: fixture.configurationURL, atomically: true, encoding: .utf8)

        let resolver = fixture.resolver(path: "\(firstDirectory.path):\(secondDirectory.path)")

        #expect(resolver.resolve() == TmuxExecutableResolution(path: first.path, source: .path))
    }

    @Test func pathSkipsEmptyRelativeAndNonExecutableCandidates() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let nonExecutableDirectory = try fixture.directory(named: "non-executable")
        _ = try fixture.file(named: "tmux", in: nonExecutableDirectory, permissions: 0o644)
        let executableDirectory = try fixture.directory(named: "executable")
        let executable = try fixture.executable(named: "tmux", in: executableDirectory)

        let resolver = fixture.resolver(
            path: ":relative-bin:\(nonExecutableDirectory.path)::\(executableDirectory.path)"
        )

        #expect(resolver.resolve() == TmuxExecutableResolution(path: executable.path, source: .path))
    }

    @Test func pathSkipsDirectoryNamedTmuxForLaterRegularExecutable() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let directoryCandidateParent = try fixture.directory(named: "directory-candidate")
        try FileManager.default.createDirectory(
            at: directoryCandidateParent.appendingPathComponent("tmux", isDirectory: true),
            withIntermediateDirectories: false
        )
        let executableDirectory = try fixture.directory(named: "executable")
        let executable = try fixture.executable(named: "tmux", in: executableDirectory)

        let resolver = fixture.resolver(
            path: "\(directoryCandidateParent.path):\(executableDirectory.path)"
        )

        #expect(resolver.resolve() == TmuxExecutableResolution(path: executable.path, source: .path))
    }

    @Test func pathReturnsStandardizedExecutablePath() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let executableDirectory = try fixture.directory(named: "executable")
        _ = try fixture.directory(named: "child", in: executableDirectory)
        let executable = try fixture.executable(named: "tmux", in: executableDirectory)

        let resolver = fixture.resolver(
            path: executableDirectory.appendingPathComponent("child/..").path
        )

        #expect(resolver.resolve()?.path == executable.standardizedFileURL.path)
    }

    @Test func validSavedExecutableResolvesAfterPathMiss() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let emptyDirectory = try fixture.directory(named: "empty")
        let saved = try fixture.executable(named: "saved-tmux", in: fixture.root)
        try "  \(saved.path)\n".write(to: fixture.configurationURL, atomically: true, encoding: .utf8)

        let resolver = fixture.resolver(path: emptyDirectory.path)

        #expect(resolver.savedPath == saved.path)
        #expect(resolver.resolve() == TmuxExecutableResolution(path: saved.path, source: .savedFallback))
    }

    @Test func explicitEnvironmentDerivesFallbackFileFromTBDHome() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let tbdHome = try fixture.directory(named: "explicit-tbd-home")
        let configurationURL = tbdHome.appendingPathComponent("tmux-executable-path")
        let saved = try fixture.executable(named: "saved-tmux", in: fixture.root)
        try saved.path.write(to: configurationURL, atomically: true, encoding: .utf8)
        let replacement = try fixture.executable(named: "replacement-tmux", in: fixture.root)
        let resolver = TmuxExecutableResolver(
            environment: ["PATH": "", "TBD_HOME": tbdHome.path]
        )

        #expect(resolver.savedPath == saved.path)
        #expect(resolver.resolve() == TmuxExecutableResolution(path: saved.path, source: .savedFallback))

        try resolver.save(replacement.path)

        #expect(try String(contentsOf: configurationURL, encoding: .utf8) == replacement.path)
    }

    @Test func invalidSavedValuesDoNotResolve() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let nonExecutable = try fixture.file(named: "not-executable", in: fixture.root, permissions: 0o644)
        let missing = fixture.root.appendingPathComponent("missing")
        let invalidValues = ["", "  \n", "relative/tmux", missing.path, nonExecutable.path]

        for value in invalidValues {
            try value.write(to: fixture.configurationURL, atomically: true, encoding: .utf8)
            #expect(fixture.resolver(path: "").resolve() == nil)
        }
    }

    @Test func savedPathRemainsReadableWhenExecutableBecomesInvalid() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "tmux", in: fixture.root)
        let resolver = fixture.resolver(path: "")
        try resolver.save(" \(executable.path)\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: executable.path
        )

        #expect(resolver.savedPath == executable.path)
        #expect(resolver.resolve() == nil)
    }

    @Test func saveTrimsWhitespaceAndCreatesOnlyTheBackingFile() throws {
        let fixture = try TmuxExecutableFixture(createConfigurationDirectory: false)
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "tmux", in: fixture.root)
        let resolver = fixture.resolver(path: "")

        try resolver.save(" \t\(executable.path)\n")

        #expect(try String(contentsOf: fixture.configurationURL, encoding: .utf8) == executable.path)
        #expect(resolver.savedPath == executable.path)
        let contents = try FileManager.default.contentsOfDirectory(
            at: fixture.configurationURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(contents.map { $0.resolvingSymlinksInPath() } == [fixture.configurationURL.resolvingSymlinksInPath()])
    }

    @Test func invalidSavePreservesPriorValidValue() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "tmux", in: fixture.root)
        let resolver = fixture.resolver(path: "")
        try resolver.save(executable.path)

        #expect(throws: (any Error).self) {
            try resolver.save("relative/tmux")
        }

        #expect(resolver.savedPath == executable.path)
        #expect(try String(contentsOf: fixture.configurationURL, encoding: .utf8) == executable.path)
    }

    @Test func saveRejectsEmptyMissingAndNonExecutablePaths() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing")
        let nonExecutable = try fixture.file(named: "not-executable", in: fixture.root, permissions: 0o644)
        let resolver = fixture.resolver(path: "")

        for value in ["", " \n", missing.path, nonExecutable.path] {
            #expect(throws: (any Error).self) {
                try resolver.save(value)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.configurationURL.path))
        }
    }

    @Test func saveRejectsDirectoryWithoutOverwritingOrCreatingFallback() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "tmux", in: fixture.root)
        let directory = try fixture.directory(named: "tmux-directory")
        let resolver = fixture.resolver(path: "")
        try resolver.save(executable.path)

        #expect(throws: (any Error).self) {
            try resolver.save(directory.path)
        }
        #expect(resolver.savedPath == executable.path)

        try resolver.clear()
        #expect(throws: (any Error).self) {
            try resolver.save(directory.path)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configurationURL.path))
    }

    @Test func clearRemovesFallbackAndIsIdempotent() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "tmux", in: fixture.root)
        let resolver = fixture.resolver(path: "")
        try resolver.save(executable.path)

        try resolver.clear()
        try resolver.clear()

        #expect(resolver.savedPath == nil)
        #expect(resolver.resolve() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.configurationURL.path))
    }

    @Test func clearRemovesDanglingConfigurationSymlink() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }
        let missingTarget = fixture.root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(
            at: fixture.configurationURL,
            withDestinationURL: missingTarget
        )
        let resolver = fixture.resolver(path: "")

        try resolver.clear()

        #expect(throws: (any Error).self) {
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configurationURL.path)
        }
    }

    @Test func emptyPathAndMissingFallbackDoNotSearchFixedLocations() throws {
        let fixture = try TmuxExecutableFixture()
        defer { fixture.remove() }

        #expect(fixture.resolver(path: "").resolve() == nil)
    }

    @Test func configurationFilePathHonorsExplicitTBDHome() {
        let file = TBDConstants.tmuxExecutablePathFile(
            environment: ["TBD_HOME": "/tmp/acme-tbd-home"]
        )

        #expect(file.path == "/tmp/acme-tbd-home/tmux-executable-path")
    }
}

private struct TmuxExecutableFixture {
    let root: URL
    let configurationURL: URL

    init(createConfigurationDirectory: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        configurationURL = root
            .appendingPathComponent("configuration", isDirectory: true)
            .appendingPathComponent("tmux-executable-path")
        if createConfigurationDirectory {
            try FileManager.default.createDirectory(
                at: configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: false
            )
        }
    }

    func resolver(path: String?) -> TmuxExecutableResolver {
        var environment: [String: String] = [:]
        if let path {
            environment["PATH"] = path
        }
        return TmuxExecutableResolver(
            environment: environment,
            configurationURL: configurationURL
        )
    }

    func directory(named name: String) throws -> URL {
        try directory(named: name, in: root)
    }

    func directory(named name: String, in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
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
