import Foundation
import os
import TBDShared

// `prompt.answer` and `prompt.changed` (spec section 4.4, "Open prompts", and
// section 5's "Answer").
//
// The parts, each a unit the transcript feed takes over:
// - `PhonePromptShaper` turns an open prompt into a `PhonePrompt`, and fits a
//   `prompt.changed` into one frame.
// - `PhonePromptAnswerLedger` records which phone is answering, or answered,
//   which prompt, for `answeredBy`.
// - `PhonePromptSet` and `PhonePromptAttribution` turn the set the phone was
//   last sent and the set open now into a `PromptChangedData`, or nil.
// - `PhoneLocalPromptSource` reads a local terminal's open prompts again on
//   every `.terminalPendingPromptsChanged` for it.
// - `PhonePromptFeed`, in `PhoneDeviceState.prompts`, ties them to one device's
//   open session, through `openPrompts(_:for:)` and `closePrompts(for:)`.

// MARK: - Shaping

/// Turns an open prompt into what the phone shows: the fields the laptop's
/// prompt cards draw (`PermissionPromptCard`, `InteractiveQuestionCard`).
///
/// **Caps are on encoded bytes.** Each text is cut, at a character boundary,
/// so its JSON string body under `PhoneAppCoding.makeEncoder()` is at most its
/// cap: question text and a permission's summary and target at
/// `PhoneAppConstants.promptTextCap`, an option's description and a suggestion
/// line at `promptOptionCap`, a header and a tool name at
/// `PhoneText.fieldLimit`. Measuring the escaped length rather than the UTF-8
/// length is what bounds a frame: a quote takes two bytes once encoded, and a
/// control character six.
///
/// **What an answer is keyed on is never rewritten.** An answer names a
/// question by its text and picks an option by its label.
/// `PromptDecisionEncoder` checks the text against the prompt, but carries a
/// value through as written. So:
/// - a question whose text was cut is still shown, and an answer keyed on the
///   cut text is refused by the core as naming a question the prompt does not
///   have, so nothing is delivered;
/// - an option whose label is over `promptOptionCap` is left out rather than
///   cut, because a cut label sent back would answer with words that are not
///   the option's. The phone can still type it as "Other".
///
/// No count is capped: a prompt with more questions, options or suggestions
/// than one frame holds is left out of `prompt.changed` whole
/// (`fitted(_:budget:)`), never shown in part.
enum PhonePromptShaper {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// A local prompt from `PendingPromptStore`. Its questions are the ones
    /// `PromptQuestionParser.questions(fromAskUserQuestionInput:)` reads, the
    /// same the core validates an answer against.
    static func local(_ p: PendingPromptPayload) -> PhonePrompt {
        let toolName = p.toolName.isEmpty ? nil : p.toolName
        switch p.kind {
        case .question:
            return question(
                id: p.id, toolName: toolName,
                questions: PromptQuestionParser.questions(fromAskUserQuestionInput: p.toolInputJSON) ?? [])
        case .permission:
            return permission(
                id: p.id, toolName: toolName, toolInputJSON: p.toolInputJSON, inputTruncated: false,
                suggestionsJSON: p.suggestionsJSON)
        }
    }

    /// A remote session's `pending_prompt`. Its questions are
    /// `effectiveQuestions`, the ones `remote.answer` validates against. The
    /// target counts as truncated when the provider cut the tool's input or
    /// left it out.
    static func remote(_ p: RemotePendingPrompt) -> PhonePrompt {
        let toolName = p.toolName.flatMap { $0.isEmpty ? nil : $0 }
        switch p.kind {
        case .question:
            return question(id: p.id, toolName: toolName, questions: p.effectiveQuestions)
        case .permission:
            return permission(
                id: p.id, toolName: toolName, toolInputJSON: p.toolInputJSON,
                inputTruncated: p.toolInputTruncated, suggestionsJSON: p.suggestionsJSON)
        }
    }

