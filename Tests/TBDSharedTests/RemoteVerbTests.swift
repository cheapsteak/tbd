import Foundation
import Testing
@testable import TBDShared

/// The capability strings and argv the provider contract fixes
/// (`docs/remote-provider-contract.md` § Verbs, § `transcript read`, §
/// `send <id> [--submit]`). Pinned as literals rather than re-derived, because
/// a caller that spells a capability differently from the contract is a caller
/// that silently never offers the operation — a provider's unrecognized
/// strings are ignored, not rejected.
@Suite("RemoteVerb")
struct RemoteVerbTests {

    @Test func capabilityStringsMatchTheContract() {
        #expect(RemoteCapability.transcriptRead == "transcript.read")
        #expect(RemoteCapability.transcriptRetain == "transcript.retain")
        #expect(RemoteCapability.transcriptImport == "transcript.import")
        #expect(RemoteCapability.transcriptRecall == "transcript.recall")
        #expect(RemoteCapability.sendSubmit == "send-submit")
    }

    /// The bare pre-namespace spellings are not capabilities this build
    /// recognizes. A provider still declaring them loses those operations
    /// until it adopts the namespaced strings.
    @Test func bareSpellingsAreNotAmongTheNamespacedCapabilities() {
        let namespaced = [
            RemoteCapability.transcriptRead, RemoteCapability.transcriptRetain,
            RemoteCapability.transcriptImport, RemoteCapability.transcriptRecall,
        ]
        for bare in ["transcript", "retain", "import", "recall"] {
            #expect(!namespaced.contains(bare), "\(bare)")
        }
    }

    @Test func transcriptReadWithoutACursorFetchesFromTheBeginning() {
        #expect(RemoteVerb.transcriptRead(sessionID: "s-1")
            == ["transcript", "read", "s-1"])
    }

    @Test func transcriptReadWithACursorPassesItVerbatim() {
        #expect(RemoteVerb.transcriptRead(sessionID: "s-1", since: "opaque/cur sor")
            == ["transcript", "read", "s-1", "--since", "opaque/cur sor"])
    }

    @Test func transcriptRetainImportAndRecall() {
        #expect(RemoteVerb.transcriptRetain(sessionID: "s-1") == ["transcript", "retain", "s-1"])
        #expect(RemoteVerb.transcriptImport == ["transcript", "import"])
        #expect(RemoteVerb.transcriptRecall(key: "k/1") == ["transcript", "recall", "k/1"])
    }

    @Test func sendSubmitAppendsTheFlagAfterTheSessionID() {
        #expect(RemoteVerb.sendSubmit(sessionID: "s-1") == ["send", "s-1", "--submit"])
    }

    /// An id that looks like a flag is still an operand: the builders place
    /// it positionally and never reorder or drop it.
    @Test func aSessionIDThatLooksLikeAFlagStaysInPlace() {
        #expect(RemoteVerb.sendSubmit(sessionID: "--submit") == ["send", "--submit", "--submit"])
        #expect(RemoteVerb.transcriptRead(sessionID: "--since")
            == ["transcript", "read", "--since"])
    }
}

/// Wire shapes for the two RPCs the remote transcript pane and composer use.
@Suite("RemoteTranscriptSyncWire")
struct RemoteTranscriptSyncWireTests {

    @Test func methodNames() {
        #expect(RPCMethod.remoteTranscriptSync == "remote.transcriptSync")
        #expect(RPCMethod.remoteSendMessage == "remote.sendMessage")
        #expect(RPCMethod.configSetRemoteTranscriptEnabled == "config.setRemoteTranscriptEnabled")
    }

    /// Both are addressed by a provider name, so the cloud gate must cover them.
    @Test func bothAreProviderNamed() {
        #expect(RPCMethod.providerNamedRemoteMethods.contains(RPCMethod.remoteTranscriptSync))
        #expect(RPCMethod.providerNamedRemoteMethods.contains(RPCMethod.remoteSendMessage))
    }

    @Test func syncParamsRoundTrip() throws {
        let params = RemoteTranscriptSyncParams(provider: "acme", sessionID: "s-1")
        let decoded = try JSONDecoder().decode(
            RemoteTranscriptSyncParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.provider == "acme")
        #expect(decoded.sessionID == "s-1")
    }

    @Test func syncResultDecodesTheDocumentedKeys() throws {
        let json = #"{"path":"/tmp/x/transcript.jsonl","generation":3,"caughtUp":false}"#
        let result = try JSONDecoder().decode(
            RemoteTranscriptSyncResult.self, from: Data(json.utf8))
        #expect(result.path == "/tmp/x/transcript.jsonl")
        #expect(result.generation == 3)
        #expect(result.caughtUp == false)
    }

    @Test func sendMessageParamsRoundTrip() throws {
        let params = RemoteSendMessageParams(
            provider: "acme", sessionID: "s-1", text: "line one\nline two")
        let decoded = try JSONDecoder().decode(
            RemoteSendMessageParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.provider == "acme")
        #expect(decoded.sessionID == "s-1")
        #expect(decoded.text == "line one\nline two")
    }
}
