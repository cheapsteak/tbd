import Foundation
import os
import TBDShared

/// `worktree.create`, `remote.providers` and `remote.create` (spec section
/// 4.4, and section 5's "New worktree" and "Remote sessions").
///
/// **The phone creates only under a repo it can see.** Both creates take the
/// repo from the row the user tapped, and `remote.providers` may name one to
/// prefill the forms. A repo that is gone, or hidden, which the sessions list
/// never shows, is `not_found`; so is a provider that is not registered. Each
/// handler reads these rows itself before it calls the action.
///
/// **Each create goes through one action** under the device of the verified
/// pairing, `context.peer.deviceID`: `phoneCreateWorktree`, which keeps only
/// the repo and the first message, and `phoneRemoteCreate`, which keeps only
/// the provider and the form values. A refusal is `refused` with the daemon's
/// reason; a success whose result does not decode is `internal`, never a
/// success. Both creates are in the request memory (`remembersReplies(of:)`),
/// so a resend creates once and gets the first reply. Their records name the
/// repo or the provider, never the message or a form value.
///
/// **A provider's form reaches the phone field by field.** `remote.providers`
/// sends each provider's name, whether it is ready and why not, whether it
/// takes a first message, and for each field its name, type, label, whether
/// it is required, an `enum` field's choices and the value TBD would fill in.
/// It never sends a provider's command, arguments, identity, remediation
/// command or contract details. The `repo` and `prompt` fields are TBD's to
/// fill, from the tapped repo and the phone's message, so the phone neither
/// sees nor sets them.
extension PhoneAppService {
    static let noSuchRepoReason = "That repo is no longer on this laptop."
    static let providerTakesNoMessageReason = "This provider does not take a first message."
    static let notAFormFieldReason = "The form has a value this provider does not ask for."
    static let tooManyFormValuesReason = "The form has too many values."
    static let formValueTooLongReason = "A value in the form is too long."
    static let notAChoiceReason = "A value in the form is not one of its choices."
    static let incompleteFormReason = "The form is not complete."
    static let providerNotReadyReason = "This provider is not ready on this laptop."
    static let providerNeedsSignInReason = "Sign in to this provider on your laptop."
    static let noCreateFormReason = "This provider has not reported its create form yet."
    static let repoHasNoRemoteReason = "This repo has no remote that this provider can use."
    static let worktreeCreateFailedReason = "The worktree could not be created. Check the laptop."

    /// The create field TBD fills with the phone's first message.
    static let promptFieldName = "prompt"
    /// The field type whose value is a bool, not a string.
    static let boolFieldType = "bool"
    /// The field type whose value is one of the field's choices.
    static let enumFieldType = "enum"
    /// The most values one `remote.create` may carry, strings and bools
    /// together, and the most fields of one provider's form the phone is
    /// sent.
    static let formValuesMax = 64
    /// The most UTF-8 bytes of one form value, either way: a longer prefill
    /// is not sent, and a longer value from the phone is `bad_request`.
    static let formValueMaxBytes = 4_096
    /// The most choices of one `enum` field the phone is sent.
    static let formChoicesMax = 100
    /// The most bytes a `remote.providers` result may encode to, leaving the
    /// rest of one frame for the reply's envelope.
    static let providersResultBytes = PhoneFrameBudget.eventDataBytes

    // MARK: - worktree.create

