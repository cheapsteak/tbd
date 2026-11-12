import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("Codex rollout provenance")
struct CodexRolloutProvenanceTests {
    private func withRollout(_ contents: String, body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-provenance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rollout.jsonl")
        try Data(contents.utf8).write(to: path)
        try body(path)
    }

    @Test("nonempty scalar source proves a complete top-level metadata record")
    func topLevelProof() throws {
        try withRollout("broken json\n" + #"{"type":"session_meta","payload":{"source":"cli"}}"# + "\n") { path in
            guard case let .topLevel(proof) = CodexRolloutProvenance.classify(path: path.deletingLastPathComponent().path + "/./rollout.jsonl") else {
                Issue.record("expected top-level proof")
                return
            }
            #expect(proof.path == path.path)
            #expect(proof.isCurrent())
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"event_msg\"}\n".utf8))
            try handle.close()
            #expect(proof.isCurrent(), "normal transcript growth keeps metadata proof current")
        }
    }

    @Test("unsupported source never proves top-level", arguments: ["null", "{}", "[]", "\"\"", "\"  \"", "true", "42"])
    func unsupportedSource(source: String) throws {
        try withRollout("{\"type\":\"session_meta\",\"payload\":{\"source\":\(source)}}\n") { path in
            guard case .unproven = CodexRolloutProvenance.classify(path: path.path) else {
                Issue.record("unsupported source should remain unproven")
                return
            }
        }
    }

    @Test("subagent object excludes the rollout")
    func subagent() throws {
        try withRollout(#"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"# + "\n") { path in
            guard case .subagent = CodexRolloutProvenance.classify(path: path.path) else {
                Issue.record("expected subagent")
                return
            }
        }
    }

    @Test("missing, partial, and first unsupported metadata remain unproven", arguments: [
        "broken\n", #"{"type":"session_meta","payload":{"source":"cli"}}"#,
        #"{"type":"session_meta","payload":{}}"# + "\n" + #"{"type":"session_meta","payload":{"source":"cli"}}"# + "\n"
    ])
    func missingMetadata(contents: String) throws {
        try withRollout(contents) { path in
            guard case .unproven = CodexRolloutProvenance.classify(path: path.path) else {
                Issue.record("expected unproven")
                return
            }
        }
    }

    @Test("missing and nonregular files remain unproven")
    func unreadableFile() {
        for path in ["/tmp/tbd-provenance-missing-\(UUID())", FileManager.default.temporaryDirectory.path] {
            guard case .unproven = CodexRolloutProvenance.classify(path: path) else {
                Issue.record("expected unproven")
                continue
            }
        }
    }

    @Test("an unreadable rollout remains unproven")
    func permissionDenied() throws {
        try withRollout(#"{"type":"session_meta","payload":{"source":"cli"}}"# + "\n") { path in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
            guard case .unproven = CodexRolloutProvenance.classify(path: path.path) else {
                Issue.record("unreadable file must not prove top-level provenance")
                return
            }
        }
    }

    @Test("metadata beyond the bounded header remains unproven")
    func boundedRead() throws {
        try withRollout(String(repeating: "x", count: 1_048_576) + "\n"
            + #"{"type":"session_meta","payload":{"source":"cli"}}"# + "\n") { path in
            guard case .unproven = CodexRolloutProvenance.classify(path: path.path) else {
                Issue.record("must bound malformed input before metadata")
                return
            }
        }
    }

    @Test("replacing the file or rewriting its metadata invalidates proof", arguments: [false, true])
    func staleProof(replace: Bool) throws {
        let initial = #"{"type":"session_meta","payload":{"source":"cli"}}"# + "\n"
        try withRollout(initial) { path in
            guard case let .topLevel(proof) = CodexRolloutProvenance.classify(path: path.path) else {
                Issue.record("expected top-level proof")
                return
            }
            if replace {
                try Data(initial.utf8).write(to: path, options: .atomic)
            } else {
                try Data((#"{"type":"session_meta","payload":{"source":"exec"}}"# + "\n").utf8).write(to: path)
            }
            #expect(!proof.isCurrent())
        }
    }
}