    private static func question(id: String, toolName: String?, questions: [PromptQuestion]) -> PhonePrompt {
        PhonePrompt(
            id: id, kind: PendingPromptKind.question.rawValue,
            toolName: toolName.map { cut($0, to: PhoneText.fieldLimit).text },
            summary: nil, target: nil, targetTruncated: false,
            questions: questions.map(shaped), suggestions: nil, allowAlways: false)
    }

    private static func shaped(_ question: PromptQuestion) -> PhoneQuestion {
        PhoneQuestion(
            text: cut(question.text, to: PhoneAppConstants.promptTextCap).text,
            header: question.header.map { cut($0, to: PhoneText.fieldLimit).text },
            multiSelect: question.multiSelect,
            options: question.options.compactMap { option in
                guard escapedLength(option.label) <= PhoneAppConstants.promptOptionCap else { return nil }
                return PhoneOption(
                    label: option.label,
                    description: option.description.map { cut($0, to: PhoneAppConstants.promptOptionCap).text })
            })
    }

    /// A permission prompt:
    /// - `summary` is `TranscriptParser.toolInputSummary(name:input:)`;
    /// - `target` is `target(input:toolInputJSON:)`, cut to `promptTextCap`,
    ///   with `targetTruncated` when it was cut or the provider cut the input;
    /// - `suggestions` is `PermissionSuggestionSummary.lines(fromJSON:)`,
    ///   omitted when there are none;
    /// - `allowAlways` is whether there are suggestions: the laptop card's
    ///   "Yes, and don't ask again this session", and exactly when the core
    ///   accepts `allow_always`.
    private static func permission(
        id: String, toolName: String?, toolInputJSON: String?, inputTruncated: Bool, suggestionsJSON: String?
    ) -> PhonePrompt {
        let input = toolInputJSON.flatMap(inputObject)
        let summary = TranscriptParser.toolInputSummary(name: toolName ?? "", input: input ?? [:])
        let preview = Self.target(input: input, toolInputJSON: toolInputJSON)
            .map { cut($0, to: PhoneAppConstants.promptTextCap) }
        let suggestions = PermissionSuggestionSummary.lines(fromJSON: suggestionsJSON)
            .map { cut($0, to: PhoneAppConstants.promptOptionCap).text }
        return PhonePrompt(
            id: id, kind: PendingPromptKind.permission.rawValue,
            toolName: toolName.map { cut($0, to: PhoneText.fieldLimit).text },
            summary: summary.isEmpty ? nil : cut(summary, to: PhoneAppConstants.promptTextCap).text,
            target: preview?.text,
            targetTruncated: (preview?.cut ?? false) || inputTruncated,
            questions: nil,
            suggestions: suggestions.isEmpty ? nil : suggestions,
            allowAlways: !suggestions.isEmpty)
    }

