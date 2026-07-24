import Testing
import Foundation
@testable import TBDShared

@Suite("RemoteProvider contract types")
struct RemoteProviderTests {
    @Test func sessionPayloadDecodesSnakeCaseAndTolerantEnums() throws {
        let json = """
        {"id": "fix-ci", "title": "fix CI", "created_at": "2026-07-24T18:02:11Z",
         "state": "running", "agent_state": "waiting_input",
         "agent_state_reason": "permission_prompt", "agent_state_at": "2026-07-24T18:40:00Z",
         "meta": {"repo": "acme/api"}, "some_future_field": 42}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.id == "fix-ci")
        #expect(s.state == .running)
        #expect(s.agentState == .waitingInput)
        #expect(s.agentStateReason == "permission_prompt")
        #expect(s.meta?["repo"] == "acme/api")
    }

    @Test func unknownEnumValuesDecodeAsUnknown() throws {
        let json = #"{"id": "x", "state": "hibernating", "agent_state": "pondering"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.state == .unknown)
        #expect(s.agentState == .unknown)
    }

    @Test func missingAgentStateDecodesAsUnknown() throws {
        let json = #"{"id": "x", "state": "running"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.agentState == .unknown)
    }

    @Test func describeDecodesCreateParams() throws {
        let json = """
        {"contract_versions": [1], "name": "example", "provider_version": "0.1.0",
         "capabilities": ["log", "attach"],
         "create_params": [
           {"name": "repo", "type": "string", "label": "Repository", "required": true},
           {"name": "size", "type": "enum", "label": "Size", "values": ["small","large"], "default": "small"}]}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ProviderDescribe.self, from: json)
        #expect(d.contractVersions == [1])
        #expect(d.capabilities.contains("log"))
        #expect(d.createParams[0].required == true)
        #expect(d.createParams[1].values == ["small", "large"])
        #expect(d.createParams[1].defaultValue == "small")
    }

    @Test func errorEnvelopeDecodes() throws {
        let json = """
        {"error": {"code": "auth_expired", "message": "token expired", "retryable": false,
                   "remediation": {"label": "Run login", "command": "aws sso login --profile acme"}}}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(ProviderErrorEnvelope.self, from: json)
        #expect(e.error.code == "auth_expired")
        #expect(e.error.remediation?.command == "aws sso login --profile acme")
    }

    @Test func registryLoadsAndValidates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "example", "exec": "/usr/local/bin/example", "args": ["provider"]}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        let configs = try RemoteProviderRegistry.load(from: file)
        #expect(configs.count == 1)
        #expect(configs[0].name == "example")
        // Missing file → empty list, not an error.
        #expect(try RemoteProviderRegistry.load(from: dir.appendingPathComponent("nope.json")).isEmpty)
        // Duplicate names → throws.
        try #"[{"name": "a", "exec": "/x"}, {"name": "a", "exec": "/y"}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try RemoteProviderRegistry.load(from: file) }
    }

    @Test func registryRejectsEmptyExec() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "example", "exec": ""}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: RemoteProviderRegistry.RegistryError.invalidEntry("example")) {
            try RemoteProviderRegistry.load(from: file)
        }
    }

    @Test func registryRejectsEmptyName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "", "exec": "/usr/local/bin/example"}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: RemoteProviderRegistry.RegistryError.invalidEntry("")) {
            try RemoteProviderRegistry.load(from: file)
        }
    }

    @Test func registryRejectsNonArrayJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"{"name": "x"}"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try RemoteProviderRegistry.load(from: file) }
    }

    @Test func agentProvidersPathHonorsTBDHome() {
        let path = TBDConstants.agentProvidersPath(environment: ["TBD_HOME": "/tmp/tbd-test-home"])
        #expect(path == "/tmp/tbd-test-home/agent-providers.json")
    }
}
