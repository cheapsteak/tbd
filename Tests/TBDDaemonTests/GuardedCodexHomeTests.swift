import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("Guarded Codex home")
struct GuardedCodexHomeTests {
    private func home(
        hooks: String = #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"exit 2"}]}]}}"#,
        config: String = "",
        profile: String? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-guarded-codex-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try hooks.write(to: url.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        try config.write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        if let profile {
            try profile.write(to: url.appendingPathComponent("tbd.config.toml"), atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test("a present command hook is accepted")
    func acceptsCommandHook() throws {
        let url = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        // Compare paths: the returned URL is marked as a directory, while
        // `url` lost that flag when it was resolved before the directory existed.
        #expect(try GuardedCodexHome.validate(url.path).path == url.path)
    }

    @Test("missing or unusable guard is rejected")
    func rejectsMissingGuard() throws {
        let url = try home(hooks: #"{"hooks":{"SessionStart":[]}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
    }

    @Test("explicitly disabled hook is rejected in either config layer")
    func rejectsDisabledHook() throws {
        let url = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        let key = "\(url.path)/hooks.json:pre_tool_use:0:0"
        let disabled = "[hooks.state.\"\(key)\"]\nenabled = false\n"
        try disabled.write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
        try "".write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try disabled.write(to: url.appendingPathComponent("tbd.config.toml"), atomically: true, encoding: .utf8)
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
    }

    @Test("either hook feature turned off in either config layer is rejected",
          arguments: ["hooks", "codex_hooks"])
    func rejectsHooksFeatureOff(feature: String) throws {
        let url = try home(config: "[features]\n\(feature) = false\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
        try "[features]\n\(feature) = true\n".write(
            to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(try GuardedCodexHome.validate(url.path).path == url.path)
        try "[features]\n\(feature) = false\n".write(
            to: url.appendingPathComponent("tbd.config.toml"), atomically: true, encoding: .utf8)
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
    }

    @Test("malformed config and linked hook file fail closed")
    func rejectsUnreadableConfiguration() throws {
        let url = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        try "[hooks\n".write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
        try "".write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let hook = url.appendingPathComponent("hooks.json")
        let target = url.appendingPathComponent("source.json")
        try FileManager.default.moveItem(at: hook, to: target)
        try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: target)
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.validate(url.path)
        }
    }

    @Test("TBD writes its profile only into a home that passes the check")
    func ensureProfileWritesNothingIntoAnUnguardedHome() throws {
        let url = try home(hooks: #"{"hooks":{"SessionStart":[]}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: GuardedCodexHome.ValidationError.self) {
            try GuardedCodexHome.ensureProfile(in: url.path)
        }
        #expect(!FileManager.default.fileExists(
            atPath: url.appendingPathComponent("tbd.config.toml").path))
    }

    @Test("TBD's own profile write leaves a guarded home passing the check")
    func ensureProfileKeepsTheGuard() throws {
        let url = try home()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try GuardedCodexHome.ensureProfile(in: url.path).path == url.path)
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("tbd.config.toml").path))
    }

    @Test("a refusal reads the same whether returned or thrown through the router")
    func validationErrorDescribesItself() {
        let error = GuardedCodexHome.ValidationError.invalid("config.toml is missing")
        #expect("\(error)" == "Guarded Codex home: config.toml is missing")
        #expect(error.localizedDescription == "\(error)")
    }

    @Test("a dedicated home alone is worth recording, and an old row without one reads as nil")
    func launchOptionsCarryTheHome() throws {
        let options = try #require(CodexLaunchOptions.recorded(
            model: nil, disabledFeatures: [], codexHome: "/synthetic/home"))
        #expect(options.codexHome == "/synthetic/home")
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(CodexLaunchOptions.self, from: data) == options)
        let old = try JSONDecoder().decode(
            CodexLaunchOptions.self, from: Data(#"{"model":"acme","disabledFeatures":[]}"#.utf8))
        #expect(old.codexHome == nil)
        #expect(CodexLaunchOptions.recorded(model: nil, disabledFeatures: []) == nil)
    }
}
