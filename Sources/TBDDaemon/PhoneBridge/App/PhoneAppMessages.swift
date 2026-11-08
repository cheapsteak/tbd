import Foundation
import TBDShared

// The app protocol's params, results and event data. Field names are the wire
// names. A nil optional is omitted from the JSON, never written as `null`.
// Timestamps are integer Unix milliseconds, named `…At`.
//
// Requests, with their params and result:
// - `sessions.subscribe` – SessionsSubscribeParams, SessionsSubscribeResult
// - `transcript.open` – TranscriptOpenParams, TranscriptOpenResult
// - `transcript.page` – TranscriptPageParams, TranscriptPage
// - `transcript.detail` – TranscriptDetailParams, TranscriptDetailResult
// - `transcript.close` – PhoneEmpty, PhoneEmpty
// - `message.send` – MessageSendParams, ActionOutcomeResult
// - `prompt.answer` – PhonePromptAnswerParams, PromptAnswerResult
// - `profiles.list` – PhoneEmpty, ProfilesListResult
// - `session.switchProfile` – SessionSwitchProfileParams, SessionRefResult
// - `session.fork` – SessionForkParams, SessionRefResult
// - `session.setModel` – SessionSetModelParams, ActionOutcomeResult
// - `worktree.create` – PhoneWorktreeCreateParams, PhoneWorktreeCreateResult
// - `remote.providers` – PhoneRemoteProvidersParams, PhoneRemoteProvidersResult
// - `remote.create` – PhoneRemoteCreateParams, SessionRefResult
//
// Events, with their data:
// - `sessions.changed` – SessionsChangedData
// - `transcript.append` and `transcript.update` – TranscriptItemsData
// - `transcript.reset` – TranscriptResetData
// - `prompt.changed` – PromptChangedData

// MARK: - Session reference

/// Which session a request or event is about: a local terminal, or a remote
/// session by its provider and the provider's session ID.
///
/// Wire shapes: `{"kind":"local","terminalID":"…"}` and
/// `{"kind":"remote","provider":"…","sessionID":"…"}`. Any other `kind` fails
/// to decode.
enum PhoneSessionRef: Hashable, Sendable {
    case local(terminalID: UUID)
    case remote(provider: String, sessionID: String)

    /// `local:<uuid>` or `remote:<provider>/<id>`, for log records.
    var targetDescription: String {
        switch self {
        case .local(let terminalID):
            return "local:\(terminalID.uuidString)"
        case .remote(let provider, let sessionID):
            return "remote:\(provider)/\(sessionID)"
        }
    }
}

extension PhoneSessionRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, terminalID, provider, sessionID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "local":
            self = .local(terminalID: try container.decode(UUID.self, forKey: .terminalID))
        case "remote":
            self = .remote(
                provider: try container.decode(String.self, forKey: .provider),
                sessionID: try container.decode(String.self, forKey: .sessionID))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown session kind \"\(kind)\"")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let terminalID):
            try container.encode("local", forKey: .kind)
            try container.encode(terminalID, forKey: .terminalID)
        case .remote(let provider, let sessionID):
            try container.encode("remote", forKey: .kind)
            try container.encode(provider, forKey: .provider)
            try container.encode(sessionID, forKey: .sessionID)
        }
    }
}

// MARK: - Session list

/// Whether a session supports one action, and if not, why not.
struct PhoneCapability: Codable, Equatable, Sendable {
    let available: Bool
    let reason: String?
}

struct PhoneCapabilities: Codable, Equatable, Sendable {
    let transcript: PhoneCapability
    let send: PhoneCapability
    let answer: PhoneCapability
    let switchProfile: PhoneCapability
    let fork: PhoneCapability
    let model: PhoneCapability
}

/// A session's status, as the laptop sidebar shows it.
enum PhoneStatusChip: String, Codable, CaseIterable, Sendable {
    case waitingForYou
    case working
    case idle
    case parked
    case rateLimited
    case error
    case exited
    case unknown
}

struct PhoneStatus: Codable, Equatable, Sendable {
    let chip: PhoneStatusChip
    /// When the chip last changed.
    let changedAt: Int64
    /// Why, for an error or a rate limit.
    let reason: String?
    /// When a rate limit lifts.
    let untilAt: Int64?
}

enum PhoneAgent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case remote
}

