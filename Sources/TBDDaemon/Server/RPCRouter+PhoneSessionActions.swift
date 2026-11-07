import Foundation
import TBDShared

/// The router behind the phone bridge's one door (`PhoneSessionActions`).
///
/// Every method is one call to an existing core function or handler. It adds
/// nothing but the encoding of params for a handler that decodes them, with
/// the router's own `encoder` to match the router's own `decoder`, and the
/// phone's identity, built from the one `deviceID` it is given. So each runs
/// the checks of the RPC it mirrors, in that RPC's order, and returns that
/// RPC's response.
///
/// None of the handlers called here takes a socket connection, because none is
/// limited to the app at the socket edge. The three RPCs that are,
/// `prompt.answer`, `remote.answer` and a send without the dispatch marker,
/// are reached through the cores split out beneath their socket checks.
extension RPCRouter: PhoneSessionActions {
    func phoneSessionStates() async throws -> RPCResponse {
        try await handleSessionStates(encoder.encode(SessionStatesParams()))
    }

    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        try await answerPrompt(
            p, actor: .phone(deviceID: deviceID), authority: .pairedPhone(deviceID: deviceID))
    }

    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        try await answerRemotePrompt(
            p, actor: .phone(deviceID: deviceID), authority: .pairedPhone(deviceID: deviceID))
    }

    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse {
        try await sendFromPairedPhone(p, deviceID: deviceID)
    }

    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleTerminalWake(encoder.encode(p), actor: .phone(deviceID: deviceID))
    }

    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleTerminalSwapProfile(encoder.encode(p), actor: .phone(deviceID: deviceID))
    }

    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleWorktreeCreate(encoder.encode(p), actor: .phone(deviceID: deviceID))
    }

    func phoneRemoteProviders() async throws -> RPCResponse {
        try await handleRemoteProviders()
    }

    func phoneRemoteSessions() async throws -> RPCResponse {
        try await handleRemoteSessions()
    }

    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleRemoteCreate(encoder.encode(p), actor: .phone(deviceID: deviceID))
    }

    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleRemoteSendMessage(encoder.encode(p), actor: .phone(deviceID: deviceID))
    }

    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse {
        try await handleRemoteTranscriptSync(encoder.encode(p))
    }

    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse {
        try await handleRemoteTranscriptLoadEarlier(encoder.encode(p))
    }
}
