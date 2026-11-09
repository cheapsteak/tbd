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
//   every `.terminalPendingPromptsChanged` for it, and
//   `PhoneRemotePromptSource` a remote session's on every
//   `.remoteSessionsChanged`.
// - `PhonePromptFeed`, in `PhoneDeviceState.prompts`, ties them to one device's
//   open session, through `openPrompts(_:for:)` and `closePrompts(for:)`.

// MARK: - Shaping

/// Turns an open prompt into what the phone shows: the fields the laptop's
/// prompt cards draw (`PermissionPromptCard`, `InteractiveQuestionCard`).
///
/// **What an answer is keyed on goes whole.** An answer names a question by
/// its text, which `PromptDecisionEncoder` checks against the prompt's, and
/// picks an option by its label, which it carries through as written. So a
/// question's text and an option's label are never cut: a cut text names no
/// question the prompt has, so the core refuses the answer, and a cut label
/// would answer with words that are not the option's.
///
/// **Everything else is capped on encoded bytes.** Each other text is cut, at
/// a character boundary, so its JSON string body under
/// `PhoneAppCoding.makeEncoder()` is at most its cap: a permission's summary
/// and target at `PhoneAppConstants.promptTextCap`, an option's description
/// and a suggestion line at `promptOptionCap`, a header and a tool name at
/// `PhoneText.fieldLimit`. Measuring the escaped length rather than the UTF-8
/// length is what bounds a frame: a quote takes two bytes once encoded, and a
/// control character six. A permission shows at most `suggestionLimit`
/// suggestion lines, the last of them saying how many more there are.
///
/// No count of questions or options is capped: a prompt too large for one
/// frame is left out of `prompt.changed` whole (`fitted(_:budget:)`), never
/// shown in part.
enum PhonePromptShaper {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// The most suggestion lines a permission prompt shows.
    static let suggestionLimit = 32

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

    /// A question with its text and every option's label whole, since an
    /// answer is keyed on them, and its header and option descriptions cut.
    private static func shaped(_ question: PromptQuestion) -> PhoneQuestion {
        PhoneQuestion(
            text: question.text,
            header: question.header.map { cut($0, to: PhoneText.fieldLimit).text },
            multiSelect: question.multiSelect,
            options: question.options.map { option in
                PhoneOption(
                    label: option.label,
                    description: option.description.map { cut($0, to: PhoneAppConstants.promptOptionCap).text })
            })
    }

    /// A permission prompt:
    /// - `summary` is `TranscriptParser.toolInputSummary(name:input:)`;
    /// - `target` is `target(input:toolInputJSON:)`, cut to `promptTextCap`,
    ///   with `targetTruncated` when it was cut or the provider cut the input;
    /// - `suggestions` is `PermissionSuggestionSummary.lines(fromJSON:)`,
    ///   at most `suggestionLimit` of them (`limited(_:)`), omitted when there
    ///   are none;
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
        let suggestions = limited(PermissionSuggestionSummary.lines(fromJSON: suggestionsJSON))
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

