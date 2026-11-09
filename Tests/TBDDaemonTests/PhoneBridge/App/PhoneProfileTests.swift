import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `profiles.list`, `session.switchProfile` and `session.fork`, driven
/// through `handleAppMessage`. Tier 1: the service over an in-memory database
/// with seeded profiles and terminals, and fake session actions that record
/// what would have reached the daemon. Nothing touches the disk, tmux or the
/// network.
@Suite("Phone profiles, switch profile and fork", .fastPassBounded)
struct PhoneProfileTests {
    private static let remoteSession = PhoneSessionRef.remote(provider: "acme-cloud", sessionID: "rs-1")

    /// A swap's success, as `terminal.swapProfile` answers it: the terminal
    /// row it switched or made.
    private static func swapped(_ terminalID: UUID) throws -> RPCResponse {
        try RPCResponse(result: TBDShared.Terminal(
            id: terminalID, worktreeID: UUID(), tmuxWindowID: "@2", tmuxPaneID: "%2",
            claudeSessionID: "acme-session", kind: .claude))
    }

    private static func sessionRef(_ bytes: Data) throws -> PhoneSessionRef {
        try JSONDecoder().decode(PhoneReplyEnvelope<SessionRefResult>.self, from: bytes).result.session
    }

    /// The swaps that reached the daemon, as `[terminal, profile, mode]`.
    private static func swaps(_ h: PhoneServiceHarness) -> [[String]] {
        h.actions.swaps.map { swap in
            [swap.terminalID.uuidString, swap.newProfileID?.uuidString ?? "<none>", swap.mode?.rawValue ?? "<none>"]
        }
    }

    // MARK: - profiles.list

    /// A profile carries its ID, name, kind and whether it is the default,
    /// and nothing else: no environment override, endpoint, AWS profile or
    /// model of a profile, and no global environment override, appears
    /// anywhere in the reply.
    @Test func profilesCarryOnlyIDNameKindAndDefault() async throws {
        let h = try await PhoneServiceHarness.make()
        let proxy = try await h.db.modelProfiles.create(
            name: "Acme Proxy", kind: .apiKey, baseURL: "https://acme-proxy.example/secret-path",
            model: "acme-secret-model")
        try await h.db.modelProfiles.setEnvOverrides(
            id: proxy.id, overrides: ["ANTHROPIC_API_KEY": "sk-test-secret"])
        let bedrock = try await h.db.modelProfiles.create(
            name: "Acme Bedrock", kind: .bedrock, awsRegion: "us-west-2", awsProfile: "acme-secret-aws-profile")
        try await h.db.config.setDefaultProfileID(bedrock.id)
        try await h.db.config.setEnvOverrides(["ACME_GLOBAL_TOKEN": "sk-global-secret"])
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.profilesList, params: PhoneEmpty(), on: outbox)