struct PhoneSession: Codable, Equatable, Sendable {
    let ref: PhoneSessionRef
    let agent: PhoneAgent
    let tabName: String
    let status: PhoneStatus
    let profileName: String?
    /// The session's model profile, matching `PhoneProfile.id` from
    /// `profiles.list`. Filled from the terminal's profile ID. Omitted when the
    /// session has none (a remote session, or a terminal on the default account
    /// with no profile).
    let profileID: UUID?
    /// The session's current model name, filled when the daemon knows it (for
    /// example from the transcript's latest assistant line). Omitted when
    /// unknown.
    let model: String?
    let capabilities: PhoneCapabilities
    /// The prompt waiting for an answer, if any.
    let openPromptID: String?
}

/// One row of the sessions list: a worktree with its sessions, or one remote
/// session.
struct PhoneRow: Codable, Equatable, Sendable {
    let id: String
    /// `worktree` or `remoteSession`.
    let kind: String
    let name: String
    let remote: Bool
    /// The newest `status.changedAt` among the row's sessions, or the row's
    /// own last change when it has none. The phone sorts rows by it, newest
    /// first, and repos by their newest row.
    let statusChangedAt: Int64
    let sessions: [PhoneSession]
}

/// A row's place in its group, in the laptop sidebar's order.
struct PhoneRowPlacement: Codable, Equatable, Sendable {
    let id: String
    let depth: Int
}

/// One group of the laptop sidebar with its rows in order. The phone may
/// ignore the order and sort by `PhoneRow.statusChangedAt`.
struct PhoneGroupLayout: Codable, Equatable, Sendable {
    let id: String
    /// `scratch`, `repo` or `provider`.
    let kind: String
    let name: String
    let rows: [PhoneRowPlacement]
}

// MARK: - sessions.subscribe and sessions.changed

struct SessionsSubscribeParams: Codable, Equatable, Sendable {
    /// The stream the phone saw before, with the last `seq` it saw.
    let stream: String?
    let sinceSeq: Int?
}

struct SessionsSubscribeResult: Codable, Equatable, Sendable {
    let stream: String
    let seq: Int
    /// True when the missed events were replayed in place of a snapshot.
    let replayed: Bool
    let layout: [PhoneGroupLayout]?
    let rows: [PhoneRow]?
    let omittedRows: Int
    let more: Bool
}

struct SessionsChangedData: Codable, Equatable, Sendable {
    /// Present only when the layout changed.
    let layout: [PhoneGroupLayout]?
    let rows: [PhoneRow]
    let removedRowIDs: [String]
}

// MARK: - Transcript items

enum PhoneItemKind: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case fileEdit
    case subagent
    case slash
    case peer
    case thinking
    case systemNote
}

/// One transcript row, shaped for the phone (spec section 7).
struct PhoneItem: Codable, Equatable, Sendable {
    let id: String
    let kind: PhoneItemKind
    let at: Int64?
    let text: String?
    /// True when `text` was cut and the rest is behind `transcript.detail`.
    let truncated: Bool
    let toolName: String?
    let target: String?
    /// `running`, `ok` or `error`.
    let toolStatus: String?
    let added: Int?
    let removed: Int?
    let agentType: String?
    let itemCount: Int?
    let sender: String?
}

struct TranscriptPage: Codable, Equatable, Sendable {
    let items: [PhoneItem]
    /// Asks for the page before this one. Absent once the start is reached.
    let cursor: String?
    let reachedStart: Bool
    let omittedItems: Int
}

// MARK: - Transcript requests

struct TranscriptOpenParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let showDetails: Bool
    let resume: Bool
}

struct TranscriptOpenResult: Codable, Equatable, Sendable {
    let resumed: Bool
    let seq: Int
    let page: TranscriptPage?
}

struct TranscriptPageParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let cursor: String
}

enum TranscriptDetailPart: String, Codable, CaseIterable, Sendable {
    case input
    case result
    case text
    case subagent
}

struct TranscriptDetailParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let itemID: String
    let part: TranscriptDetailPart
    let chunk: Int
}

struct TranscriptDetailResult: Codable, Equatable, Sendable {
    let itemID: String
    let part: TranscriptDetailPart
    let chunk: Int
    let chunkCount: Int
    let totalBytes: Int
    let tooLarge: Bool
    let text: String?
    let items: [PhoneItem]?
}

// MARK: - Transcript events

/// The data of `transcript.append` and `transcript.update`.
struct TranscriptItemsData: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let items: [PhoneItem]
}

struct TranscriptResetData: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    /// `rollover`, `rewrite` or `generation`.
    let reason: String
    let page: TranscriptPage
}

// MARK: - Prompts