    /// `lines` as they are when there are at most `suggestionLimit`;
    /// otherwise the first `suggestionLimit - 1` and a last line saying how
    /// many more there are, so an ordinary prompt never outgrows a frame.
    static func limited(_ lines: [String]) -> [String] {
        guard lines.count > suggestionLimit else { return lines }
        let kept = suggestionLimit - 1
        return Array(lines.prefix(kept)) + ["and \(lines.count - kept) more"]
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
    /// quotes, is at most `limit` bytes, and whether anything was cut: the
    /// transcript's own cut (`TranscriptShaper.preview`).
    static func cut(_ text: String, to limit: Int) -> (text: String, cut: Bool) {
        let preview = TranscriptShaper.preview(text, limit: limit)
        return (preview.text, preview.truncated)
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
    /// Data that fits is returned as it is. Otherwise:
    /// - a prompt too large to fit even alone is left out, and the prompts
    ///   after it are still tried, so it cannot hide every newer prompt;
    /// - the other prompts are kept in order, oldest first, up to the first
    ///   that does not fit, and the newer ones are left out until an older one
    ///   closes;
    /// - then the resolutions likewise.
    ///
    /// A prompt is never shown in part. A prompt left out was never sent, so
    /// its closing is never reported. A resolution left out is lost; the
    /// phone still sees its prompt leave the set. Only how many were left out
    /// is logged, never what they say.
    ///
    /// Only an unusual set comes here: several large prompts open at once, or
    /// one whose question text, labels or tool input run to tens of kilobytes.
    static func fitted(_ data: PromptChangedData, budget: Int = PhoneFrameBudget.eventDataBytes) -> PromptChangedData {
        let encoder = PhoneAppCoding.makeEncoder()
        func size<T: Encodable>(_ value: T) -> Int {
            (try? encoder.encode(value).count) ?? Int.max / 4
        }
        if size(data) <= budget { return data }
        let empty = size(PromptChangedData(session: data.session, prompts: [], resolved: nil))
        var used = empty
        var prompts: [PhonePrompt] = []
        var tooLarge = 0
        var full = false
        for prompt in data.prompts {
            let bytes = size(prompt)
            if empty + bytes > budget {
                tooLarge += 1
                continue
            }
            guard !full else { continue }
            let cost = bytes + (prompts.isEmpty ? 0 : 1)
            guard used + cost <= budget else {
                full = true
                continue
            }
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
            "Phone prompts: left out \(leftOutPrompts, privacy: .public) prompts (\(tooLarge, privacy: .public) too large for any frame) and \(leftOutResolutions, privacy: .public) resolutions to fit a prompt.changed into one frame")
        return PromptChangedData(session: data.session, prompts: prompts, resolved: resolved.isEmpty ? nil : resolved)
    }
}

// MARK: - Who answered

/// Which phones are answering, or have answered, which prompts, across every
/// device the service serves, for `prompt.changed`'s `answeredBy`.
///
/// `prompt.answer` begins an attempt before it calls the core and finishes it
/// when the core replies. An attempt whose answer was `delivered`, or may have
/// been (`unknown`), settles and is kept with how it ended; one that met
/// `already_resolved` or an error is dropped. Several phones may answer one
/// prompt at once, each with an attempt of its own, and every attempt that
/// settles is kept. A prompt takes one answer, so `answeredBy` names the
/// phone whose answer was delivered; with none delivered, the phone whose
/// answer may have landed when only one phone's may have, and no phone in
/// particular when several may have, since any of them may be the one. A
/// read that stopped waiting for running attempts counts each as one that
/// may have landed.
///
/// **Bounded waits.** A read waits for a closed prompt's running attempts
/// under a wait ID (`beginWait(_:)`). `expire(_:)` ends the wait early and
/// hands back its parked read, and `endWait(_:)` retires the ID, so a timer
/// that fires after the wait ended does nothing.
///
/// **Bounded.** Running attempts are bounded by the requests a device may have
/// in flight. A kept attempt is dropped `lifetime` after it settled, and at
/// most `settledLimit` are kept, the oldest dropped first.
///
/// **A prompt ID can come back.** `PendingPromptStore.open` can open a prompt
/// again under the same ID after it closed, with a new `createdAt`. So a read
/// may pass the time the prompt it asks about was opened, and an attempt that
/// settled before then answered an earlier opening and does not count.
struct PhonePromptAnswerLedger: Sendable {
    struct Key: Hashable, Sendable {
        let session: PhoneSessionRef
        let promptID: String
    }

    /// How a kept attempt's answer ended.
    enum Settlement: Sendable, Equatable {
        /// The core delivered the answer.
        case delivered
        /// The answer may have landed: the core could not tell.
        case unknown
    }

    /// Who answered a prompt, as the kept attempts tell it.
    enum Answerer: Sendable, Equatable {
        /// This phone answered.
        case device(UUID)
        /// A phone answered, but which one is not known: more than one
        /// phone's answer may have landed, and none is known to have.
        case unknownDevice

        /// The answering phone, when it is known.
        var deviceID: UUID? {
            guard case .device(let deviceID) = self else { return nil }
            return deviceID
        }
    }

    private struct Attempt: Sendable {
        let token: UInt64
        let deviceID: UUID
        /// When the attempt settled and was kept; nil while its call runs.
        var settledAt: Date?
        /// How the kept attempt's answer ended; nil while its call runs.
        var settlement: Settlement?
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

    /// A read parked on a prompt's running attempts, under its wait's ID.
    private struct Waiter: Sendable {
        let waitID: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var attempts: [Key: [Attempt]] = [:]
    /// The kept attempts, in the order they settled.
    private var settledOrder: [Settled] = []
    /// Reads waiting for a prompt's running attempts to finish.
    private var waiters: [Key: [Waiter]] = [:]
    /// The waits that may still park a read: begun, and neither expired nor
    /// ended.
    private var openWaits: Set<UInt64> = []

    /// A phone's answer to the prompt under `key` is about to reach the core.
    mutating func begin(_ key: Key, token: UInt64, deviceID: UUID, now: Date) {
        prune(now: now)
        attempts[key, default: []].append(Attempt(token: token, deviceID: deviceID, settledAt: nil, settlement: nil))
    }

    /// The attempt `token` finished: kept with how it ended, `settled`, or
    /// dropped when that is nil. Returns the waiters to resume, once no
    /// attempt on `key` still runs.
    mutating func finish(
        _ key: Key, token: UInt64, settled: Settlement?, now: Date
    ) -> [CheckedContinuation<Void, Never>] {
        if var list = attempts[key], let index = list.firstIndex(where: { $0.token == token }) {
            if let settled {
                list[index].settledAt = now
                list[index].settlement = settled
                settledOrder.append(Settled(key: key, token: token, at: now))
            } else {
                list.remove(at: index)
            }
            attempts[key] = list.isEmpty ? nil : list
        }
        prune(now: now)
        guard !isAnswering(key) else { return [] }
        return (waiters.removeValue(forKey: key) ?? []).map(\.continuation)
    }

    /// Whether a phone's answer to the prompt under `key` is still running.
    func isAnswering(_ key: Key) -> Bool {
        attempts[key]?.contains { $0.settledAt == nil } ?? false
    }

    /// Who answered the prompt under `key`, from its kept attempts, counting
    /// only one that settled at or after `openedAt` when it is given, and,
    /// with `countingRunning`, its running attempts as ones that may have
    /// landed:
    /// - **the phone whose answer was `delivered`**, when one was;
    /// - otherwise **the phone whose answer may have landed** (`unknown`, or
    ///   running when counted), when only one phone's may have, however many
    ///   attempts it made;
    /// - **`unknownDevice`** when several phones' may have;
    /// - nil when no attempt counts.
    func answeredBy(_ key: Key, openedAt: Date? = nil, countingRunning: Bool = false) -> Answerer? {
        let all = attempts[key] ?? []
        let kept = all.filter { attempt in
            guard let settledAt = attempt.settledAt else { return false }
            guard let openedAt else { return true }
            return settledAt >= openedAt
        }
        if let delivered = kept.first(where: { attempt in attempt.settlement == .delivered }) {
            return .device(delivered.deviceID)
        }
        let running = countingRunning ? all.filter { attempt in attempt.settledAt == nil } : []
        let mayHaveLanded = kept + running
        guard let first = mayHaveLanded.first else { return nil }
        let devices = Set(mayHaveLanded.map { attempt in attempt.deviceID })
        return devices.count == 1 ? .device(first.deviceID) : .unknownDevice
    }

    /// Opens the wait `waitID`, so it may park a read.
    mutating func beginWait(_ waitID: UInt64) {
        openWaits.insert(waitID)
    }

    /// Whether the wait `waitID` may still park a read: begun, and neither
    /// expired nor ended.
    func isWaiting(_ waitID: UInt64) -> Bool {
        openWaits.contains(waitID)
    }

    /// Parks a read on `key`'s running attempts under the wait `waitID`.
    /// Call only while `isAnswering(key)` and `isWaiting(waitID)`.
    mutating func wait(_ key: Key, waitID: UInt64, _ continuation: CheckedContinuation<Void, Never>) {
        waiters[key, default: []].append(Waiter(waitID: waitID, continuation: continuation))
    }

    /// The wait `waitID` ran out of time: it parks no more reads, and the
    /// read it has parked is returned to resume. Nothing once it ended.
    mutating func expire(_ waitID: UInt64) -> [CheckedContinuation<Void, Never>] {
        guard openWaits.remove(waitID) != nil else { return [] }
        var resumed: [CheckedContinuation<Void, Never>] = []
        for key in Array(waiters.keys) {
            guard let list = waiters[key], list.contains(where: { $0.waitID == waitID }) else { continue }
            resumed += list.filter { $0.waitID == waitID }.map(\.continuation)
            let rest = list.filter { $0.waitID != waitID }
            waiters[key] = rest.isEmpty ? nil : rest
        }
        return resumed
    }

    /// The wait `waitID` ended. An `expire(_:)` after this does nothing.
    mutating func endWait(_ waitID: UInt64) {
        openWaits.remove(waitID)
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
/// - **`phone`**, when the ledger kept a phone's answer to it, or a phone's
///   answer still ran when the read stopped waiting for it
///   (`PhoneAppService.phoneAnswers(for:openedAt:)`), with the phone's
///   device when the ledger can name it (`PhonePromptAnswerLedger.answeredBy`)
///   and none when several phones' answers may have landed. For a local prompt, only when the store says
///   TBD's decision reached Claude (`answered`), or has no record of how it
///   ended.
/// - **`laptop`** for a local prompt the terminal answered
///   (`answeredInTerminal`), or that TBD's decision ended with no phone's
///   answer kept (`answered`): the laptop's TBD app answered it.
/// - **`unknown`** otherwise: the terminal or session ended, the mod went
///   away, the daemon stopped, or nothing records how it ended. A remote
///   prompt is `unknown` unless a phone answered it, as nothing else records
///   who answered one.
struct PhonePromptAttribution: Sendable, Equatable {
    /// Who the ledger says answered, by prompt ID.
    var phoneAnswers: [String: PhonePromptAnswerLedger.Answerer] = [:]
    /// How the store resolved each recently closed local prompt, by prompt
    /// ID. Nil for a remote session.
    var localResolutions: [String: PendingPromptStore.Resolution]?

    func resolution(of promptID: String) -> PhonePromptResolution {
        let phone = phoneAnswers[promptID]
        let laptop = PhonePromptResolution(promptID: promptID, answeredBy: .laptop, deviceID: nil)
        let unknown = PhonePromptResolution(promptID: promptID, answeredBy: .unknown, deviceID: nil)
        let byPhone = phone.map { answerer in
            PhonePromptResolution(promptID: promptID, answeredBy: .phone, deviceID: answerer.deviceID)
        }
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
    /// When each prompt in `sent` was opened, as its source last read it, by
    /// prompt ID. Empty for a remote session, whose prompts carry no time.
    private var openedTimes: [String: Date] = [:]

    init(session: PhoneSessionRef) {
        self.session = session
    }

    /// When each of `ids`, prompts last sent, was opened, as far as known.
    func openedAt(of ids: [String]) -> [String: Date] {
        var times: [String: Date] = [:]
        for id in ids {
            times[id] = openedTimes[id]
        }
        return times
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
    ///
    /// `openedAt` is when each prompt in `current` was opened, by prompt ID.
    /// It is kept for the prompts sent even when nothing else changed, since
    /// a prompt that closed and opened again between two reads looks the
    /// same but for it.
    mutating func advance(
        to current: [PhonePrompt], openedAt: [String: Date] = [:], attribution: PhonePromptAttribution
    ) -> PromptChangedData? {
        let resolved = closedIDs(in: current).map { attribution.resolution(of: $0) }
        let data = PhonePromptShaper.fitted(PromptChangedData(
            session: session, prompts: current, resolved: resolved.isEmpty ? nil : resolved))
        let sentIDs = Set(data.prompts.map(\.id))
        openedTimes = openedAt.filter { sentIDs.contains($0.key) }
        if let sent, sent == data.prompts {
            return nil
        }
        sent = data.prompts
        return data
    }
}

// MARK: - Sources

/// What reads one open session's prompts for a device's prompt feed: it
/// reads the set once on `start()` and again on every change, and `stop()`
/// ends it for good.
protocol PhonePromptSource: Sendable {
    func start() async
    func stop() async
}

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
actor PhoneLocalPromptSource: PhonePromptSource {
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
        let idMarker = Self.idMarker(of: terminalID)
        subscriberID = subscriptions.addSubscriber { data in
            if Self.isPromptChange(data, for: terminalID, idMarker: idMarker) {
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
    ///
    /// The subscriber runs on the broadcaster's own call, once per phone with
    /// the session open, for every delta of every terminal. So `data` is
    /// decoded only when it holds both the case's name and the terminal's ID,
    /// `idMarker` (`idMarker(of:)`), and a prompt change of any other
    /// terminal costs two byte searches and no decode, as
    /// `TranscriptDeltaRelay` does for its terminal's deltas.
    static func isPromptChange(_ data: Data, for terminalID: UUID, idMarker: Data? = nil) -> Bool {
        guard data.range(of: marker) != nil, data.range(of: idMarker ?? Self.idMarker(of: terminalID)) != nil,
              case .terminalPendingPromptsChanged(let delta)? = try? JSONDecoder().decode(StateDelta.self, from: data) else {
            return false
        }
        return delta.terminalID == terminalID
    }

    /// `terminalID` as an encoded delta holds it: `StateSubscriptionManager`
    /// encodes a UUID as its uppercase string.
    static func idMarker(of terminalID: UUID) -> Data {
        Data(terminalID.uuidString.utf8)
    }
}

/// The open prompt of one remote session, as its provider last reported it
/// (`effectivePendingPrompt`), read from the laptop's remote session list
/// when the feed starts and again on every `.remoteSessionsChanged`.
///
/// The delta is only a wakeup, as for a local terminal: the list is read
/// itself (`phoneRemoteSessions`), so a delta that arrives out of order
/// cannot bring an old set back. A session missing from the list, or
/// dismissed, has no open prompt. A list the daemon refuses to give, or that
/// does not decode, delivers nothing, and the next change reads it again.
///
/// One task reads and delivers, one read at a time, and a wakeup that comes
/// while it works makes one more read. So a delivery that waits, for a
/// phone's answer to a prompt that closed (up to
/// `PhoneAppConstants.answerAttributionWait`), holds up only the next read,
/// never the transcript's syncs, which run on a task of their own.
///
/// `stop()` removes the subscriber and ends the work for good; a later
/// `start()` does nothing.
actor PhoneRemotePromptSource: PhonePromptSource {
    typealias Delivery = @Sendable (_ open: [RemotePendingPrompt]) async -> Void

    /// The bytes every `.remoteSessionsChanged` delta holds, checked before
    /// a delta is decoded.
    private static let marker = Data(#""remoteSessionsChanged""#.utf8)
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    private let provider: String
    private let sessionID: String
    private let actions: any PhoneSessionActions
    private let subscriptions: StateSubscriptionManager
    private let deliver: Delivery
    private var subscriberID: StateSubscriptionManager.SubscriberID?
    private var wakeups: AsyncStream<Void>.Continuation?
    private var consumer: Task<Void, Never>?
    private var stopped = false

    init(provider: String, sessionID: String, actions: any PhoneSessionActions,
         subscriptions: StateSubscriptionManager, deliver: @escaping Delivery) {
        self.provider = provider
        self.sessionID = sessionID
        self.actions = actions
        self.subscriptions = subscriptions
        self.deliver = deliver
    }

    /// Whether the source is subscribed to state deltas: between `start`
    /// and `stop`. For tests.
    var isSubscribed: Bool {
        subscriberID != nil
    }

    /// Subscribes to state deltas and reads the prompt once. Does nothing
    /// once started or stopped.
    func start() {
        guard !stopped, consumer == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = continuation
        subscriberID = subscriptions.addSubscriber { data in
            if Self.isSessionsChange(data) {
                continuation.yield()
            }
            return true
        }
        // The first read, after the subscriber is in place, so no change
        // falls between them.
        continuation.yield()
        let provider = self.provider
        let sessionID = self.sessionID
        let actions = self.actions
        let deliver = self.deliver
        consumer = Task {
            for await _ in stream {
                let open = await Self.openPrompts(provider: provider, sessionID: sessionID, actions: actions)
                guard !Task.isCancelled else { return }
                // A list that could not be read delivers nothing; the next
                // change reads it again.
                guard let open else { continue }
                await deliver(open)
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

    /// The session's open prompt, none when the session is missing from the
    /// list or dismissed, or nil when the list cannot be read.
    private static func openPrompts(
        provider: String, sessionID: String, actions: any PhoneSessionActions
    ) async -> [RemotePendingPrompt]? {
        do {
            let response = try await actions.phoneRemoteSessions()
            guard response.success else {
                logger.error("Phone prompts: the remote session list was refused")
                return nil
            }
            let sessions = try response.decodeResult(RemoteSessionsResult.self).sessions
            guard let session = sessions.first(where: { $0.provider == provider && $0.payload.id == sessionID }),
                  !session.dismissed else { return [] }
            return session.payload.effectivePendingPrompt.map { [$0] } ?? []
        } catch {
            logger.error(
                "Phone prompts: could not read the remote session list: \(PhoneAppService.errorType(error), privacy: .public)")
            return nil
        }
    }

    /// Whether the encoded delta `data` is a `.remoteSessionsChanged`.
    static func isSessionsChange(_ data: Data) -> Bool {
        guard data.range(of: marker) != nil,
              case .remoteSessionsChanged? = try? JSONDecoder().decode(StateDelta.self, from: data) else {
            return false
        }
        return true
    }
}

/// A device's open-session prompt feed: the set the phone was last sent, and
/// the source watching the session's prompts. `token` tells this feed's
/// reads from those of a feed it replaced.
struct PhonePromptFeed: Sendable {
    let token: UInt64
    var set: PhonePromptSet
    /// `PhoneLocalPromptSource` for a local session and
    /// `PhoneRemotePromptSource` for a remote one; nil only when a test
    /// builds a feed by hand.
    let source: (any PhonePromptSource)?
}

// MARK: - The service

/// `prompt.answer` and the `prompt.changed` feed of a device's open session.
///
/// **`prompt.answer`** adds no authority. It calls the core of `prompt.answer`
/// (`phoneAnswerPrompt`) or of `remote.answer` (`phoneAnswerRemotePrompt`)
/// under the device of the verified pairing, `context.peer.deviceID`, never a
/// value from the request, with the answer exactly as the phone sent it.
/// `transcript_prompt_answer_enabled`, the setting the laptop's prompt card
/// obeys, is read twice: first through the session's `answer` capability, as
/// the sessions list shows it, so while the setting is off the answer is
/// `unsupported` with `PhoneSessionStatus.answerTurnedOffReason` before the
/// core is called; then by the core itself, which refuses an answer whose
/// setting was turned off after the first read. `PromptDecisionEncoder` checks
/// the answer against the prompt, so the phone answers exactly the kinds the
/// laptop does. The method is in the request memory, so a resent answer acts
/// once. A remote answer's refusal reaches the phone only in words TBD wrote
/// (`answerRefusal(_:remoteRefusals:)`), since a provider's own can quote a
/// secret.
///
/// **`prompt.changed`** carries the open session's full prompt set, which
/// may be empty, after the session opens and then on every change, with a
/// resolution for each prompt that closed since the last one
/// (`PhonePromptAttribution`). Events go through `emit`, so they are numbered
/// and kept for a resume.
extension PhoneAppService {
    static let answerReasonTooLongReason = "That reason is too long to send from a phone."
    static let answerRefusedReason = "The laptop refused the answer."
    static let noAnswerReason = "This provider does not support answering prompts."
    static let notAClaudeAnswerReason = "Only a Claude session can answer prompts."

    // MARK: - prompt.answer

    /// Answers a prompt and says how it ended: `delivered`, `already_resolved`
    /// or `unknown`.
    ///
    /// - A permission answer whose reason is over `promptTextCap` UTF-8 bytes
    ///   is `bad_request`, before anything is called.
    /// - **A local session** the phone cannot see (`phoneVisibleTerminal`) is
    ///   `not_found`. Then, in this order, each is `unsupported`
    ///   (`phoneCapableClaudeTerminal`): a session that can never answer (a
    ///   Codex session, a tab in a remote lane), with the reason the sessions
    ///   list shows; any other session that is not Claude (a shell), with
    ///   `notAClaudeAnswerReason`; and a Claude session while the setting for
    ///   answering prompts is off, with the list's reason,
    ///   `PhoneSessionStatus.answerTurnedOffReason`. Otherwise
    ///   `phoneAnswerPrompt` with the terminal, the prompt and the answer.
    /// - **A remote session** needs its `answer` capability, as the sessions
    ///   list shows it (its provider declares `answer`, and the setting is
    ///   on), or it is `unsupported` with the same reason; a provider that is
    ///   not registered, and a session the phone cannot see, are `not_found`
    ///   (`checkPhoneCapableRemoteSession`). Then `phoneAnswerRemotePrompt`
    ///   with the provider, the session, the prompt and the answer.
    ///
    /// The core's result is the reply's: "already answered" is the outcome
    /// `already_resolved`, not an error. A refusal (the setting was turned off
    /// after the capability check read it, no hook picked the answer up, the
    /// answer does not fit the prompt) is `refused`: a local answer's with the
    /// core's text, and a remote answer's only in words TBD wrote
    /// (`answerRefusal(_:remoteRefusals:)`). A result that does not decode is
    /// `internal`, never a success. A revoke noticed before the call stops it.
    nonisolated func promptAnswer(_ params: PhonePromptAnswerParams, _ context: DeviceContext) async throws -> PromptAnswerResult {
        if case .permission(_, let reason?) = params.answer, reason.utf8.count > PhoneAppConstants.promptTextCap {
            throw PhoneAppError(code: .badRequest, message: Self.answerReasonTooLongReason)
        }
        let deviceID = context.peer.deviceID
        let key = PhonePromptAnswerLedger.Key(session: params.session, promptID: params.promptID)
        switch params.session {
        case .local(let terminalID):
            _ = try await phoneCapableClaudeTerminal(
                terminalID, needing: { $0.answer }, notClaude: Self.notAClaudeAnswerReason)
            let core = PromptAnswerParams(terminalID: terminalID, promptID: params.promptID, answer: params.answer)
            return try await answerInLedger(key, deviceID: deviceID) {
                try await self.actions.phoneAnswerPrompt(core, deviceID: deviceID)
            }
        case .remote(let provider, let sessionID):
            try await checkPhoneCapableRemoteSession(
                provider: provider, sessionID: sessionID, needing: { $0.answer }, orElse: Self.noAnswerReason)
            let core = RemoteAnswerParams(
                provider: provider, sessionID: sessionID, promptID: params.promptID, answer: params.answer)
            let promptQuestions = await sentQuestionTexts(for: key)
            let remoteRefusals = Self.tbdRemoteAnswerRefusals(for: params.answer, promptQuestions: promptQuestions)
            return try await answerInLedger(key, deviceID: deviceID, remoteRefusals: remoteRefusals) {
                try await self.actions.phoneAnswerRemotePrompt(core, deviceID: deviceID)
            }
        }
    }

    /// Runs `call`, a core answer, inside a ledger attempt for `key`, and
    /// reads its result. The attempt is kept, with how it ended, when the
    /// answer was delivered or may have been, and dropped on
    /// `already_resolved` and on every error. A refusal is
    /// `answerRefusal(_:remoteRefusals:)`, with `remoteRefusals` for a remote
    /// answer and nil for a local one.
    private nonisolated func answerInLedger(
        _ key: PhonePromptAnswerLedger.Key, deviceID: UUID, remoteRefusals: Set<String>? = nil,
        _ call: () async throws -> RPCResponse
    ) async throws -> PromptAnswerResult {
        try Task.checkCancellation()
        let token = await beginPhoneAnswer(key, deviceID: deviceID)
        let result: PromptAnswerResult
        do {
            let response = try await call()
            guard response.success else {
                throw Self.answerRefusal(response.error, remoteRefusals: remoteRefusals)
            }
            result = try Self.decoded(PromptAnswerResult.self, from: response, method: "prompt.answer")
        } catch {
            await finishPhoneAnswer(key, token: token, settled: nil)
            throw error
        }
        let settled: PhonePromptAnswerLedger.Settlement?
        switch result.outcome {
        case .delivered:
            settled = .delivered
        case .unknown:
            settled = .unknown
        case .alreadyResolved:
            settled = nil
        }
        await finishPhoneAnswer(key, token: token, settled: settled)
        return result
    }

    /// The `refused` error for an answer the core refused with `reason`.
    ///
    /// - **A local answer** (`remoteRefusals` nil) is refused by TBD alone:
    ///   the setting is off, no hook picked the answer up, or the answer does
    ///   not fit the prompt. Its reason reaches the phone as `refusal(_:)`
    ///   sends it, or `answerRefusedReason` when it gave none.
    /// - **A remote answer** can be refused by the provider, whose error
    ///   message can quote a URL with an access token in it. Its reason
    ///   reaches the phone only when it is in `remoteRefusals`, the words TBD
    ///   writes on that path (`tbdRemoteAnswerRefusals(for:promptQuestions:)`);
    ///   anything else is `remoteRefusedReason`, and the reason goes to the
    ///   log as private data (`remoteRefusal(_:method:tbdRefusals:)`).
    static func answerRefusal(_ reason: String?, remoteRefusals: Set<String>?) -> PhoneAppError {
        guard let remoteRefusals else {
            return Self.refusal(reason.flatMap { $0.isEmpty ? nil : $0 } ?? Self.answerRefusedReason)
        }
        return Self.remoteRefusal(reason, method: "remote.answer", tbdRefusals: remoteRefusals)
    }

    /// The refusals TBD itself writes on the remote answer path, for an
    /// answer of `answer` to a prompt whose question texts, as a phone was
    /// sent them, are `promptQuestions`, which reach a phone as they are
    /// (`answerRefusal(_:remoteRefusals:)`):
    /// - the gates' (`tbdRemoteGateRefusals`);
    /// - the setting's, and a session with no mirror row
    ///   (`PromptAnswerRefusal`);
    /// - a session that has exited (`RemoteSendMessageRefusal.exited`);
    /// - every `PromptAnswerValidation` message whose words are TBD's and
    ///   text the phone has: the fixed ones, and, for a question answer, the
    ///   ones that name a question the answer itself names, and the "no
    ///   answer" one for every question in `promptQuestions`, which the
    ///   validator raises for a question the answer left out.
    ///
    /// Every text here is TBD's words with the phone's own text or the
    /// prompt's question texts a phone was already sent in `prompt.changed`,
    /// so none tells the phone anything a provider wrote that it does not
    /// have. The refusals TBD builds from anything else, such as a validation
    /// message naming a question no phone was sent, a stale provider's and an
    /// undeclared verb's, are left out, and the phone gets
    /// `remoteRefusedReason` for them.
    static func tbdRemoteAnswerRefusals(for answer: PromptAnswer, promptQuestions: [String] = []) -> Set<String> {
        var refusals = tbdRemoteGateRefusals.union([
            PromptAnswerRefusal.disabled,
            PromptAnswerRefusal.notMirrored,
            RemoteSendMessageRefusal.exited,
            PromptAnswerValidation.kindMismatch.message,
            PromptAnswerValidation.allowAlwaysWithoutSuggestions.message,
            PromptAnswerValidation.missingAnswer(question: "").message,
        ])
        if case .question(let answers) = answer {
            for question in answers.keys {
                refusals.insert(PromptAnswerValidation.missingAnswer(question: question).message)
                refusals.insert(PromptAnswerValidation.unknownQuestion(question).message)
            }
            for question in promptQuestions {
                refusals.insert(PromptAnswerValidation.missingAnswer(question: question).message)
            }
        }
        return refusals
    }

    /// The question texts of the prompt under `key`, as a device's prompt
    /// feed last sent it to its phone, or none when no feed sent it. A
    /// question's text goes whole (`PhonePromptShaper`), so these are the
    /// texts the core checks an answer against.
    func sentQuestionTexts(for key: PhonePromptAnswerLedger.Key) -> [String] {
        for state in devices.values {
            guard let set = state.prompts?.set, set.session == key.session,
                  let prompt = set.sent?.first(where: { $0.id == key.promptID }) else { continue }
            return (prompt.questions ?? []).map(\.text)
        }
        return []
    }

    // MARK: - The ledger

    /// Begins a ledger attempt for a phone's answer and returns its token.
    func beginPhoneAnswer(_ key: PhonePromptAnswerLedger.Key, deviceID: UUID) -> UInt64 {
        let token = mintToken()
        phoneAnswerLedger.begin(key, token: token, deviceID: deviceID, now: now())
        return token
    }

    /// Finishes the ledger attempt `token`, kept with how it ended,
    /// `settled`, or dropped when that is nil, and wakes the reads waiting on
    /// it once no other attempt on the prompt runs.
    func finishPhoneAnswer(
        _ key: PhonePromptAnswerLedger.Key, token: UInt64, settled: PhonePromptAnswerLedger.Settlement?
    ) {
        for waiter in phoneAnswerLedger.finish(key, token: token, settled: settled, now: now()) {
            waiter.resume()
        }
    }

    /// Who the ledger says answered each closed prompt in `keys`
    /// (`PhonePromptAnswerLedger.answeredBy`), by prompt ID. With a prompt's
    /// time in `openedAt`, an answer that settled before it answered an
    /// earlier opening of the prompt and does not count.
    ///
    /// It first waits for every phone's answer to those prompts still
    /// running, so a race is told right: a phone whose answer lost to the
    /// laptop's finishes `already_resolved` and is dropped, rather than being
    /// read as the winner while its call was in flight. The device's next
    /// `prompt.changed` waits with it, so the wait is bounded: at most
    /// `PhoneAppConstants.answerAttributionWait` on the service's clock. A
    /// local answer to a closed prompt returns well inside that, as the core
    /// returns at once. A remote one can run for the provider's answer
    /// timeout, 30 seconds, plus its time in the session's queue, and is the
    /// one the bound cuts short. A prompt whose phone answer still runs when
    /// the wait ends counts as answered by that phone, with its device when
    /// one phone is answering it and none when several are: that answer is
    /// why the prompt closed in nearly every case.
    func phoneAnswers(
        for keys: [PhonePromptAnswerLedger.Key], openedAt: [String: Date] = [:]
    ) async -> [String: PhonePromptAnswerLedger.Answerer] {
        if keys.contains(where: { phoneAnswerLedger.isAnswering($0) }) {
            await waitForPhoneAnswers(to: keys)
        }
        var answers: [String: PhonePromptAnswerLedger.Answerer] = [:]
        for key in keys {
            if let answerer = phoneAnswerLedger.answeredBy(
                key, openedAt: openedAt[key.promptID], countingRunning: true) {
                answers[key.promptID] = answerer
            }
        }
        return answers
    }

    /// Waits until no phone's answer to any prompt in `keys` runs, or until
    /// `PhoneAppConstants.answerAttributionWait` has passed on the service's
    /// clock, whichever comes first.
    private func waitForPhoneAnswers(to keys: [PhonePromptAnswerLedger.Key]) async {
        let waitID = mintToken()
        phoneAnswerLedger.beginWait(waitID)
        let clock = self.clock
        let timer = Task {
            do {
                try await clock.sleep(for: PhoneAppConstants.answerAttributionWait)
            } catch {
                return
            }
            self.expirePhoneAnswerWait(waitID)
        }
        for key in keys {
            while phoneAnswerLedger.isAnswering(key), phoneAnswerLedger.isWaiting(waitID) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    phoneAnswerLedger.wait(key, waitID: waitID, continuation)
                }
            }
        }
        timer.cancel()
        phoneAnswerLedger.endWait(waitID)
    }

    /// Ends the wait `waitID` for running phone answers, when its time ran
    /// out before the answers finished.
    private func expirePhoneAnswerWait(_ waitID: UInt64) {
        for waiter in phoneAnswerLedger.expire(waitID) {
            waiter.resume()
        }
    }

    /// How many prompt reads wait for a phone's answer to finish. For tests.
    func phoneAnswerWaiterCount() -> Int {
        phoneAnswerLedger.waiterCount
    }

    // MARK: - prompt.changed

    /// Starts `prompt.changed` for `session` on the device, in place of any
    /// feed it had. The first event carries the session's set as soon as it
    /// is read, then one follows every change. A local session's set is read
    /// from the pending prompt store (`PhoneLocalPromptSource`); a remote
    /// session's from the laptop's remote session list, once at once and
    /// again on every `.remoteSessionsChanged` (`PhoneRemotePromptSource`),
    /// on a task of its own so a slow read never holds up the transcript.
    /// Does nothing for a device with no state.
    ///
    /// The transcript feed calls this once its `transcript.open` reply is
    /// queued, so the events follow the reply.
    func openPrompts(_ session: PhoneSessionRef, for deviceID: UUID) {
        guard devices[deviceID] != nil else { return }
        let earlier = devices[deviceID]?.prompts?.source
        let token = mintToken()
        let source: any PhonePromptSource
        switch session {
        case .local(let terminalID):
            source = PhoneLocalPromptSource(
                terminalID: terminalID, store: pendingPrompts, subscriptions: subscriptions,
                deliver: { [weak self] open, resolved in
                    await self?.localPromptsRead(open, resolved: resolved, deviceID: deviceID, token: token)
                })
        case .remote(let provider, let sessionID):
            source = PhoneRemotePromptSource(
                provider: provider, sessionID: sessionID, actions: actions, subscriptions: subscriptions,
                deliver: { [weak self] open in
                    await self?.remotePromptsRead(open, deviceID: deviceID, token: token)
                })
        }
        devices[deviceID]?.prompts = PhonePromptFeed(token: token, set: PhonePromptSet(session: session), source: source)
        // The earlier source's subscriber goes before the new one's comes.
        Task {
            await earlier?.stop()
            await source.start()
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

    /// What `PhoneRemotePromptSource` read, one read at a time, for the
    /// prompt feed `token` names: once when the feed starts and again after
    /// every `.remoteSessionsChanged`. Does nothing once a later feed
    /// replaced it.
    private func remotePromptsRead(_ prompts: [RemotePendingPrompt], deviceID: UUID, token: UInt64) async {
        await promptsRead(
            prompts.map(PhonePromptShaper.remote), openedAt: [:], localResolutions: nil,
            deviceID: deviceID, token: token)
    }

    private func localPromptsRead(
        _ open: [PendingPromptPayload], resolved: [String: PendingPromptStore.Resolution], deviceID: UUID, token: UInt64
    ) async {
        var openedAt: [String: Date] = [:]
        for payload in open {
            openedAt[payload.id] = payload.createdAt
        }
        await promptsRead(
            open.map(PhonePromptShaper.local), openedAt: openedAt, localResolutions: resolved,
            deviceID: deviceID, token: token)
    }

    /// Emits the `prompt.changed` that brings the device from the set it was
    /// last sent to `current`, if anything changed, unless a later feed
    /// replaced the one `token` names. `openedAt` is when each prompt in
    /// `current` was opened, by prompt ID, where known.
    private func promptsRead(
        _ current: [PhonePrompt], openedAt: [String: Date],
        localResolutions: [String: PendingPromptStore.Resolution]?, deviceID: UUID, token: UInt64
    ) async {
        guard let feed = devices[deviceID]?.prompts, feed.token == token else { return }
        let session = feed.set.session
        let closedIDs = feed.set.closedIDs(in: current)
        let closed = closedIDs.map { PhonePromptAnswerLedger.Key(session: session, promptID: $0) }
        let answers = await phoneAnswers(for: closed, openedAt: feed.set.openedAt(of: closedIDs))
        guard var latest = devices[deviceID]?.prompts, latest.token == token else { return }
        let attribution = PhonePromptAttribution(phoneAnswers: answers, localResolutions: localResolutions)
        let changed = latest.set.advance(to: current, openedAt: openedAt, attribution: attribution)
        devices[deviceID]?.prompts = latest
        guard let data = changed else { return }
        emit(.promptChanged, data: data, to: deviceID)
    }

    /// The device's open-session prompt feed's session, or nil with none.
    /// For tests.
    func promptsSession(for deviceID: UUID) -> PhoneSessionRef? {
        devices[deviceID]?.prompts?.set.session
    }
}