    /// Creates a worktree in the tapped repo with the phone's message as its
    /// first message, and every other choice TBD's default, then waits up to
    /// `PhoneAppConstants.worktreeSessionWait` for its first agent session.
    ///
    /// A message over `PhoneAppConstants.messageMaxBytes` is `bad_request`. A
    /// blank message (empty, or only whitespace and invisible format
    /// characters, `PhoneMessageText.isBlank`) creates the worktree with no
    /// first message, so its agent starts idle. Any other message goes to
    /// `phoneCreateWorktree` as it came, which holds it to the phone message
    /// rule and refuses one holding a control character; that refusal is
    /// `refused`, as the send path's is.
    ///
    /// The reply carries the worktree's ID and, when the wait found one, its
    /// first agent session (`firstAgentSession(inWorktree:)`). When the wait
    /// runs out the session is absent, and the phone picks it up from
    /// `sessions.changed`. A create that fails in the background during the
    /// wait is `refused` with `worktreeCreateFailedReason`.
    nonisolated func worktreeCreate(
        _ params: PhoneWorktreeCreateParams, _ context: DeviceContext
    ) async throws -> PhoneWorktreeCreateResult {
        guard params.message.utf8.count <= PhoneAppConstants.messageMaxBytes else {
            throw PhoneAppError(code: .badRequest, message: Self.messageTooLongReason)
        }
        _ = try await visibleRepo(params.repoID)
        let prompt = PhoneMessageText.isBlank(params.message) ? nil : params.message
        try Task.checkCancellation()
        let response = try await actions.phoneCreateWorktree(
            WorktreeCreateParams(repoID: params.repoID, prompt: prompt), deviceID: context.peer.deviceID)
        let worktree = try Self.succeeded(Worktree.self, from: response, method: "worktree.create")
        let terminalID = try await firstAgentSession(inWorktree: worktree.id)
        return PhoneWorktreeCreateResult(
            worktreeID: worktree.id, session: terminalID.map { PhoneSessionRef.local(terminalID: $0) })
    }