    /// What the laptop's permission card previews: the input's `command`,
    /// else its `file_path`, else the whole input as compact sorted-key JSON.
    /// The input as it came when it does not parse, and nil with no input.
    static func target(input: [String: Any]?, toolInputJSON: String?) -> String? {
        if let command = input?["command"] as? String, !command.isEmpty { return command }
        if let path = input?["file_path"] as? String, !path.isEmpty { return path }
        guard let toolInputJSON, !toolInputJSON.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(toolInputJSON.utf8)),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let compact = String(data: data, encoding: .utf8) else {
            return toolInputJSON
        }
        return compact
    }

    private static func inputObject(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    // MARK: Cutting

    /// `text` cut at a character boundary so its JSON string body, without
    /// quotes, is at most `limit` bytes, and whether anything was cut.
    static func cut(_ text: String, to limit: Int) -> (text: String, cut: Bool) {
        guard escapedLength(text) > limit else { return (text, false) }
        var kept = ""
        var used = 0
        for character in text {
            let width = escapedLength(String(character))
            guard used + width <= limit else { break }
            kept.append(character)
            used += width
        }
        return (kept, true)
    }

    /// The bytes `text` takes as a JSON string body, without quotes
    /// (`PhoneFrameBudget.escapedLength`).
    static func escapedLength(_ text: String) -> Int {
        PhoneFrameBudget.escapedLength(text[...].unicodeScalars)
    }

    // MARK: Fitting a frame

    /// The bytes `,"resolved":[]` add to an event's data.
    private static let resolvedFieldBytes = #","resolved":[]"#.utf8.count

    /// `data` as it fits `budget` bytes of encoded event data, so the event
    /// fits one frame.
    ///
    /// Data that fits is returned as it is. Otherwise the prompts are kept in
    /// order, oldest first, up to the first that does not fit, and then the
    /// resolutions likewise: a prompt is never shown in part, and the newest
    /// are left out until an older one closes. A prompt left out was never
    /// sent, so its closing is never reported. A resolution left out is
    /// lost; the phone still sees its prompt leave the set.
    ///
    /// The shaper's caps keep one prompt of four questions with four options
    /// each, every text at its cap, well inside `PhoneFrameBudget.eventDataBytes`
    /// with room for dozens of resolutions; only a prompt larger than the
    /// AskUserQuestion tool accepts, or several large ones at once, comes here.
    static func fitted(_ data: PromptChangedData, budget: Int = PhoneFrameBudget.eventDataBytes) -> PromptChangedData {
        let encoder = PhoneAppCoding.makeEncoder()
        func size<T: Encodable>(_ value: T) -> Int {
            (try? encoder.encode(value).count) ?? Int.max / 4
        }
        if size(data) <= budget { return data }
        var used = size(PromptChangedData(session: data.session, prompts: [], resolved: nil))
        var prompts: [PhonePrompt] = []
        for prompt in data.prompts {
            let cost = size(prompt) + (prompts.isEmpty ? 0 : 1)
            guard used + cost <= budget else { break }
            prompts.append(prompt)
            used += cost
        }
        var resolved: [PhonePromptResolution] = []
        for resolution in data.resolved ?? [] {
            let cost = size(resolution) + (resolved.isEmpty ? resolvedFieldBytes : 1)
            guard used + cost <= budget else { break }
            resolved.append(resolution)
            used += cost
        }
        let leftOutPrompts = data.prompts.count - prompts.count
        let leftOutResolutions = (data.resolved?.count ?? 0) - resolved.count
        logger.notice(
            "Phone prompts: left out \(leftOutPrompts, privacy: .public) prompts and \(leftOutResolutions, privacy: .public) resolutions to fit a prompt.changed into one frame")
        return PromptChangedData(session: data.session, prompts: prompts, resolved: resolved.isEmpty ? nil : resolved)
    }
}

// MARK: - Who answered

/// Which phones are answering, or have answered, which prompts, across every
/// device the service serves, for `prompt.changed`'s `answeredBy`.
///
/// `prompt.answer` begins an attempt before it calls the core and finishes it
/// when the core replies. An attempt whose answer was `delivered`, or may have
/// been (`unknown`), settles and is kept; one that met `already_resolved` or
/// an error is dropped. Several phones may answer one prompt at once, each
/// with an attempt of its own; a prompt takes one answer, so at most one of
/// them is kept.
///
/// **Bounded.** Running attempts are bounded by the requests a device may have
/// in flight. A kept attempt is dropped `lifetime` after it settled, and at
/// most `settledLimit` are kept, the oldest dropped first. A prompt ID names
/// one dialog for its life, so an attempt kept a while after its prompt
/// closed matches no later prompt.
struct PhonePromptAnswerLedger: Sendable {
    struct Key: Hashable, Sendable {
        let session: PhoneSessionRef
        let promptID: String
    }

    private struct Attempt: Sendable {
        let token: UInt64
        let deviceID: UUID
        /// When the attempt settled and was kept; nil while its call runs.
        var settledAt: Date?
    }

    private struct Settled: Sendable {
        let key: Key
        let token: UInt64
        let at: Date
    }

    /// The most kept attempts.
    static let settledLimit = 256
    /// How long a kept attempt lasts, in seconds: the request memory's 10
    /// minutes, long past its prompt's closing.
    static let lifetime: TimeInterval = 600

