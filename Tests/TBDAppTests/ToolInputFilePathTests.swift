import Foundation
import Testing

@testable import TBDApp

@Suite("ToolInputFilePath")
struct ToolInputFilePathTests {
    @Test func well_formed_json() {
        let json = #"{"file_path":"/Users/me/foo.swift","content":"hello"}"#
        #expect(ToolInputFilePath.extract(from: json) == "/Users/me/foo.swift")
    }

    @Test func truncated_mid_content() {
        // Truncated inside the `content` string — JSON is structurally invalid,
        // but `file_path` already serialized in full.
        let json = #"{"file_path":"/Users/me/big.txt","content":"line1\nline2\nline3"#
        #expect(ToolInputFilePath.extract(from: json) == "/Users/me/big.txt")
    }

    @Test func file_path_after_other_field() {
        let json = #"{"old_string":"foo","file_path":"/tmp/x.swift","new_string":"bar"}"#
        #expect(ToolInputFilePath.extract(from: json) == "/tmp/x.swift")
    }

    @Test func missing_file_path_returns_nil() {
        let json = #"{"command":"ls -la","description":"list"}"#
        #expect(ToolInputFilePath.extract(from: json) == nil)
    }

    @Test func escaped_path_returns_nil() {
        // We bail out on backslashes; let full-input fetch resolve it.
        let json = #"{"file_path":"/tmp/with\"quote.swift","content":"x"}"#
        #expect(ToolInputFilePath.extract(from: json) == nil)
    }
}
