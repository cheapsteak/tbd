import Testing
import Foundation
@testable import TBDShared

/// The receipt shape `retain`, `import`, and `delete --retain` all share
/// (`docs/remote-provider-contract.md` § `retain <id>` / `import`).
///
/// Decoded through `JSONDecoder.forRemoteProvider`, which is the decoder the
/// daemon actually hands provider stdout to — a bare `JSONDecoder()` would
/// exercise a path no provider output ever takes.
@Suite("RetainReceipt")
struct RetainReceiptTests {
    private func decode(_ json: String) throws -> RetainReceipt {
        try JSONDecoder.forRemoteProvider("agentbox")
            .decode(RetainReceipt.self, from: Data(json.utf8))
    }

    @Test func decodesKeyExpiryAndBytes() throws {
        let receipt = try decode(#"""
            {"key": "opaque-provider-string", "expires_at": "2026-10-01T00:00:00Z", "bytes": 148213}
            """#)
        #expect(receipt.key == "opaque-provider-string")
        #expect(receipt.bytes == 148_213)
        #expect(receipt.expiresAt == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
    }

    /// Absence is "the provider makes no claim". It decodes to nil, and nothing
    /// downstream may read nil as permanence.
    @Test func decodesWithoutExpiresAtAsNoClaim() throws {
        let receipt = try decode(#"{"key": "k", "bytes": 12}"#)
        #expect(receipt.expiresAt == nil)
        #expect(receipt.key == "k")
        #expect(receipt.bytes == 12)
    }

    /// `bytes` is how a truncated `recall` is detected, so a receipt without it
    /// cannot do its job — it must fail rather than default to zero, which
    /// would make every later short-read check pass vacuously.
    @Test func missingBytesIsADecodeFailure() {
        #expect(throws: (any Error).self) {
            try decode(#"{"key": "k", "expires_at": "2026-10-01T00:00:00Z"}"#)
        }
    }

    @Test func missingKeyIsADecodeFailure() {
        #expect(throws: (any Error).self) {
            try decode(#"{"bytes": 12}"#)
        }
    }

    /// Providers emit both RFC 3339 spellings; both must land on the same
    /// instant rather than one of them silently reading as "no claim".
    @Test func decodesFractionalSecondTimestamps() throws {
        let plain = try decode(#"{"key": "k", "expires_at": "2026-10-01T00:00:00Z", "bytes": 1}"#)
        let fractional = try decode(#"{"key": "k", "expires_at": "2026-10-01T00:00:00.000Z", "bytes": 1}"#)
        #expect(plain.expiresAt == fractional.expiresAt)
        #expect(plain.expiresAt != nil)
    }

    /// A present-but-unparseable timestamp degrades to "no claim" rather than
    /// to an invented instant. Inventing one in the past would disable Revive
    /// on a record the provider still holds.
    @Test func unparseableExpiresAtReadsAsNoClaim() throws {
        let receipt = try decode(#"{"key": "k", "expires_at": "next tuesday", "bytes": 1}"#)
        #expect(receipt.expiresAt == nil)
        #expect(receipt.bytes == 1)
    }

    /// Round-tripping must not change what the receipt means: the encoder
    /// re-emits RFC 3339, not a number of seconds.
    @Test func encodesExpiresAtAsRFC3339AndRoundTrips() throws {
        let original = RetainReceipt(
            key: "k", expiresAt: ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"), bytes: 9)
        let data = try JSONEncoder().encode(original)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("expires_at"))
        #expect(text.contains("2026-10-01T00:00:00Z"))
        let decoded = try JSONDecoder().decode(RetainReceipt.self, from: data)
        #expect(decoded == original)
    }

    @Test func encodesNoExpiresAtKeyWhenThereIsNoClaim() throws {
        let data = try JSONEncoder().encode(RetainReceipt(key: "k", bytes: 9))
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("expires_at") == false)
    }
}

/// `delete`'s response shape (`docs/remote-provider-contract.md` §
/// `delete <id> [--retain]`).
@Suite("RemoteDeleteResult")
struct RemoteDeleteResultTests {
    private func decode(_ json: String) throws -> RemoteDeleteResult {
        try JSONDecoder.forRemoteProvider("agentbox")
            .decode(RemoteDeleteResult.self, from: Data(json.utf8))
    }

    @Test func decodesWithoutRetained() throws {
        let result = try decode(#"{"id": "fix-flaky-ci", "deleted": true}"#)
        #expect(result.id == "fix-flaky-ci")
        #expect(result.deleted)
        #expect(result.retained == nil)
    }

    @Test func decodesWithRetainedReceipt() throws {
        let result = try decode(#"""
            {"id": "fix-flaky-ci", "deleted": true,
             "retained": {"key": "opaque", "expires_at": "2026-10-01T00:00:00Z", "bytes": 148213}}
            """#)
        #expect(result.retained?.key == "opaque")
        #expect(result.retained?.bytes == 148_213)
        #expect(result.retained?.expiresAt != nil)
    }

    /// Deleting an unknown or already-deleted id is idempotent: `deleted:
    /// false` decodes as an ordinary result, not an error.
    @Test func decodesDeletedFalseForAnUnknownID() throws {
        let result = try decode(#"{"id": "gone-already", "deleted": false}"#)
        #expect(result.deleted == false)
        #expect(result.retained == nil)
    }
}