    private var attempts: [Key: [Attempt]] = [:]
    /// The kept attempts, in the order they settled.
    private var settledOrder: [Settled] = []
    /// Reads waiting for a prompt's running attempts to finish.
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    /// A phone's answer to the prompt under `key` is about to reach the core.
    mutating func begin(_ key: Key, token: UInt64, deviceID: UUID, now: Date) {
        prune(now: now)
        attempts[key, default: []].append(Attempt(token: token, deviceID: deviceID, settledAt: nil))
    }

    /// The attempt `token` finished: kept with `keep`, dropped otherwise.
    /// Returns the waiters to resume, once no attempt on `key` still runs.
    mutating func finish(_ key: Key, token: UInt64, keep: Bool, now: Date) -> [CheckedContinuation<Void, Never>] {
        if var list = attempts[key], let index = list.firstIndex(where: { $0.token == token }) {
            if keep {
                list[index].settledAt = now
                settledOrder.append(Settled(key: key, token: token, at: now))
            } else {
                list.remove(at: index)
            }
            attempts[key] = list.isEmpty ? nil : list
        }
        prune(now: now)
        guard !isAnswering(key) else { return [] }
        return waiters.removeValue(forKey: key) ?? []
    }

    /// Whether a phone's answer to the prompt under `key` is still running.
    func isAnswering(_ key: Key) -> Bool {
        attempts[key]?.contains { $0.settledAt == nil } ?? false
    }

    /// The phone whose answer to the prompt under `key` was kept.
    func answeredBy(_ key: Key) -> UUID? {
        attempts[key]?.first { $0.settledAt != nil }?.deviceID
    }

    /// Waits on `key`'s running attempts. Call only while `isAnswering(key)`.
    mutating func wait(_ key: Key, _ continuation: CheckedContinuation<Void, Never>) {
        waiters[key, default: []].append(continuation)
    }

    /// How many reads are waiting. For tests.
    var waiterCount: Int {
        waiters.values.reduce(0) { $0 + $1.count }
    }

    private mutating func prune(now: Date) {
        while let oldest = settledOrder.first,
              settledOrder.count > Self.settledLimit || now.timeIntervalSince(oldest.at) > Self.lifetime {
            settledOrder.removeFirst()
            guard var list = attempts[oldest.key] else { continue }
            list.removeAll { $0.token == oldest.token }
            attempts[oldest.key] = list.isEmpty ? nil : list
        }
    }
}

/// What tells who answered each prompt that closed.
///
/// `answeredBy` is:
/// - **`phone`, with its device**, when a phone's answer to it was kept by the
///   ledger. For a local prompt, only when the store says TBD's decision
///   reached Claude (`answered`), or has no record of how it ended.
/// - **`laptop`** for a local prompt the terminal answered
///   (`answeredInTerminal`), or that TBD's decision ended with no phone's
///   answer kept (`answered`): the laptop's TBD app answered it.
/// - **`unknown`** otherwise: the terminal or session ended, the mod went
///   away, the daemon stopped, or nothing records how it ended. A remote
///   prompt is `unknown` unless a phone answered it, as nothing else records
///   who answered one.
struct PhonePromptAttribution: Sendable, Equatable {
    /// The phone whose answer the ledger kept, by prompt ID.
    var phoneAnswers: [String: UUID] = [:]
    /// How the store resolved each recently closed local prompt, by prompt
    /// ID. Nil for a remote session.
    var localResolutions: [String: PendingPromptStore.Resolution]?

    func resolution(of promptID: String) -> PhonePromptResolution {
        let phone = phoneAnswers[promptID]
        let laptop = PhonePromptResolution(promptID: promptID, answeredBy: .laptop, deviceID: nil)
        let unknown = PhonePromptResolution(promptID: promptID, answeredBy: .unknown, deviceID: nil)
        let byPhone = phone.map { PhonePromptResolution(promptID: promptID, answeredBy: .phone, deviceID: $0) }
        guard let localResolutions else {
            return byPhone ?? unknown
        }
        switch localResolutions[promptID] {
        case .some(.answered):
            return byPhone ?? laptop
        case .none:
            return byPhone ?? unknown
        case .some(.answeredInTerminal):
            return laptop
        case .some(.terminalGone), .some(.sessionEnded), .some(.modDisconnected), .some(.daemonShutdown):
            return unknown
        }
    }
}