    /// The first agent tab of `worktreeID` (`lookForAgentTerminal`), waiting
    /// up to `PhoneAppConstants.worktreeSessionWait` for one to appear, or nil
    /// when none did in time.
    ///
    /// `worktree.create` returns before its agent's tab exists, so this
    /// subscribes to state deltas, looks once right after subscribing, so a
    /// tab made before the subscription is not missed, and looks again after
    /// every delta, bursts folded into one look. The first look runs before
    /// the wait's clock starts; the later looks race a sleep on the service's
    /// clock in a task group, and the loser is cancelled. The subscriber is
    /// removed on every way out: found, timed out, the create failed, or the
    /// request cancelled.
    ///
    /// **A create that fails in the background ends the wait.** It runs after
    /// `worktree.create` has replied, and its rollback deletes the worktree
    /// row and broadcasts a delta, so the next look finds the row gone and
    /// the wait ends `refused` with `worktreeCreateFailedReason`, never a
    /// success naming a worktree that no longer exists.
    ///
    /// It takes the first agent tab, Claude or Codex, whichever the user's
    /// primary agent setting started; a shell tab is not a session the phone
    /// shows.
    nonisolated func firstAgentSession(inWorktree worktreeID: UUID) async throws -> UUID? {
        let (wakeups, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscriptions = self.subscriptions
        let subscriberID = subscriptions.addSubscriber { _ in
            continuation.yield()
            return true
        }
        defer {
            subscriptions.removeSubscriber(subscriberID)
            continuation.finish()
        }
        let db = self.db
        // The first look, after the subscriber is in place, so no tab falls
        // between them. A delta that lands while it reads is kept in the
        // stream and looked at again below.
        if let terminalID = try await Self.lookForAgentTerminal(inWorktree: worktreeID, db: db) {
            return terminalID
        }
        let clock = self.clock
        return try await withThrowingTaskGroup(of: UUID?.self, returning: UUID?.self) { group in
            group.addTask {
                for await _ in wakeups {
                    if let terminalID = try await Self.lookForAgentTerminal(inWorktree: worktreeID, db: db) {
                        return terminalID
                    }
                }
                // The stream ends only when this task is cancelled.
                return nil
            }
            group.addTask {
                try await clock.sleep(for: PhoneAppConstants.worktreeSessionWait)
                return nil
            }
            let first: UUID? = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// One look at `worktreeID`: the first of its tabs, in the order tabs
    /// were made, that runs an agent by the sessions list's reading
    /// (`PhoneSnapshotBuilder.agent`), or nil when it has none yet.
    ///
    /// A worktree row that is gone means the create failed and rolled back:
    /// `refused` with `worktreeCreateFailedReason`. A read that fails is
    /// logged and counts as no tab yet, so the next delta or the wait's end
    /// decides; one the wait's end cancelled is not logged.
    private static func lookForAgentTerminal(inWorktree worktreeID: UUID, db: TBDDatabase) async throws -> UUID? {
        let worktree: Worktree?
        let terminals: [TBDShared.Terminal]
        do {
            worktree = try await db.worktrees.get(id: worktreeID)
            terminals = try await db.terminals.list(worktreeID: worktreeID)
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.error(
                "Phone worktree.create: could not read the new worktree: \(Self.errorType(error), privacy: .public)")
            return nil
        }
        guard worktree != nil else {
            Self.logger.notice(
                "Phone worktree.create: worktree \(worktreeID, privacy: .public) is gone, so its create failed")
            throw PhoneAppError(code: .refused, message: worktreeCreateFailedReason)
        }
        return terminals.first { terminal in PhoneSnapshotBuilder.agent(of: terminal) != nil }?.id
    }

    // MARK: - remote.providers

    /// Every registered provider as a `PhoneProvider` (`phoneProvider`), in
    /// the laptop's order, as many as fit one frame (`fittedProviders`). With
    /// `params.repoID`, the forms are prefilled from that repo as well as from
    /// the laptop's own defaults, and a provider whose `repo` field the repo
    /// cannot answer is not ready.
    nonisolated func remoteProviders(
        _ params: PhoneRemoteProvidersParams, _ context: DeviceContext
    ) async throws -> PhoneRemoteProvidersResult {
        let repo: Repo?
        if let repoID = params.repoID {
            repo = try await visibleRepo(repoID)
        } else {
            repo = nil
        }
        let statuses = try await providerStatuses()
        let globalDefaults = try await db.config.get().remoteCreateDefaults
        let slug = NameGenerator.generate(date: now())
        return Self.fittedProviders(statuses.map { status in
            Self.phoneProvider(status, repo: repo, globalDefaults: globalDefaults, generatedSlug: slug)
        })
    }

    /// What the phone sees of one provider.
    ///
    /// A ready provider carries its form fields other than `repo` and
    /// `prompt`, the first `formValuesMax` of them (`phoneField`). One that is
    /// not ready (`unavailableReason`) carries why, and no fields.
    /// `acceptsPrompt` says whether its form has a `prompt` field, which the
    /// phone's message fills.
    static func phoneProvider(
        _ status: RemoteProviderStatus, repo: Repo?, globalDefaults: [String: String], generatedSlug: String?
    ) -> PhoneProvider {
        let fields = status.describe?.createParams ?? []
        let acceptsPrompt = fields.contains { field in field.name == promptFieldName }
        let plan = createPlan(fields: fields, repo: repo, globalDefaults: globalDefaults, generatedSlug: generatedSlug)
        if let reason = unavailableReason(status, repoPlan: repo == nil ? nil : plan) {
            return PhoneProvider(
                name: status.config.name, available: false, reason: reason, acceptsPrompt: acceptsPrompt, fields: [])
        }
        let formFields = fields
            .filter { field in !isFilledByTBD(field.name) }
            .prefix(formValuesMax)
            .map { field in phoneField(field, plan: plan) }
        return PhoneProvider(
            name: status.config.name, available: true, reason: nil, acceptsPrompt: acceptsPrompt,
            fields: Array(formFields))
    }

    /// Why a provider cannot create a session from the phone, or nil when it
    /// can:
    /// - **its health is `needsAuth`**: `providerNeedsSignInReason`;
    /// - **its health is `stale` or `error`**: `providerNotReadyReason`;
    /// - **it has not reported its form** (no `describe`), which disables the
    ///   laptop sheet's Create button: `noCreateFormReason`;
    /// - **`repoPlan` cannot answer its `repo` field**, because the repo has
    ///   no remote this provider can read: `repoHasNoRemoteReason`. A blank
    ///   `repo` would be left out of the request and answered by the
    ///   provider's own default repository, required or not.
    ///
    /// **The phone never gets a provider's health message**, only these fixed
    /// lines, as it gets fixed lines for an agent's error
    /// (`PhoneSessionStatus`). The provider manager falls back to the
    /// provider's raw stderr, or to the description of a Swift error, when a
    /// failing verb sends no contract error, and shortening that text does not
    /// make it safe: a wrapper's stderr can quote a URL with an access token
    /// in it. The laptop shows the message, where its user can act on it.
    static func unavailableReason(_ status: RemoteProviderStatus, repoPlan: RemoteCreateFormLogic.Plan?) -> String? {
        switch status.health {
        case .ok:
            break
        case .needsAuth:
            return providerNeedsSignInReason
        case .stale, .error:
            return providerNotReadyReason
        }
        guard status.describe != nil else { return noCreateFormReason }
        if repoPlan?.repoUnanswered == true { return repoHasNoRemoteReason }
        return nil
    }

    /// One form field as the phone sees it: its name, its type, its label cut
    /// to `PhoneText.fieldLimit` bytes, whether it is required, the first
    /// `formChoicesMax` of its choices no longer than `PhoneText.fieldLimit`
    /// bytes, and its prefill. A string field's prefill is the value the plan
    /// fills in, absent when it is empty or longer than `formValueMaxBytes`;
    /// a bool field's is `"true"` when the plan turns it on, and absent when
    /// off. Nothing is cut that the phone may send back: a choice or a prefill
    /// too long to keep is left out instead.
    static func phoneField(_ field: ProviderCreateParamField, plan: RemoteCreateFormLogic.Plan) -> PhoneFormField {
        let prefill: String?
        if field.type == boolFieldType {
            prefill = plan.boolValues[field.name] == true ? "true" : nil
        } else {
            let value = plan.stringValues[field.name] ?? ""
            prefill = value.isEmpty || value.utf8.count > formValueMaxBytes ? nil : value
        }
        let choices = field.values.map { values in
            Array(values.filter { value in value.utf8.count <= PhoneText.fieldLimit }.prefix(formChoicesMax))
        }
        return PhoneFormField(
            name: field.name,
            type: field.type,
            label: field.label.map { label in PhoneText.capped(label) },
            required: field.required,
            values: choices,
            prefill: prefill)
    }

    /// `providers` in order, as many as fit `budget` bytes once encoded as a
    /// `PhoneRemoteProvidersResult`. A provider that does not fit is left out
    /// and the next one tried, which takes a form far larger than any
    /// provider declares.
    static func fittedProviders(
        _ providers: [PhoneProvider], budget: Int = providersResultBytes
    ) -> PhoneRemoteProvidersResult {
        let encoder = PhoneAppCoding.makeEncoder()
        var used = (try? encoder.encode(PhoneRemoteProvidersResult(providers: [])).count) ?? 0
        var kept: [PhoneProvider] = []
        for provider in providers {
            // A provider's bytes, and a comma unless it is the first.
            let cost = ((try? encoder.encode(provider).count) ?? Int.max / 2) + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else { continue }
            used += cost
            kept.append(provider)
        }
        let dropped = providers.count - kept.count
        if dropped > 0 {
            Self.logger.notice(
                "Phone remote.providers: \(dropped, privacy: .public) of \(providers.count, privacy: .public) providers left out to fit one frame")
        }
        return PhoneRemoteProvidersResult(providers: kept)
    }

    // MARK: - remote.create

    /// Starts a remote session under the tapped repo with the provider's
    /// form, filled as the laptop's create sheet would fill it, and replies
    /// with the new session's reference.
    ///
    /// In order:
    /// 1. **Sizes** (`checkFormSize`): a message over
    ///    `PhoneAppConstants.messageMaxBytes`, more than `formValuesMax`
    ///    values, or a value over `formValueMaxBytes` is `bad_request`.
    /// 2. **What the phone names**: a repo that is gone or hidden, and a
    ///    provider that is not registered, are `not_found`.
    /// 3. **The form** (`remoteCreateParamsJSON`): the values, the message
    ///    and the provider's readiness.
    /// 4. **`phoneRemoteCreate`** with the provider and the form's JSON.
    nonisolated func remoteCreate(_ params: PhoneRemoteCreateParams, _ context: DeviceContext) async throws -> SessionRefResult {
        try Self.checkFormSize(params)
        let repo = try await visibleRepo(params.repoID)
        let statuses = try await providerStatuses()
        guard let status = statuses.first(where: { candidate in candidate.config.name == params.provider }) else {
            throw PhoneAppError(code: .notFound, message: Self.noSuchProviderReason)
        }
        let globalDefaults = try await db.config.get().remoteCreateDefaults
        let paramsJSON = try Self.remoteCreateParamsJSON(
            params, status: status, repo: repo, globalDefaults: globalDefaults,
            generatedSlug: NameGenerator.generate(date: now()))
        try Task.checkCancellation()
        let response = try await actions.phoneRemoteCreate(
            RemoteCreateParams(provider: params.provider, paramsJSON: paramsJSON), deviceID: context.peer.deviceID)
        let session = try Self.succeeded(RemoteSessionPayload.self, from: response, method: "remote.create")
        return SessionRefResult(session: .remote(provider: params.provider, sessionID: session.id))
    }

    /// The size checks `remote.create` makes before it reads anything: the
    /// message, how many values the form carries, and each value and key.
    static func checkFormSize(_ params: PhoneRemoteCreateParams) throws {
        guard params.message.utf8.count <= PhoneAppConstants.messageMaxBytes else {
            throw PhoneAppError(code: .badRequest, message: messageTooLongReason)
        }
        guard params.strings.count + params.bools.count <= formValuesMax else {
            throw PhoneAppError(code: .badRequest, message: tooManyFormValuesReason)
        }
        let stringsFit = params.strings.allSatisfy { key, value in
            key.utf8.count <= PhoneText.fieldLimit && value.utf8.count <= formValueMaxBytes
        }
        let boolsFit = params.bools.keys.allSatisfy { key in key.utf8.count <= PhoneText.fieldLimit }
        guard stringsFit, boolsFit else {
            throw PhoneAppError(code: .badRequest, message: formValueTooLongReason)
        }
    }

    /// The `paramsJSON` a phone's `remote.create` sends `provider`, built the
    /// way the laptop's create sheet builds it.
    ///
    /// 1. A provider that is not ready (`unavailableReason`, with `repo`'s
    ///    plan) is `unsupported`, with the reason `remote.providers` gives.
    /// 2. Every key of `strings` must name a field of the form that is not a
    ///    bool, and every key of `bools` a bool field, and neither may name
    ///    `repo` or `prompt`, which TBD fills; any other key is `bad_request`.
    /// 3. The string values (`vettedFormStrings`): no control characters, and
    ///    an `enum` field's value one of its choices.
    /// 4. The message (`remoteFirstMessage`).
    /// 5. The plan (`createPlan`, from `repo`, the laptop's defaults and
    ///    `generatedSlug`), with the phone's values laid over it, and the
    ///    message as `prompt`, empty when there is none, so a stored default
    ///    never stands in for a message the phone did not send.
    /// 6. `RemoteCreateFormLogic.buildParamsJSON`, whose failure, such as a
    ///    required field left blank, is `bad_request` with its description.
    static func remoteCreateParamsJSON(
        _ params: PhoneRemoteCreateParams, status: RemoteProviderStatus, repo: Repo,
        globalDefaults: [String: String], generatedSlug: String?
    ) throws -> String {
        let fields = status.describe?.createParams ?? []
        let plan = createPlan(fields: fields, repo: repo, globalDefaults: globalDefaults, generatedSlug: generatedSlug)
        if let reason = unavailableReason(status, repoPlan: plan) {
            throw PhoneAppError(code: .unsupported, message: reason)
        }
        let byName = Dictionary(fields.map { field in (field.name, field) }, uniquingKeysWith: { first, _ in first })
        for name in params.strings.keys {
            guard let field = byName[name], field.type != boolFieldType, !isFilledByTBD(name) else {
                throw PhoneAppError(code: .badRequest, message: notAFormFieldReason)
            }
        }
        for name in params.bools.keys {
            guard let field = byName[name], field.type == boolFieldType, !isFilledByTBD(name) else {
                throw PhoneAppError(code: .badRequest, message: notAFormFieldReason)
            }
        }
        let phoneStrings = try vettedFormStrings(params.strings, fields: byName)
        let acceptsPrompt = byName[promptFieldName] != nil
        let prompt = try remoteFirstMessage(params.message, acceptsPrompt: acceptsPrompt)
        var strings = plan.stringValues
        var bools = plan.boolValues
        strings.merge(phoneStrings) { _, phone in phone }
        bools.merge(params.bools) { _, phone in phone }
        if acceptsPrompt {
            strings[promptFieldName] = prompt ?? ""
        }
        switch RemoteCreateFormLogic.buildParamsJSON(fields: fields, stringValues: strings, boolValues: bools) {
        case .success(let json):
            return json
        case .failure(let error):
            throw PhoneAppError(code: .badRequest, message: error.errorDescription ?? incompleteFormReason)
        }
    }

    /// The phone's string form values, held to what the laptop's create sheet
    /// lets its user enter. `fields` is the form by field name, and every key
    /// of `strings` names one of them.
    ///
    /// 1. Every CRLF becomes LF, and a value holding a control character is
    ///    `refused` with `PhoneMessageText.controlCharacterRefusal`, the code
    ///    and words the phone's message gets for the same text. A provider can
    ///    paste a value into its session as it does the message.
    /// 2. An `enum` field's value must be one of the field's choices, the only
    ///    values the sheet's picker offers, or `bad_request` with
    ///    `notAChoiceReason`. A blank value passes here: the picker offers it
    ///    on a field that is not required, and `buildParamsJSON` refuses it on
    ///    one that is.
    ///
    /// Every value is checked for control characters before any for its
    /// choices, so the answer does not depend on the order of the keys.
    static func vettedFormStrings(
        _ strings: [String: String], fields: [String: ProviderCreateParamField]
    ) throws -> [String: String] {
        let normalized = strings.mapValues { value in PhoneMessageText.lineEndingsNormalized(value) }
        guard !normalized.values.contains(where: { value in PhoneMessageText.hasControlCharacter(value) }) else {
            throw PhoneAppError(code: .refused, message: PhoneMessageText.controlCharacterRefusal)
        }
        for (name, value) in normalized {
            guard let field = fields[name], field.type == enumFieldType,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard (field.values ?? []).contains(value) else {
                throw PhoneAppError(code: .badRequest, message: notAChoiceReason)
            }
        }
        return normalized
    }

    /// The phone's message as a new remote session's first message, held to
    /// the rule every phone message is (`PhoneMessageText`).
    ///
    /// A blank message is no message: nil. A non-blank one to a provider
    /// whose form has no `prompt` field is `bad_request`. Otherwise every
    /// CRLF becomes LF, and a message holding a control character is
    /// `refused` with `PhoneMessageText.controlCharacterRefusal`, the code
    /// and words the send path answers the same message with. The provider
    /// pastes the message into its session, where such a character would
    /// reach the agent as a key.
    static func remoteFirstMessage(_ message: String, acceptsPrompt: Bool) throws -> String? {
        guard !PhoneMessageText.isBlank(message) else { return nil }
        guard acceptsPrompt else {
            throw PhoneAppError(code: .badRequest, message: providerTakesNoMessageReason)
        }
        switch PhoneMessageText.vetted(message) {
        case .deliver(let text):
            return text
        case .refused(let reason):
            throw PhoneAppError(code: .refused, message: reason)
        }
    }

    // MARK: - Shared

    /// The plan the laptop's create sheet starts from, for `repo`'s row:
    /// `repo`'s remote as the `repo` field, `repo`'s stored values, the
    /// laptop's stored values, `generatedSlug` for a `slug` field, then each
    /// field's own default (`RemoteCreateFormLogic.plan`).
    static func createPlan(
        fields: [ProviderCreateParamField], repo: Repo?, globalDefaults: [String: String], generatedSlug: String?
    ) -> RemoteCreateFormLogic.Plan {
        RemoteCreateFormLogic.plan(
            fields: fields,
            repoPrefill: RemoteCreateFormLogic.repoPrefill(remoteURL: repo?.remoteURL),
            repoDefaults: repo?.remoteCreateDefaults ?? [:],
            globalDefaults: globalDefaults,
            generatedSlug: generatedSlug)
    }

    /// Whether TBD fills the create field `name` itself: `repo` from the
    /// tapped repo, `prompt` from the phone's message.
    static func isFilledByTBD(_ name: String) -> Bool {
        name == RemoteCreateFormLogic.repoFieldName || name == promptFieldName
    }

    /// The repo `repoID` names, when the phone can see it: it exists and is
    /// not hidden. Otherwise `not_found`.
    private nonisolated func visibleRepo(_ repoID: UUID) async throws -> Repo {
        guard let repo = try await db.repos.get(id: repoID), !repo.hidden else {
            throw PhoneAppError(code: .notFound, message: Self.noSuchRepoReason)
        }
        return repo
    }

    /// The registered providers, as `remote.providers` gives them. A list the
    /// daemon refuses to give is `refused` with its reason; one that does not
    /// decode is `internal`.
    nonisolated func providerStatuses() async throws -> [RemoteProviderStatus] {
        let response = try await actions.phoneRemoteProviders()
        return try Self.succeeded(RemoteProvidersResult.self, from: response, method: "remote.providers").providers
    }
}