        #expect(reply.error == nil)
        let result = try JSONDecoder().decode(PhoneReplyEnvelope<ProfilesListResult>.self, from: bytes).result
        #expect(result.profiles == [
            PhoneProfile(id: proxy.id, name: "Acme Proxy", kind: "apiKey", isDefault: false),
            PhoneProfile(id: bedrock.id, name: "Acme Bedrock", kind: "bedrock", isDefault: true),
        ])
        let first = try #require(result.profiles.first)
        let object = try JSONSerialization.jsonObject(with: PhoneAppCoding.makeEncoder().encode(first))
        let keys = Set(try #require(object as? [String: Any]).keys)
        #expect(keys == ["id", "name", "kind", "isDefault"])
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in [
            "sk-test-secret", "ANTHROPIC_API_KEY", "acme-proxy.example", "secret-path", "acme-secret-model",
            "acme-secret-aws-profile", "us-west-2", "sk-global-secret", "ACME_GLOBAL_TOKEN",
        ] {
            #expect(!text.contains(secret), "the reply carries \(secret)")
        }
        // A pure read: it calls nothing and records nothing.
        #expect(h.actions.calls.isEmpty)
        #expect(h.recorder.records.isEmpty)
    }

    @Test func noProfilesIsAnEmptyList() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(.profilesList, params: PhoneEmpty(), on: outbox)

        #expect(reply.error == nil)
        let result = try JSONDecoder().decode(PhoneReplyEnvelope<ProfilesListResult>.self, from: bytes).result
        #expect(result.profiles.isEmpty)
    }

    /// A long name is cut to the field limit, at a character boundary.
    @Test func aLongProfileNameIsCut() {
        let profile = ModelProfile(name: String(repeating: "é", count: 1_000), kind: .oauth)

        let shown = PhoneAppService.phoneProfile(profile, defaultID: nil)

        #expect(shown.name.utf8.count <= PhoneText.fieldLimit)
        #expect(shown.name == String(repeating: "é", count: PhoneText.fieldLimit / 2))
        #expect(shown.isDefault == false)
    }

    /// Profiles past what fits the budget are dropped from the end, and the
    /// result always fits it.
    @Test func profilesPastTheBudgetAreDroppedFromTheEnd() throws {
        let profiles = (0..<500).map { index in
            PhoneProfile(
                id: UUID(), name: String(repeating: "a", count: PhoneText.fieldLimit), kind: "oauth",
                isDefault: index == 0)
        }

        let fitted = PhoneAppService.fittedProfiles(profiles)

        #expect(!fitted.profiles.isEmpty)
        #expect(fitted.profiles.count < profiles.count)
        #expect(fitted.profiles == Array(profiles.prefix(fitted.profiles.count)))
        let encoded = try PhoneAppCoding.makeEncoder().encode(fitted)
        #expect(encoded.count <= PhoneAppService.profilesResultBytes)
        let reply = try PhoneAppCoding.reply(
            requestID: String(repeating: "r", count: PhoneAppConstants.requestIDMaxBytes), result: fitted)
        #expect(PhoneAppCoding.framedSize(reply) <= PhoneFrameBudget.maxPlaintext)
    }

    /// A profile too large for what is left of the budget is left out alone:
    /// the profiles after it that fit are still kept, in order.
    @Test func aProfileThatDoesNotFitDropsOnlyItself() throws {
        let short = PhoneProfile(id: UUID(), name: "Acme Work", kind: "oauth", isDefault: true)
        let long = PhoneProfile(
            id: UUID(), name: String(repeating: "a", count: PhoneText.fieldLimit), kind: "oauth", isDefault: false)
        let after = PhoneProfile(id: UUID(), name: "Acme Home", kind: "oauth", isDefault: false)
        let budget = try PhoneAppCoding.makeEncoder().encode(ProfilesListResult(profiles: [short, after])).count

        let fitted = PhoneAppService.fittedProfiles([short, long, after], budget: budget)

        #expect(fitted.profiles == [short, after])
    }

    // MARK: - session.switchProfile

    @Test func switchProfileSwapsInPlace() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .swapProfile, with: try Self.swapped(terminal.id))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.sessionRef(bytes) == .local(terminalID: terminal.id))
        #expect(Self.swaps(h) == [[terminal.id.uuidString, profile.id.uuidString, "inPlace"]])
        // The identity is the verified peer's, and the record names only the
        // session, never the profile.
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .swapProfile, deviceID: h.peer.deviceID)])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "session.switchProfile", target: "local:\(terminal.id.uuidString)")])
    }

    /// A parked session takes the swap's cold path: the phone asks for the
    /// same in-place swap, and the daemon moves the parked row.
    @Test func switchProfileOnAParkedSessionIsTheSameSwap() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        h.actions.respond(to: .swapProfile, with: try Self.swapped(terminal.id))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.sessionRef(bytes) == .local(terminalID: terminal.id))
        #expect(Self.swaps(h) == [[terminal.id.uuidString, profile.id.uuidString, "inPlace"]])
    }

    @Test func switchProfileOnRemoteIsUnsupported() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: Self.remoteSession, profileID: profile.id), on: outbox)

        #expect(reply.error == PhoneAppError(code: .unsupported, message: "Not available for remote sessions."))
        #expect(h.actions.calls.isEmpty)
    }

    /// A Codex session, a shell and a tab in a remote lane are refused before
    /// anything is called, with the reason the sessions list gives where it
    /// gives one.
    @Test(arguments: [
        (TerminalKind.codex, false, "Codex sessions show status only."),
        (TerminalKind.shell, false, "Only a Claude session can switch profiles or fork."),
        (TerminalKind.claude, true, "This tab belongs to a remote lane. Use its remote session."),
    ])
    func switchProfileOnASessionThatIsNotLocalClaudeIsUnsupported(
        _ kind: TerminalKind, _ inRemoteLane: Bool, _ reason: String
    ) async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal(kind: kind, inRemoteLane: inRemoteLane)
        let outbox = await h.connect()

        let (switched, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)
        let (forked, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: nil),
            on: outbox)

        #expect(switched.error == PhoneAppError(code: .unsupported, message: reason))
        #expect(forked.error == PhoneAppError(code: .unsupported, message: reason))
        #expect(h.actions.calls.isEmpty)
    }

    @Test func switchProfileToAMissingProfileIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: UUID()),
            on: outbox)

        #expect(reply.error == PhoneAppError(code: .notFound, message: "That profile is no longer on this laptop."))
        #expect(h.actions.calls.isEmpty)
    }

    @Test func switchProfileOnAMissingSessionIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: UUID()), profileID: profile.id),
            on: outbox)

        #expect(reply.error?.code == .notFound)
        #expect(h.actions.calls.isEmpty)
    }

    @Test func aRefusedSwapReturnsTheDaemonsReason() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .swapProfile, with: RPCResponse(error: "Profile not found or unreadable"))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "Profile not found or unreadable"))
    }

    /// A swap that answers success with no terminal row is never taken for a
    /// success.
    @Test func aSwapResultThatDoesNotDecodeIsInternal() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .swapProfile, with: .ok())
        let outbox = await h.connect()

        let (switched, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)
        let (forked, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: nil),
            on: outbox)

        #expect(switched.error?.code == .internalError)
        #expect(forked.error?.code == .internalError)
    }

    /// Switch and fork read a local session through the same capability
    /// check as `prompt.answer` (`phoneCapableClaudeTerminal`). The setting
    /// for answering prompts gates answering only, so with it off both still
    /// reach the swap.
    @Test func switchAndForkIgnoreTheAnswerSetting() async throws {
        let h = try await PhoneServiceHarness.make()
        try await h.db.config.setTranscriptPromptAnswerEnabled(false)
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        let forkID = UUID()
        let outbox = await h.connect()

        h.actions.respond(to: .swapProfile, with: try Self.swapped(terminal.id))
        let (switched, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)
        h.actions.respond(to: .swapProfile, with: try Self.swapped(forkID))
        let (forked, forkBytes) = try await h.request(
            .sessionFork,
            params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: profile.id), on: outbox)

        #expect(switched.error == nil)
        #expect(forked.error == nil)
        #expect(try Self.sessionRef(forkBytes) == .local(terminalID: forkID))
        #expect(Self.swaps(h) == [
            [terminal.id.uuidString, profile.id.uuidString, "inPlace"],
            [terminal.id.uuidString, profile.id.uuidString, "fork"],
        ])
    }

    /// Switch and fork never read the setting for answering prompts, which
    /// gates neither (`listedCapability`), so a config row that cannot be
    /// read does not stop them: both reach the swap. An answer on the same
    /// session does read it, and is refused for the unreadable setting,
    /// which shows the row is unreadable.
    @Test func switchAndForkDoNotReadTheAnswerSetting() async throws {
        let h = try await PhoneServiceHarness.make(phoneControlAlwaysOn: true)
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        let forkID = UUID()
        let outbox = await h.connect()
        try await h.makeConfigUnreadable()

        h.actions.respond(to: .swapProfile, with: try Self.swapped(terminal.id))
        let (switched, _) = try await h.request(
            .sessionSwitchProfile,
            params: SessionSwitchProfileParams(session: .local(terminalID: terminal.id), profileID: profile.id),
            on: outbox)
        h.actions.respond(to: .swapProfile, with: try Self.swapped(forkID))
        let (forked, forkBytes) = try await h.request(
            .sessionFork,
            params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: profile.id), on: outbox)
        let (answered, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(
                session: .local(terminalID: terminal.id), promptID: "p-1",
                answer: .permission(decision: .allow, message: nil)),
            on: outbox)

        #expect(switched.error == nil)
        #expect(forked.error == nil)
        #expect(try Self.sessionRef(forkBytes) == .local(terminalID: forkID))
        #expect(Self.swaps(h) == [
            [terminal.id.uuidString, profile.id.uuidString, "inPlace"],
            [terminal.id.uuidString, profile.id.uuidString, "fork"],
        ])
        #expect(answered.error == PhoneAppError(
            code: .unsupported, message: PhoneSessionStatus.answerSettingUnreadReason))
        #expect(h.actions.answers.isEmpty)
    }

    // MARK: - session.fork

    @Test func forkRepliesWithTheNewSession() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        let forkID = UUID()
        h.actions.respond(to: .swapProfile, with: try Self.swapped(forkID))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionFork,
            params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: profile.id), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.sessionRef(bytes) == .local(terminalID: forkID))
        #expect(Self.swaps(h) == [[terminal.id.uuidString, profile.id.uuidString, "fork"]])
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .swapProfile, deviceID: h.peer.deviceID)])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "session.fork", target: "local:\(terminal.id.uuidString)")])
    }

    /// No profile named forks under the session's own profile.
    @Test func forkWithoutAProfileKeepsTheCurrentOne() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal(profileID: profile.id)
        h.actions.respond(to: .swapProfile, with: try Self.swapped(UUID()))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: nil),
            on: outbox)

        #expect(reply.error == nil)
        #expect(Self.swaps(h) == [[terminal.id.uuidString, profile.id.uuidString, "fork"]])
    }

    /// A session with no profile runs on the laptop's own login, which the
    /// swap names with no profile, so its fork names none either.
    @Test func forkOfASessionWithNoProfileNamesNone() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .swapProfile, with: try Self.swapped(UUID()))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: nil),
            on: outbox)

        #expect(reply.error == nil)
        #expect(Self.swaps(h) == [[terminal.id.uuidString, "<none>", "fork"]])
    }

    /// A parked session forks as a running one does, without a wake first:
    /// the same fork goes to the daemon, whose swap copies the conversation
    /// into a new tab and leaves the parked session as it is, and the reply
    /// names the new tab.
    @Test func forkOfAParkedSessionForks() async throws {
        let h = try await PhoneServiceHarness.make()
        let profile = try await h.db.modelProfiles.create(name: "Acme Work", kind: .oauth)
        let terminal = try await h.seedTerminal()
        try await h.park(terminal.id)
        let forkID = UUID()
        h.actions.respond(to: .swapProfile, with: try Self.swapped(forkID))
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionFork,
            params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: profile.id), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.sessionRef(bytes) == .local(terminalID: forkID))
        #expect(Self.swaps(h) == [[terminal.id.uuidString, profile.id.uuidString, "fork"]])
        // The swap is the only call: nothing wakes the parked session first.
        #expect(h.actions.calls == [FakeSessionActions.Call(method: .swapProfile, deviceID: h.peer.deviceID)])
    }

    @Test func forkUnderAMissingProfileIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: .local(terminalID: terminal.id), profileID: UUID()),
            on: outbox)

        #expect(reply.error?.code == .notFound)
        #expect(h.actions.calls.isEmpty)
    }

    @Test func forkOfARemoteSessionIsUnsupported() async throws {
        let h = try await PhoneServiceHarness.make()
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .sessionFork, params: SessionForkParams(session: Self.remoteSession, profileID: nil), on: outbox)

        #expect(reply.error == PhoneAppError(code: .unsupported, message: "Not available for remote sessions."))
        #expect(h.actions.calls.isEmpty)
    }

    /// The same request ID twice forks once, and the resend gets the first
    /// reply byte for byte.
    @Test func aResentForkForksOnce() async throws {
        let h = try await PhoneServiceHarness.make()
        let terminal = try await h.seedTerminal()
        h.actions.respond(to: .swapProfile, with: try Self.swapped(UUID()))
        let outbox = await h.connect()
        let params = SessionForkParams(session: .local(terminalID: terminal.id), profileID: nil)

        let (first, firstBytes) = try await h.request(.sessionFork, id: "fork-1", params: params, on: outbox)
        let (again, againBytes) = try await h.request(.sessionFork, id: "fork-1", params: params, on: outbox)

        #expect(first.error == nil)
        #expect(again.error == nil)
        #expect(h.actions.swaps.count == 1)
        #expect(againBytes == firstBytes)
    }
}