// MARK: - The set the phone has

/// One open session's prompts as the phone was last sent them, and the
/// `prompt.changed` that brings the phone to the set open now.
struct PhonePromptSet: Sendable {
    let session: PhoneSessionRef
    /// The prompts last sent, as fitted into their frame; nil before the
    /// first `prompt.changed`.
    private(set) var sent: [PhonePrompt]?

    init(session: PhoneSessionRef) {
        self.session = session
    }

    /// The IDs of the prompts last sent that `current` no longer holds, in
    /// the order they were sent.
    func closedIDs(in current: [PhonePrompt]) -> [String] {
        let open = Set(current.map(\.id))
        return (sent ?? []).map(\.id).filter { !open.contains($0) }
    }

    /// The `prompt.changed` data that brings the phone from `sent` to
    /// `current`, the full set, fitted into one frame, with a resolution for
    /// every prompt that closed; or nil when the phone has that set already.
    /// The first call always returns data, an empty set included, so the
    /// phone learns the set as soon as the session opens.
    mutating func advance(to current: [PhonePrompt], attribution: PhonePromptAttribution) -> PromptChangedData? {
        let resolved = closedIDs(in: current).map { attribution.resolution(of: $0) }
        let data = PhonePromptShaper.fitted(PromptChangedData(
            session: session, prompts: current, resolved: resolved.isEmpty ? nil : resolved))
        if let sent, sent == data.prompts {
            return nil
        }
        sent = data.prompts
        return data
    }
}

// MARK: - A local session's source

