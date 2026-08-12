import Foundation
import TBDShared
import Testing
@testable import TBDApp

/// Tier 2: exercises only isolated filesystem configuration and executable fixtures.
@MainActor
@Suite("Tmux executable settings")
struct TmuxExecutableSettingsTests {
    @Test func backingFilePresentationAbbreviatesHomeAndPreservesCopyPath() {
        let presentation = TmuxConfigurationPathPresentation(
            configurationURL: URL(fileURLWithPath: "/Users/acme/tbd/tmux-executable-path"),
            homeDirectory: "/Users/acme"
        )

        #expect(presentation.displayPath == "~/tbd/tmux-executable-path")
        #expect(presentation.fullPath == "/Users/acme/tbd/tmux-executable-path")
    }

    @Test func missingExecutablePromptsOnlyOncePerAppStateLifetime() throws {
        try withFixture { fixture, state in
            #expect(state.tmuxExecutableResolution == nil)
            #expect(state.savedTmuxExecutablePath == nil)
            #expect(state.isTmuxLocationPromptPresented == false)

            state.checkTmuxAvailabilityAtStartup()
            #expect(state.isTmuxLocationPromptPresented)

            state.dismissTmuxLocationPrompt()
            state.checkTmuxAvailabilityAtStartup()
            #expect(state.isTmuxLocationPromptPresented == false)
        }
    }

    @Test func pathExecutableSuppressesStartupPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pathDirectory = try fixture.directory(named: "path")
        let executable = try fixture.executable(named: "tmux", in: pathDirectory)
        try withAppState(fixture: fixture, path: pathDirectory.path) { state in
            state.checkTmuxAvailabilityAtStartup()

            #expect(state.tmuxExecutableResolution == TmuxExecutableResolution(
                path: executable.path,
                source: .path
            ))
            #expect(state.isTmuxLocationPromptPresented == false)
        }
    }

    @Test func savedFallbackSuppressesStartupPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "saved-tmux", in: fixture.root)
        try fixture.resolver(path: "").save(executable.path)
        try withAppState(fixture: fixture, path: "") { state in
            state.checkTmuxAvailabilityAtStartup()

            #expect(state.savedTmuxExecutablePath == executable.path)
            #expect(state.tmuxExecutableResolution == TmuxExecutableResolution(
                path: executable.path,
                source: .savedFallback
            ))
            #expect(state.isTmuxLocationPromptPresented == false)
        }
    }

    @Test func savingValidFallbackRefreshesStateAndDismissesPrompt() throws {
        try withFixture { fixture, state in
            let executable = try fixture.executable(named: "saved-tmux", in: fixture.root)
            state.checkTmuxAvailabilityAtStartup()
            #expect(state.isTmuxLocationPromptPresented)

            try state.saveTmuxExecutableFallback(executable.path)

            #expect(state.savedTmuxExecutablePath == executable.path)
            #expect(state.tmuxExecutableResolution == TmuxExecutableResolution(
                path: executable.path,
                source: .savedFallback
            ))
            #expect(state.isTmuxLocationPromptPresented == false)
        }
    }

    @Test func invalidFallbackPreservesPriorValidValue() throws {
        try withFixture { fixture, state in
            let executable = try fixture.executable(named: "saved-tmux", in: fixture.root)
            try state.saveTmuxExecutableFallback(executable.path)

            #expect(throws: TmuxExecutableResolverError.self) {
                try state.saveTmuxExecutableFallback("relative/tmux")
            }

            #expect(state.savedTmuxExecutablePath == executable.path)
            #expect(state.tmuxExecutableResolution?.path == executable.path)
        }
    }

    @Test func clearingFallbackRefreshesWithoutReopeningStartupPrompt() throws {
        try withFixture { fixture, state in
            let executable = try fixture.executable(named: "saved-tmux", in: fixture.root)
            try state.saveTmuxExecutableFallback(executable.path)
            state.checkTmuxAvailabilityAtStartup()
            #expect(state.isTmuxLocationPromptPresented == false)

            try state.clearTmuxExecutableFallback()
            state.checkTmuxAvailabilityAtStartup()

            #expect(state.savedTmuxExecutablePath == nil)
            #expect(state.tmuxExecutableResolution == nil)
            #expect(state.isTmuxLocationPromptPresented == false)
        }
    }

    private func withFixture(_ body: (Fixture, AppState) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try withAppState(fixture: fixture, path: "") { state in
            try body(fixture, state)
        }
    }

    private func withAppState(
        fixture: Fixture,
        path: String,
        _ body: (AppState) throws -> Void
    ) throws {
        let suiteName = "TmuxExecutableSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            userDefaults: defaults,
            tmuxExecutableResolver: fixture.resolver(path: path)
        )
        try body(state)
    }
}

private struct Fixture {
    let root: URL
    let configurationURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxExecutableSettingsTests-\(UUID().uuidString)", isDirectory: true)
        configurationURL = root.appendingPathComponent("tmux-executable-path")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func resolver(path: String) -> TmuxExecutableResolver {
        TmuxExecutableResolver(
            environment: ["PATH": path],
            configurationURL: configurationURL
        )
    }

    func directory(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func executable(named name: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