struct PhoneOption: Codable, Equatable, Sendable {
    let label: String
    let description: String?
}

struct PhoneQuestion: Codable, Equatable, Sendable {
    let text: String
    let header: String?
    let multiSelect: Bool
    let options: [PhoneOption]
}

struct PhonePrompt: Codable, Equatable, Sendable {
    let id: String
    /// `question` or `permission`.
    let kind: String
    let toolName: String?
    let summary: String?
    let target: String?
    let targetTruncated: Bool
    let questions: [PhoneQuestion]?
    let suggestions: [String]?
    let allowAlways: Bool
}

/// Where a closed prompt was answered.
enum PhoneAnsweredBy: String, Codable, CaseIterable, Sendable {
    case phone
    case laptop
    case unknown
}

/// A prompt that closed since the last `prompt.changed` for its session.
struct PhonePromptResolution: Codable, Equatable, Sendable {
    let promptID: String
    let answeredBy: PhoneAnsweredBy
    /// The answering phone, set only when `answeredBy` is `phone`, and then
    /// absent when TBD cannot tell which phone answered: several phones'
    /// answers may have landed, and none is known to have.
    let deviceID: UUID?
}

struct PromptChangedData: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    /// The session's open prompts.
    let prompts: [PhonePrompt]
    /// Absent when no prompt closed.
    let resolved: [PhonePromptResolution]?
}

// MARK: - Actions

struct MessageSendParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let text: String
}

/// How a send ended: `sent`, `woken` or `unknown`.
struct ActionOutcomeResult: Codable, Equatable, Sendable {
    let outcome: String
}

/// `prompt.answer`'s params. The result is `PromptAnswerResult`.
///
/// The daemon hands `answer` to the core as it came, and the core checks it
/// against the prompt. The phone builds it exactly as the laptop's prompt card
/// does (`PromptAnswerController.questionAnswer` and `permissionAnswer`):
/// - **A question** is answered under its text, as `PhonePrompt.questions`
///   gives it. A single-select value is the chosen option's label, or the
///   "Other" text when "Other" is chosen and not blank: "Other" wins. A
///   multi-select value is the chosen labels in option order, then the
///   "Other" text when chosen, joined with ", ". Every question needs a
///   value.
/// - **A permission** is `allow`, `allow_always` (only where `allowAlways` is
///   offered) or `deny`. A deny may carry a reason of at most
///   `PhoneAppConstants.promptTextCap` UTF-8 bytes; one that is blank once
///   trimmed is sent as no reason.
struct PhonePromptAnswerParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let promptID: String
    let answer: PromptAnswer
}

struct ProfilesListResult: Codable, Equatable, Sendable {
    let profiles: [PhoneProfile]
}

/// A model profile, never with a token or other secret.
struct PhoneProfile: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: String
    let isDefault: Bool
}

struct SessionSwitchProfileParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let profileID: UUID
}

struct SessionForkParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    /// Nil forks under the session's own profile.
    let profileID: UUID?
}

/// The session an action produced or restarted.
struct SessionRefResult: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
}

struct SessionSetModelParams: Codable, Equatable, Sendable {
    let session: PhoneSessionRef
    let model: String
}

struct PhoneWorktreeCreateParams: Codable, Equatable, Sendable {
    let repoID: UUID
    let message: String
}

struct PhoneWorktreeCreateResult: Codable, Equatable, Sendable {
    let worktreeID: UUID
    /// Absent when the session was not ready in time.
    let session: PhoneSessionRef?
}

struct PhoneRemoteProvidersParams: Codable, Equatable, Sendable {
    /// The repo whose values prefill the providers' forms.
    let repoID: UUID?
}

struct PhoneRemoteProvidersResult: Codable, Equatable, Sendable {
    let providers: [PhoneProvider]
}

struct PhoneProvider: Codable, Equatable, Sendable {
    let name: String
    let available: Bool
    let reason: String?
    let acceptsPrompt: Bool
    let fields: [PhoneFormField]
}

/// One field of a provider's create form.
struct PhoneFormField: Codable, Equatable, Sendable {
    let name: String
    /// The provider's field type: `string`, `text`, `bool`, `int` or `enum`.
    let type: String
    let label: String?
    let required: Bool
    /// The choices of an `enum` field.
    let values: [String]?
    let prefill: String?
}

struct PhoneRemoteCreateParams: Codable, Equatable, Sendable {
    let provider: String
    let repoID: UUID
    let message: String
    let strings: [String: String]
    let bools: [String: Bool]
}