/// The open prompts of one local terminal, read again whenever its set
/// changes.
///
/// A `.terminalPendingPromptsChanged` for the terminal is only a wakeup: the
/// set is read from `PendingPromptStore` itself, with how each recently
/// closed prompt ended, so a delta that arrives out of order cannot bring an
/// old set back. One task reads and delivers, one read at a time, and a
/// wakeup that comes while it works makes one more read, so the last read
/// always follows the last change. `start()` reads once at once.
///
/// `stop()` removes the subscriber and ends the work for good; a later
/// `start()` does nothing.
actor PhoneLocalPromptSource {
    typealias Delivery = @Sendable (
        _ open: [PendingPromptPayload], _ resolved: [String: PendingPromptStore.Resolution]
    ) async -> Void

    /// The bytes every `.terminalPendingPromptsChanged` delta holds, checked
    /// before a delta is decoded.
    private static let marker = Data(#""terminalPendingPromptsChanged""#.utf8)

    private let terminalID: UUID
    private let store: PendingPromptStore
    private let subscriptions: StateSubscriptionManager
    private let deliver: Delivery
    private var subscriberID: StateSubscriptionManager.SubscriberID?
    private var wakeups: AsyncStream<Void>.Continuation?
    private var consumer: Task<Void, Never>?
    private var stopped = false

    init(terminalID: UUID, store: PendingPromptStore, subscriptions: StateSubscriptionManager,
         deliver: @escaping Delivery) {
        self.terminalID = terminalID
        self.store = store
        self.subscriptions = subscriptions
        self.deliver = deliver
    }

    /// Whether the source is subscribed to state deltas: between `start`
    /// and `stop`. For tests.
    var isSubscribed: Bool {
        subscriberID != nil
    }

    /// Subscribes to state deltas and reads the set once. Does nothing once
    /// started or stopped.
    func start() {
        guard !stopped, consumer == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = continuation
        let terminalID = self.terminalID
        subscriberID = subscriptions.addSubscriber { data in
            if Self.isPromptChange(data, for: terminalID) {
                continuation.yield()
            }
            return true
        }
        // The first read, after the subscriber is in place, so no change
        // falls between them.
        continuation.yield()
        let store = self.store
        let deliver = self.deliver
        consumer = Task {
            for await _ in stream {
                let state = await store.promptsAndResolutions(forTerminal: terminalID)
                guard !Task.isCancelled else { return }
                await deliver(state.open, state.resolved)
            }
        }
    }

    /// Removes the subscriber and stops for good.
    func stop() {
        stopped = true
        if let subscriberID {
            subscriptions.removeSubscriber(subscriberID)
            self.subscriberID = nil
        }
        wakeups?.finish()
        wakeups = nil
        consumer?.cancel()
        consumer = nil
    }

    /// Whether the encoded delta `data` is a `.terminalPendingPromptsChanged`
    /// for `terminalID`.
    static func isPromptChange(_ data: Data, for terminalID: UUID) -> Bool {
        guard data.range(of: marker) != nil,
              case .terminalPendingPromptsChanged(let delta)? = try? JSONDecoder().decode(StateDelta.self, from: data) else {
            return false
        }
        return delta.terminalID == terminalID
    }
}

/// A device's open-session prompt feed: the set the phone was last sent, and
/// the source watching a local session's prompts. `token` tells this feed's
/// reads from those of a feed it replaced.
struct PhonePromptFeed: Sendable {
    let token: UInt64
    var set: PhonePromptSet
    /// Nil for a remote session, whose prompts arrive through
    /// `remotePromptsRead(_:session:deviceID:)`.
    let source: PhoneLocalPromptSource?
}

// MARK: - The service

/// `prompt.answer` and the `prompt.changed` feed of a device's open session.
///
/// **`prompt.answer`** adds no authority. It calls the core of `prompt.answer`
/// (`phoneAnswerPrompt`) or of `remote.answer` (`phoneAnswerRemotePrompt`)
/// under the device of the verified pairing, `context.peer.deviceID`, never a
/// value from the request, with the answer exactly as the phone sent it. The
/// core checks `transcript_prompt_answer_enabled`, the setting the laptop's
/// prompt card obeys, and `PromptDecisionEncoder` checks the answer against
/// the prompt, so the phone answers exactly the kinds the laptop does. The
/// method is in the request memory, so a resent answer acts once.
///
/// **`prompt.changed`** carries the open session's full prompt set, which
/// may be empty, after the session opens and then on every change, with a
/// resolution for each prompt that closed since the last one
/// (`PhonePromptAttribution`). Events go through `emit`, so they are numbered
/// and kept for a resume.
extension PhoneAppService {
    private static let promptsLogger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    static let answerReasonTooLongReason = "That reason is too long to send from a phone."
    static let answerRefusedReason = "The laptop refused the answer."
    static let noAnswerReason = "This provider does not support answering prompts."

    // MARK: - prompt.answer

    /// Answers a prompt and says how it ended: `delivered`, `already_resolved`
    /// or `unknown`.
    ///
    /// - A permission answer whose reason is over `promptTextCap` UTF-8 bytes
    ///   is `bad_request`, before anything is called.
    /// - **A local session** the phone cannot see (`phoneVisibleTerminal`) is
    ///   `not_found`. Otherwise `phoneAnswerPrompt` with the terminal, the
    ///   prompt and the answer.
    /// - **A remote session** needs its provider's `answer` capability, as the
    ///   sessions list shows it, or it is `unsupported` with the same reason;
    ///   a provider that is not registered is `not_found`. Then
    ///   `phoneAnswerRemotePrompt` with the provider, the session, the prompt
    ///   and the answer.
    ///
    /// The core's result is the reply's: "already answered" is the outcome
    /// `already_resolved`, not an error. A refusal (the setting is off, no
    /// hook picked the answer up, the answer does not fit the prompt) is
    /// `refused` with the core's text. A result that does not decode is
    /// `internal`, never a success. A revoke noticed before the call stops it.
    nonisolated func promptAnswer(_ params: PhonePromptAnswerParams, _ context: DeviceContext) async throws -> PromptAnswerResult {
        if case .permission(_, let reason?) = params.answer, reason.utf8.count > PhoneAppConstants.promptTextCap {
            throw PhoneAppError(code: .badRequest, message: Self.answerReasonTooLongReason)
        }
        let deviceID = context.peer.deviceID
        let key = PhonePromptAnswerLedger.Key(session: params.session, promptID: params.promptID)
        switch params.session {
        case .local(let terminalID):
            _ = try await phoneVisibleTerminal(terminalID)
            let core = PromptAnswerParams(terminalID: terminalID, promptID: params.promptID, answer: params.answer)
            return try await answerInLedger(key, deviceID: deviceID) {
                try await self.actions.phoneAnswerPrompt(core, deviceID: deviceID)
            }
        case .remote(let provider, let sessionID):
            let declared = try await declaredCapabilities(ofProvider: provider)
            let capability = PhoneSessionStatus.remoteCapabilities(declared: declared).answer
            guard capability.available else {
                throw PhoneAppError(code: .unsupported, message: capability.reason ?? Self.noAnswerReason)
            }
            let core = RemoteAnswerParams(
                provider: provider, sessionID: sessionID, promptID: params.promptID, answer: params.answer)
            return try await answerInLedger(key, deviceID: deviceID) {
                try await self.actions.phoneAnswerRemotePrompt(core, deviceID: deviceID)
            }
        }
    }

    /// Runs `call`, a core answer, inside a ledger attempt for `key`, and
    /// reads its result. The attempt is kept when the answer was delivered or
    /// may have been, and dropped on `already_resolved` and on every error.
    private nonisolated func answerInLedger(
        _ key: PhonePromptAnswerLedger.Key, deviceID: UUID, _ call: () async throws -> RPCResponse
    ) async throws -> PromptAnswerResult {
        try Task.checkCancellation()
        let token = await beginPhoneAnswer(key, deviceID: deviceID)
        let result: PromptAnswerResult
        do {
            let response = try await call()
            guard response.success else {
                throw Self.refusal(response.error.flatMap { $0.isEmpty ? nil : $0 } ?? Self.answerRefusedReason)
            }
            result = try Self.answerResult(from: response)
        } catch {
            await finishPhoneAnswer(key, token: token, keep: false)
            throw error
        }
        await finishPhoneAnswer(key, token: token, keep: result.outcome != .alreadyResolved)
        return result
    }

    /// `response`'s `PromptAnswerResult`. One that does not decode is
    /// `internal`: caught here, so it never reads as the phone's
    /// `bad_request`, nor as a success.
    private static func answerResult(from response: RPCResponse) throws -> PromptAnswerResult {
        do {
            return try response.decodeResult(PromptAnswerResult.self)
        } catch {
            promptsLogger.error(
                "Phone prompt.answer: the core answered a result that does not decode: \(Self.errorType(error), privacy: .public)")
            throw PhoneAppError(code: .internalError, message: "Something went wrong on the laptop.")
        }
    }

    // MARK: - The ledger

    /// Begins a ledger attempt for a phone's answer and returns its token.
    func beginPhoneAnswer(_ key: PhonePromptAnswerLedger.Key, deviceID: UUID) -> UInt64 {
        let token = mintToken()
        phoneAnswerLedger.begin(key, token: token, deviceID: deviceID, now: now())
        return token
    }

    /// Finishes the ledger attempt `token`, and wakes the reads waiting on
    /// it once no other attempt on the prompt runs.
    func finishPhoneAnswer(_ key: PhonePromptAnswerLedger.Key, token: UInt64, keep: Bool) {
        for waiter in phoneAnswerLedger.finish(key, token: token, keep: keep, now: now()) {
            waiter.resume()
        }
    }

    /// The phone whose answer the ledger kept for each closed prompt in
    /// `keys`, by prompt ID.
    ///
    /// It first waits for every phone's answer to those prompts still
    /// running, so a race is told right: a phone whose answer lost to the
    /// laptop's finishes `already_resolved` and is dropped, rather than being
    /// read as the winner while its call was in flight. The wait is short, as
    /// the core returns at once for a prompt that has closed.
    func phoneAnswers(for keys: [PhonePromptAnswerLedger.Key]) async -> [String: UUID] {
        var answers: [String: UUID] = [:]
        for key in keys {
            while phoneAnswerLedger.isAnswering(key) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    phoneAnswerLedger.wait(key, continuation)
                }
            }
            if let deviceID = phoneAnswerLedger.answeredBy(key) {
                answers[key.promptID] = deviceID
            }
        }
        return answers
    }

    /// How many prompt reads wait for a phone's answer to finish. For tests.
    func phoneAnswerWaiterCount() -> Int {
        phoneAnswerLedger.waiterCount
    }

    // MARK: - prompt.changed

    /// Starts `prompt.changed` for `session` on the device, in place of any
    /// feed it had. The first event carries the session's set as soon as it
    /// is read, then one follows every change. A local session's set is read
    /// from the pending prompt store; a remote session's arrives through
    /// `remotePromptsRead(_:session:deviceID:)`, and the first event follows
    /// its first call. Does nothing for a device with no state.
    ///
    /// The transcript feed calls this once its `transcript.open` reply is
    /// queued, so the events follow the reply.
    func openPrompts(_ session: PhoneSessionRef, for deviceID: UUID) {
        guard devices[deviceID] != nil else { return }
        let earlier = devices[deviceID]?.prompts?.source
        let token = mintToken()
        let source: PhoneLocalPromptSource?
        if case .local(let terminalID) = session {
            source = PhoneLocalPromptSource(
                terminalID: terminalID, store: pendingPrompts, subscriptions: subscriptions,
                deliver: { [weak self] open, resolved in
                    await self?.localPromptsRead(open, resolved: resolved, deviceID: deviceID, token: token)
                })
        } else {
            source = nil
        }
        devices[deviceID]?.prompts = PhonePromptFeed(token: token, set: PhonePromptSet(session: session), source: source)
        // The earlier source's subscriber goes before the new one's comes.
        Task {
            await earlier?.stop()
            await source?.start()
        }
    }

    /// Stops the device's `prompt.changed` feed.
    func closePrompts(for deviceID: UUID) {
        let source = devices[deviceID]?.prompts?.source
        devices[deviceID]?.prompts = nil
        Task {
            await source?.stop()
        }
    }

    /// A remote session's pending prompts as its provider last reported them
    /// (`effectivePendingPrompt`), for a device whose open session it is.
    /// The remote sync calls it after each `remoteSessionsChanged`, one call
    /// at a time per device. Does nothing for any other session.
    func remotePromptsRead(_ prompts: [RemotePendingPrompt], session: PhoneSessionRef, deviceID: UUID) async {
        guard let feed = devices[deviceID]?.prompts, feed.set.session == session else { return }
        await promptsRead(
            prompts.map(PhonePromptShaper.remote), localResolutions: nil, deviceID: deviceID, token: feed.token)
    }

    private func localPromptsRead(
        _ open: [PendingPromptPayload], resolved: [String: PendingPromptStore.Resolution], deviceID: UUID, token: UInt64
    ) async {
        await promptsRead(
            open.map(PhonePromptShaper.local), localResolutions: resolved, deviceID: deviceID, token: token)
    }

    /// Emits the `prompt.changed` that brings the device from the set it was
    /// last sent to `current`, if anything changed, unless a later feed
    /// replaced the one `token` names.
    private func promptsRead(
        _ current: [PhonePrompt], localResolutions: [String: PendingPromptStore.Resolution]?,
        deviceID: UUID, token: UInt64
    ) async {
        guard let feed = devices[deviceID]?.prompts, feed.token == token else { return }
        let session = feed.set.session
        let closed = feed.set.closedIDs(in: current).map { PhonePromptAnswerLedger.Key(session: session, promptID: $0) }
        let answers = await phoneAnswers(for: closed)
        guard var latest = devices[deviceID]?.prompts, latest.token == token else { return }
        let attribution = PhonePromptAttribution(phoneAnswers: answers, localResolutions: localResolutions)
        guard let data = latest.set.advance(to: current, attribution: attribution) else { return }
        devices[deviceID]?.prompts = latest
        emit(.promptChanged, data: data, to: deviceID)
    }

    /// The device's open-session prompt feed's session, or nil with none.
    /// For tests.
    func promptsSession(for deviceID: UUID) -> PhoneSessionRef? {
        devices[deviceID]?.prompts?.set.session
    }
}
