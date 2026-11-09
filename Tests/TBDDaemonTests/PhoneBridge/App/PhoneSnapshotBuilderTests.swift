import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib

/// Tier 1: the snapshot builder and the status mapping are pure functions of
/// their input. Nothing here touches the disk, a clock or the network.
@Suite("Phone snapshot builder")
struct PhoneSnapshotBuilderTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let available = PhoneCapability(available: true, reason: nil)

    /// 7 UTF-8 bytes that encode to 13 JSON bytes: a two-byte letter, a quote,
    /// a control character and a three-byte letter.
    private static let unit = "é\"\u{1}名"
    /// 280 bytes, over every field limit.
    private static let longText = String(repeating: unit, count: 40)

    // MARK: - Fixtures

    private static func input(
        repos: [Repo] = [], worktrees: [Worktree] = [], scratch: [Worktree] = [],
        terminals: [TBDShared.Terminal] = [], tabOrder: [UUID: [UUID]] = [:], tabLabels: [UUID: String] = [:],
        profiles: [ModelProfile] = [], states: [UUID: SessionState] = [:],
        openPrompts: [UUID: PendingPromptPayload] = [:],
        remoteSessions: [RemoteSessionInfo] = [], providers: [RemoteProviderStatus] = [],
        promptAnswerEnabled: Bool? = true
    ) -> PhoneSnapshotInput {
        PhoneSnapshotInput(
            repos: repos, worktrees: worktrees, scratch: scratch,
            terminals: Dictionary(grouping: terminals, by: { $0.worktreeID }),
            tabOrder: tabOrder, tabLabels: tabLabels, profiles: profiles, states: states,
            openPrompts: openPrompts, remoteSessions: remoteSessions, providers: providers,
            promptAnswerEnabled: promptAnswerEnabled)
    }

    private static func worktree(
        _ name: String, repo: UUID?, status: WorktreeStatus = .active, sortOrder: Int = 0,
        parent: UUID? = nil, location: WorktreeLocation = .local, createdAt: Date = base
    ) -> Worktree {
        Worktree(
            repoID: repo, name: name, displayName: name, branch: name, path: "/tmp/acme/\(name)",
            status: status, createdAt: createdAt, tmuxServer: "tbd-acme", sortOrder: sortOrder,
            parentWorktreeID: parent, location: location)
    }

    private static func terminal(
        in worktreeID: UUID, kind: TerminalKind?, createdAt: Date = base,
        claudeSessionID: String? = "acme-session", profileID: UUID? = nil
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1", createdAt: createdAt,
            claudeSessionID: claudeSessionID, profileID: profileID, kind: kind)
    }

    private static func remote(
        _ id: String, provider: String = "acme", repo: UUID? = nil, title: String? = nil,
        state: RemoteProcessState = .running, agentState: RemoteAgentState = .working,
        agentStateAt: String? = nil, pendingPrompt: RemotePendingPrompt? = nil,
        gone: Bool = false, dismissed: Bool = false, lastSeen: Date = base
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(
                id: id, title: title, state: state, agentState: agentState, agentStateAt: agentStateAt,
                pendingPrompt: pendingPrompt),
            gone: gone, dismissed: dismissed, lastSeen: lastSeen, resolvedRepoID: repo)
    }

    private static func provider(_ name: String, capabilities: [String] = []) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/local/bin/acme-provider"),
            describe: ProviderDescribe(name: name, capabilities: capabilities), health: .ok,
            errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
    }

    private static func state(_ value: SessionStateValue, at date: Date = base) -> SessionState {
        SessionState(value: value, source: .hookEvent("Stop"), observedAt: date)
    }

    private static func status(
        _ chip: PhoneStatusChip, at date: Date = base, reason: String? = nil, until: Date? = nil
    ) -> PhoneStatus {
        PhoneStatus(chip: chip, changedAt: PhoneTime.ms(date), reason: reason, untilAt: until.map { PhoneTime.ms($0) })
    }

    /// The one row with `id`, or a failure naming it.
    private static func row(_ id: String, in snapshot: PhoneSnapshot) throws -> PhoneRow {
        let found = snapshot.rows.first { $0.id == id }
        return try #require(found, "no row \(id)")
    }

    // MARK: - Order

    @Test func groupsFollowTheSidebar() throws {
        let a = UUID()
        let b = UUID()
        let repoA = Repo(id: a, path: "/tmp/acme/a", displayName: "acme-a")
        let repoB = Repo(id: b, path: "/tmp/acme/b", displayName: "acme-b")
        let notes = Self.worktree("notes", repo: nil)
        let mainA = Self.worktree("main", repo: a, status: .main)
        let fixLogin = Self.worktree("fix-login", repo: a, sortOrder: 1)
        let fixLoginTests = Self.worktree("fix-login-tests", repo: a, parent: fixLogin.id)
        let addSearch = Self.worktree("add-search", repo: a, sortOrder: 2)
        let mainB = Self.worktree("main", repo: b, status: .main)
        let matched = Self.remote("rs-1", repo: a)
        let unmatched = Self.remote("rs-2", title: "Migrate the billing tables")

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [repoA, repoB], worktrees: [addSearch, fixLoginTests, mainB, fixLogin, mainA, notes],
            scratch: [notes], remoteSessions: [unmatched, matched],
            providers: [Self.provider("acme"), Self.provider("acme-idle")]))

        let groupIDs = s.layout.map(\.id)
        #expect(groupIDs == ["scratch", "repo:\(a)", "repo:\(b)", "provider:acme"])
        let groupKinds = s.layout.map(\.kind)
        #expect(groupKinds == ["scratch", "repo", "repo", "provider"])
        let groupNames = s.layout.map(\.name)
        #expect(groupNames == ["Scratch", "acme-a", "acme-b", "acme"])
        try #require(s.layout.count == 4)
        #expect(s.layout[0].rows == [PhoneRowPlacement(id: notes.id.uuidString, depth: 0)])
        #expect(s.layout[1].rows == [
            PhoneRowPlacement(id: mainA.id.uuidString, depth: 0),
            PhoneRowPlacement(id: fixLogin.id.uuidString, depth: 0),
            PhoneRowPlacement(id: fixLoginTests.id.uuidString, depth: 1),
            PhoneRowPlacement(id: addSearch.id.uuidString, depth: 0),
            PhoneRowPlacement(id: "remote:acme/rs-1", depth: 0),
        ])
        #expect(s.layout[2].rows == [PhoneRowPlacement(id: mainB.id.uuidString, depth: 0)])
        #expect(s.layout[3].rows == [PhoneRowPlacement(id: "remote:acme/rs-2", depth: 0)])

        let rowIDs = s.rows.map(\.id)
        #expect(rowIDs == [
            notes.id.uuidString, mainA.id.uuidString, fixLogin.id.uuidString, fixLoginTests.id.uuidString,
            addSearch.id.uuidString, "remote:acme/rs-1", mainB.id.uuidString, "remote:acme/rs-2",
        ])
        #expect(s.omittedRows == 0)

        let fixRow = try Self.row(fixLogin.id.uuidString, in: s)
        #expect(fixRow.kind == "worktree")
        #expect(fixRow.name == "fix-login")
        #expect(!fixRow.remote)
        let billing = try Self.row("remote:acme/rs-2", in: s)
        #expect(billing.kind == "remoteSession")
        #expect(billing.name == "Migrate the billing tables")
        #expect(billing.remote)
        // With no title, a remote session's row is named by its ID.
        #expect(try Self.row("remote:acme/rs-1", in: s).name == "rs-1")
    }

    @Test func hiddenReposAndArchivedRowsAreLeftOut() throws {
        let shown = UUID()
        let hidden = UUID()
        let mainShown = Self.worktree("main", repo: shown, status: .main)
        let archived = Self.worktree("old-work", repo: shown, status: .archived)
        let mainHidden = Self.worktree("main", repo: hidden, status: .main)
        let archivedScratch = Self.worktree("old-notes", repo: nil, status: .archived)

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [
                Repo(id: shown, path: "/tmp/acme/shown", displayName: "acme"),
                Repo(id: hidden, path: "/tmp/acme/hidden", displayName: "acme-hidden", hidden: true),
            ],
            worktrees: [mainShown, archived, mainHidden], scratch: [archivedScratch],
            remoteSessions: [
                Self.remote("rs-dismissed-matched", repo: shown, dismissed: true),
                Self.remote("rs-dismissed", dismissed: true),
                // Matched to a hidden repo: it goes with its repo, as in the
                // sidebar.
                Self.remote("rs-hidden", repo: hidden),
            ],
            providers: [Self.provider("acme")]))

        let groupIDs = s.layout.map(\.id)
        #expect(groupIDs == ["repo:\(shown)"])
        let rowIDs = s.rows.map(\.id)
        #expect(rowIDs == [mainShown.id.uuidString])
        #expect(s.omittedRows == 0)
    }

    /// A remote lane's row stands for its remote session, which then gets no
    /// row of its own.
    @Test func aRemoteLaneRowCarriesItsRemoteSession() throws {
        let a = UUID()
        let lane = Self.worktree("lane", repo: a, location: .remote(provider: "acme", sessionID: "rs-3"))

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [lane],
            remoteSessions: [Self.remote("rs-3", repo: a, agentState: .idle)],
            providers: [Self.provider("acme", capabilities: [RemoteCapability.transcriptRead])]))

        let rowIDs = s.rows.map(\.id)
        #expect(rowIDs == [lane.id.uuidString])
        let row = try Self.row(lane.id.uuidString, in: s)
        #expect(row.remote)
        try #require(row.sessions.count == 1)
        let session = row.sessions[0]
        #expect(session.ref == .remote(provider: "acme", sessionID: "rs-3"))
        #expect(session.agent == .remote)
        #expect(session.tabName == "acme")
        #expect(session.status.chip == .idle)
        #expect(session.capabilities.transcript == Self.available)
        #expect(session.profileID == nil)
    }

    // MARK: - Sessions

    @Test func shellTabsAreHiddenAndCodexIsStatusOnly() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let shell = Self.terminal(in: w.id, kind: .shell, claudeSessionID: nil)
        let claude = Self.terminal(in: w.id, kind: .claude, createdAt: Self.base.addingTimeInterval(1))
        let codex = Self.terminal(in: w.id, kind: .codex, createdAt: Self.base.addingTimeInterval(2), claudeSessionID: nil)
        let kindlessShell = Self.terminal(in: w.id, kind: nil, createdAt: Self.base.addingTimeInterval(3), claudeSessionID: nil)
        // A row written before kinds were recorded, with a Claude session.
        let kindlessClaude = Self.terminal(in: w.id, kind: nil, createdAt: Self.base.addingTimeInterval(4))

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w],
            terminals: [shell, claude, codex, kindlessShell, kindlessClaude]))

        let sessions = try Self.row(w.id.uuidString, in: s).sessions
        let refs = sessions.map(\.ref)
        #expect(refs == [.local(terminalID: claude.id), .local(terminalID: codex.id), .local(terminalID: kindlessClaude.id)])
        let agents = sessions.map(\.agent)
        #expect(agents == [.claude, .codex, .claude])
        let tabNames = sessions.map(\.tabName)
        #expect(tabNames == ["Claude", "Codex", "Claude"])
        try #require(sessions.count == 3)

        let statusOnly = PhoneCapability(available: false, reason: "Codex sessions show status only.")
        #expect(sessions[1].capabilities == PhoneCapabilities(
            transcript: PhoneCapability(available: false, reason: "Codex transcripts arrive in a later TBD release"),
            send: statusOnly, answer: statusOnly, switchProfile: statusOnly, fork: statusOnly, model: statusOnly))
        #expect(sessions[0].capabilities == PhoneCapabilities(
            transcript: Self.available, send: Self.available, answer: Self.available,
            switchProfile: Self.available, fork: Self.available, model: Self.available))
    }

    /// A row saved before terminals recorded their kind is listed as Claude
    /// once it has a Claude session, but the laptop's composer is hidden for
    /// it (`ComposerState.resolve`), so every send would be refused. The list
    /// does not offer Send or Model for it.
    @Test func aKindlessClaudeRowOffersNoSendOrModel() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let kindlessClaude = Self.terminal(in: w.id, kind: nil)
        var parkedKindless = Self.terminal(in: w.id, kind: nil, createdAt: Self.base.addingTimeInterval(1))
        parkedKindless.hibernatedAt = Self.base

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w],
            terminals: [kindlessClaude, parkedKindless]))

        let sessions = try Self.row(w.id.uuidString, in: s).sessions
        try #require(sessions.count == 2)
        let noMessages = PhoneCapability(available: false, reason: "This session cannot take messages.")
        #expect(sessions[0].capabilities == PhoneCapabilities(
            transcript: Self.available, send: noMessages, answer: Self.available,
            switchProfile: Self.available, fork: Self.available, model: noMessages))
        #expect(sessions[1].capabilities == PhoneCapabilities(
            transcript: Self.available, send: noMessages, answer: Self.available,
            switchProfile: Self.available, fork: Self.available, model: noMessages))
        // The send path refuses it with the same words.
        #expect(PhoneAppService.cannotTakeMessagesReason == noMessages.reason)
    }

    /// A parked Claude session offers everything a running one does. Send
    /// wakes it, Switch Profile moves it to the profile without waking it,
    /// and Fork copies its conversation into a new tab and leaves it parked.
    @Test func aParkedSessionOffersEverythingARunningOneDoes() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let running = Self.terminal(in: w.id, kind: .claude)
        var parked = Self.terminal(in: w.id, kind: .claude, createdAt: Self.base.addingTimeInterval(1))
        parked.hibernatedAt = Self.base

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w],
            terminals: [running, parked]))

        let sessions = try Self.row(w.id.uuidString, in: s).sessions
        try #require(sessions.count == 2)
        let everything = PhoneCapabilities(
            transcript: Self.available, send: Self.available, answer: Self.available,
            switchProfile: Self.available, fork: Self.available, model: Self.available)
        #expect(sessions[0].capabilities == everything)
        #expect(sessions[1].capabilities == everything)
    }

    @Test func everyStateMapsToItsChip() {
        let until = Self.base.addingTimeInterval(3_600)
        let question = AwaitingInputReason(
            message: "", programStatusBlock: ProgramStatusBlock(kind: .question, taskID: nil))
        let cases: [(SessionStateValue, PhoneStatus)] = [
            (.working, Self.status(.working)),
            (.idle, Self.status(.idle)),
            (.done, Self.status(.idle)),
            (.awaitingInput(reason: AwaitingInputReason(message: "Allow Bash?")), Self.status(.waitingForYou, reason: "Allow Bash?")),
            (.awaitingInput(reason: question), Self.status(.waitingForYou, reason: "Waiting for an answer to a question")),
            (.awaitingInput(reason: nil), Self.status(.waitingForYou, reason: "Waiting for your input")),
            (.rateLimited(until: until), Self.status(.rateLimited, until: until)),
            (.rateLimited(until: nil), Self.status(.rateLimited)),
            (.parked(reason: "idle"), Self.status(.parked)),
            (.error, Self.status(.error, reason: "The agent reported an error.")),
            (.needsAuth, Self.status(.error, reason: "The agent needs you to sign in.")),
            (.gone, Self.status(.exited)),
            (.unknown(why: "No hook has reported yet."), Self.status(.unknown, reason: "No hook has reported yet.")),
        ]
        for (value, expected) in cases {
            #expect(PhoneSessionStatus.local(Self.state(value), openPrompt: nil) == expected, "\(value)")
        }

        // A reason is cut to 256 bytes, at a character boundary.
        let long = PhoneSessionStatus.local(Self.state(.unknown(why: Self.longText)), openPrompt: nil)
        let reason = long.reason ?? ""
        #expect(reason.utf8.count <= PhoneText.fieldLimit)
        #expect(reason.utf8.count > PhoneText.fieldLimit - 7)
        #expect(Self.longText.hasPrefix(reason))
    }

    @Test func anOpenPromptMakesTheSessionWaitForYou() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let t = Self.terminal(in: w.id, kind: .claude)
        let promptAt = Self.base.addingTimeInterval(60)
        let prompt = PendingPromptPayload(
            id: "toolu_acme", kind: .permission, toolUseID: "toolu_acme", toolName: "Bash",
            toolInputJSON: "{}", suggestionsJSON: nil, createdAt: promptAt)

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w], terminals: [t],
            states: [t.id: Self.state(.working)], openPrompts: [t.id: prompt]))

        let row = try Self.row(w.id.uuidString, in: s)
        try #require(row.sessions.count == 1)
        #expect(row.sessions[0].status == Self.status(.waitingForYou, at: promptAt, reason: "Waiting for a permission decision"))
        #expect(row.sessions[0].openPromptID == "toolu_acme")
        #expect(row.statusChangedAt == PhoneTime.ms(promptAt))

        // The agent's own words win over the generic line.
        let asked = Self.state(.awaitingInput(reason: AwaitingInputReason(message: "Allow Edit?")))
        #expect(PhoneSessionStatus.local(asked, openPrompt: prompt)
            == Self.status(.waitingForYou, at: promptAt, reason: "Allow Edit?"))
    }

    @Test func aSessionWithNoStateReadsUnknown() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let made = Self.base.addingTimeInterval(5)
        let missing = Self.terminal(in: w.id, kind: .claude, createdAt: made)
        let unavailable = Self.terminal(in: w.id, kind: .claude, createdAt: made.addingTimeInterval(1))
        // Read just now: its time is when it was read, which moves on every
        // read.
        let readNow = SessionState(
            value: .unknown(why: "No hook has reported yet."), source: .unavailable,
            observedAt: Self.base.addingTimeInterval(999))

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w],
            terminals: [missing, unavailable], states: [unavailable.id: readNow]))

        let sessions = try Self.row(w.id.uuidString, in: s).sessions
        try #require(sessions.count == 2)
        #expect(sessions[0].status == Self.status(.unknown, at: made, reason: PhoneSnapshotBuilder.noStateReason))
        #expect(sessions[1].status == Self.status(
            .unknown, at: made.addingTimeInterval(1), reason: "No hook has reported yet."))
    }

    @Test func remoteStatusFollowsTheProvider() throws {
        let stated = "2027-01-15T08:00:00Z"
        let statedAt = try #require(RemoteTimestamp.parse(stated))
        let seen = Self.base.addingTimeInterval(30)
        let prompt = RemotePendingPrompt(id: "prompt-1", kind: .permission)
        let cases: [(RemoteSessionInfo, PhoneStatusChip)] = [
            (Self.remote("gone", agentState: .working, gone: true), .exited),
            (Self.remote("exited", state: .exited, agentState: .working), .exited),
            (Self.remote("agent-exited", agentState: .exited), .exited),
            (Self.remote("waiting", agentState: .waitingInput), .waitingForYou),
            (Self.remote("prompted", agentState: .idle, pendingPrompt: prompt), .waitingForYou),
            (Self.remote("working", agentState: .working), .working),
            (Self.remote("idle", agentState: .idle), .idle),
            (Self.remote("unknown", agentState: .unknown), .unknown),
        ]
        for (session, chip) in cases {
            #expect(PhoneSessionStatus.remote(session).chip == chip, "\(session.payload.id)")
        }

        #expect(PhoneSessionStatus.remote(Self.remote("dated", agentStateAt: stated, lastSeen: seen))
            == Self.status(.working, at: statedAt))
        #expect(PhoneSessionStatus.remote(Self.remote("undated", lastSeen: seen)) == Self.status(.working, at: seen))
        #expect(PhoneSessionStatus.remote(Self.remote("garbled", agentStateAt: "soon", lastSeen: seen))
            == Self.status(.working, at: seen))

        // An open prompt's ID reaches the phone while the session lives.
        let s = PhoneSnapshotBuilder.build(Self.input(
            remoteSessions: [
                Self.remote("prompted", agentState: .waitingInput, pendingPrompt: prompt),
                Self.remote("ended", state: .exited, pendingPrompt: prompt),
            ],
            providers: [Self.provider("acme")]))
        #expect(try Self.row("remote:acme/prompted", in: s).sessions.first?.openPromptID == "prompt-1")
        #expect(try Self.row("remote:acme/ended", in: s).sessions.first?.openPromptID == nil)
    }

    @Test func remoteCapabilitiesFollowTheProvider() throws {
        let caps = PhoneSessionStatus.remoteCapabilities(declared: ["transcript.read", "answer"], promptAnswerEnabled: true)

        #expect(caps.transcript == Self.available)
        #expect(caps.answer == Self.available)
        #expect(caps.send == PhoneCapability(available: false, reason: "This provider does not support sending messages."))
        #expect(caps.model == PhoneCapability(available: false, reason: "This provider does not support changing the model."))
        let remoteOnly = PhoneCapability(available: false, reason: "Not available for remote sessions.")
        #expect(caps.switchProfile == remoteOnly)
        #expect(caps.fork == remoteOnly)

        // The builder reads each session's provider's declared set.
        let s = PhoneSnapshotBuilder.build(Self.input(
            remoteSessions: [Self.remote("rs-1")],
            providers: [Self.provider("acme", capabilities: [RemoteCapability.sendSubmit])]))
        let session = try #require(try Self.row("remote:acme/rs-1", in: s).sessions.first)
        #expect(session.capabilities.send == Self.available)
        #expect(session.capabilities.model == Self.available)
        #expect(session.capabilities.transcript
            == PhoneCapability(available: false, reason: "This provider does not support reading transcripts."))
        #expect(session.capabilities.answer
            == PhoneCapability(available: false, reason: "This provider does not support answering prompts."))
    }

    // MARK: - The setting for answering prompts

    /// `terminal`, a local session, and one remote session whose provider
    /// declares every capability, built with the setting for answering
    /// prompts `enabled`, nil for a setting that could not be read.
    private static func answerSettingSnapshot(
        enabled: Bool?, terminal: TBDShared.Terminal, worktree: Worktree, repo: Repo
    ) -> PhoneSnapshot {
        PhoneSnapshotBuilder.build(Self.input(
            repos: [repo], worktrees: [worktree], terminals: [terminal],
            remoteSessions: [Self.remote("rs-1", repo: repo.id)],
            providers: [Self.provider("acme", capabilities: [
                RemoteCapability.transcriptRead, RemoteCapability.sendSubmit, RemoteCapability.answer,
            ])],
            promptAnswerEnabled: enabled))
    }

    /// On, a local Claude session and a remote session whose provider
    /// declares `answer` both offer Answer. Off, neither does, each with the
    /// setting's reason, and every other capability is what it was with the
    /// setting on.
    @Test func theAnswerSettingTurnsOffOnlyAnswer() throws {
        let a = UUID()
        let repo = Repo(id: a, path: "/tmp/acme", displayName: "acme")
        let w = Self.worktree("fix-login", repo: a)
        let claude = Self.terminal(in: w.id, kind: .claude)
        let remoteRowID = "remote:acme/rs-1"

        let on = Self.answerSettingSnapshot(enabled: true, terminal: claude, worktree: w, repo: repo)
        let off = Self.answerSettingSnapshot(enabled: false, terminal: claude, worktree: w, repo: repo)

        let localOn = try #require(try Self.row(w.id.uuidString, in: on).sessions.first)
        let remoteOn = try #require(try Self.row(remoteRowID, in: on).sessions.first)
        #expect(localOn.capabilities.answer == Self.available)
        #expect(remoteOn.capabilities.answer == Self.available)

        let turnedOff = PhoneCapability(
            available: false, reason: "Answering prompts is turned off in TBD's settings on the laptop.")
        #expect(PhoneSessionStatus.answerTurnedOffReason == turnedOff.reason)
        let localOff = try #require(try Self.row(w.id.uuidString, in: off).sessions.first)
        let remoteOff = try #require(try Self.row(remoteRowID, in: off).sessions.first)
        #expect(localOff.capabilities == PhoneCapabilities(
            transcript: localOn.capabilities.transcript, send: localOn.capabilities.send, answer: turnedOff,
            switchProfile: localOn.capabilities.switchProfile, fork: localOn.capabilities.fork,
            model: localOn.capabilities.model))
        #expect(remoteOff.capabilities == PhoneCapabilities(
            transcript: remoteOn.capabilities.transcript, send: remoteOn.capabilities.send, answer: turnedOff,
            switchProfile: remoteOn.capabilities.switchProfile, fork: remoteOn.capabilities.fork,
            model: remoteOn.capabilities.model))
        // The capabilities left alone are the ones the session has: Send and
        // Model on both, Switch and Fork on the local session, and no switch
        // or fork for the remote one.
        #expect(localOff.capabilities.send == Self.available)
        #expect(localOff.capabilities.model == Self.available)
        #expect(localOff.capabilities.switchProfile == Self.available)
        #expect(localOff.capabilities.fork == Self.available)
        #expect(remoteOff.capabilities.send == Self.available)
        #expect(remoteOff.capabilities.transcript == Self.available)
        #expect(remoteOff.capabilities.fork
            == PhoneCapability(available: false, reason: PhoneSessionStatus.remoteOnlyReason))
    }

    /// A setting that could not be read turns off only `answer`, on a local
    /// Claude session and on a remote session whose provider declares it,
    /// with `answerSettingUnreadReason` rather than the reason for a setting
    /// turned off. A session that cannot answer anyway keeps its own reason.
    @Test func anUnreadAnswerSettingTurnsOffOnlyAnswerWithItsOwnReason() throws {
        let a = UUID()
        let repo = Repo(id: a, path: "/tmp/acme", displayName: "acme")
        let w = Self.worktree("fix-login", repo: a)
        let claude = Self.terminal(in: w.id, kind: .claude)

        let on = Self.answerSettingSnapshot(enabled: true, terminal: claude, worktree: w, repo: repo)
        let unread = Self.answerSettingSnapshot(enabled: nil, terminal: claude, worktree: w, repo: repo)

        let unreadAnswer = PhoneCapability(available: false, reason: PhoneSessionStatus.answerSettingUnreadReason)
        for rowID in [w.id.uuidString, "remote:acme/rs-1"] {
            let shownOn = try #require(try Self.row(rowID, in: on).sessions.first)
            let shownUnread = try #require(try Self.row(rowID, in: unread).sessions.first)
            #expect(shownOn.capabilities.answer == Self.available, "row \(rowID)")
            #expect(shownUnread.capabilities == PhoneCapabilities(
                transcript: shownOn.capabilities.transcript, send: shownOn.capabilities.send, answer: unreadAnswer,
                switchProfile: shownOn.capabilities.switchProfile, fork: shownOn.capabilities.fork,
                model: shownOn.capabilities.model), "row \(rowID)")
        }
        let codex = PhoneSessionStatus.localCapabilities(
            terminal: Self.terminal(in: w.id, kind: .codex, claudeSessionID: nil), isRemoteWorktree: false,
            promptAnswerEnabled: nil)
        #expect(codex.answer == PhoneCapability(available: false, reason: "Codex sessions show status only."))
        let undeclared = PhoneSessionStatus.remoteCapabilities(declared: [], promptAnswerEnabled: nil)
        #expect(undeclared.answer
            == PhoneCapability(available: false, reason: "This provider does not support answering prompts."))
    }

    /// A session that cannot answer whatever the setting says keeps its own
    /// reason while the setting is off, since that reason stays true once
    /// the setting is on again: a Codex session, a tab in a remote lane, a
    /// provider that does not declare `answer`.
    @Test func aSessionThatCannotAnswerKeepsItsOwnReasonWhileTheSettingIsOff() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let codex = Self.terminal(in: w.id, kind: .codex, claudeSessionID: nil)

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w], terminals: [codex],
            remoteSessions: [Self.remote("rs-1")],
            providers: [Self.provider("acme", capabilities: [RemoteCapability.sendSubmit])],
            promptAnswerEnabled: false))

        let codexSession = try #require(try Self.row(w.id.uuidString, in: s).sessions.first)
        #expect(codexSession.capabilities.answer
            == PhoneCapability(available: false, reason: "Codex sessions show status only."))
        let remote = try #require(try Self.row("remote:acme/rs-1", in: s).sessions.first)
        #expect(remote.capabilities.answer
            == PhoneCapability(available: false, reason: "This provider does not support answering prompts."))
        // The sessions list never builds a remote lane's tab, as the lane's
        // remote session stands for it; an action on one reads it so.
        let laneTab = PhoneSessionStatus.localCapabilities(
            terminal: Self.terminal(in: w.id, kind: .claude), isRemoteWorktree: true, promptAnswerEnabled: false)
        #expect(laneTab.answer == PhoneCapability(
            available: false, reason: "This tab belongs to a remote lane. Use its remote session."))
        let remoteCaps = PhoneSessionStatus.remoteCapabilities(declared: [], promptAnswerEnabled: false)
        #expect(remoteCaps.answer == remote.capabilities.answer)
    }

    @Test func aUserTabLabelWinsOverTheAutomaticName() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let work = ModelProfile(name: "Work", kind: .oauth)
        let labeled = Self.terminal(in: w.id, kind: .claude, profileID: work.id)
        let unlabeled = Self.terminal(in: w.id, kind: .claude, createdAt: Self.base.addingTimeInterval(1), profileID: work.id)

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w],
            terminals: [labeled, unlabeled], tabOrder: [w.id: [labeled.id, unlabeled.id]],
            tabLabels: [labeled.id: "review", unlabeled.id: ""], profiles: [work]))

        let sessions = try Self.row(w.id.uuidString, in: s).sessions
        let tabNames = sessions.map(\.tabName)
        // An empty label is no label: the second tab of the Work profile.
        #expect(tabNames == ["review", "Work 2"])
        let profileNames = sessions.map(\.profileName)
        #expect(profileNames == ["Work", "Work"])
        let profileIDs = sessions.map(\.profileID)
        #expect(profileIDs == [work.id, work.id])
        let models = sessions.map(\.model)
        #expect(models == [nil, nil])
    }

    /// Tabs in the stored order come first, in that order; the rest follow by
    /// when they were made.
    @Test func sessionsFollowTheTabOrder() throws {
        let a = UUID()
        let w = Self.worktree("fix-login", repo: a)
        let first = Self.terminal(in: w.id, kind: .claude)
        let second = Self.terminal(in: w.id, kind: .claude, createdAt: Self.base.addingTimeInterval(1))
        let third = Self.terminal(in: w.id, kind: .claude, createdAt: Self.base.addingTimeInterval(2))

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [w],
            terminals: [third, first, second], tabOrder: [w.id: [UUID(), second.id, first.id]]))

        let refs = try Self.row(w.id.uuidString, in: s).sessions.map(\.ref)
        #expect(refs == [.local(terminalID: second.id), .local(terminalID: first.id), .local(terminalID: third.id)])
    }

    // MARK: - Times

    @Test func aRowsStatusTimeIsItsNewestSession() throws {
        let a = UUID()
        let busy = Self.worktree("busy", repo: a)
        let quiet = Self.worktree("quiet", repo: a, sortOrder: 1, createdAt: Self.base.addingTimeInterval(-100))
        let claude = Self.terminal(in: busy.id, kind: .claude)
        let codex = Self.terminal(in: busy.id, kind: .codex, claudeSessionID: nil)
        let shell = Self.terminal(in: quiet.id, kind: .shell, claudeSessionID: nil)
        let stated = "2027-01-15T08:00:00Z"
        let statedAt = try #require(RemoteTimestamp.parse(stated))
        let seen = Self.base.addingTimeInterval(30)

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: a, path: "/tmp/acme", displayName: "acme")], worktrees: [busy, quiet],
            terminals: [claude, codex, shell],
            states: [
                claude.id: Self.state(.idle, at: Self.base.addingTimeInterval(10)),
                codex.id: Self.state(.working, at: Self.base.addingTimeInterval(20)),
            ],
            remoteSessions: [Self.remote("dated", agentStateAt: stated), Self.remote("undated", lastSeen: seen)],
            providers: [Self.provider("acme")]))

        #expect(try Self.row(busy.id.uuidString, in: s).statusChangedAt == PhoneTime.ms(Self.base.addingTimeInterval(20)))
        // No sessions: when the worktree was made.
        #expect(try Self.row(quiet.id.uuidString, in: s).statusChangedAt == PhoneTime.ms(Self.base.addingTimeInterval(-100)))
        #expect(try Self.row("remote:acme/dated", in: s).statusChangedAt == PhoneTime.ms(statedAt))
        #expect(try Self.row("remote:acme/undated", in: s).statusChangedAt == PhoneTime.ms(seen))
    }

    @Test func timesAreWholeUnixMilliseconds() {
        #expect(PhoneTime.ms(Date(timeIntervalSince1970: 1.9999)) == 1_999)
        #expect(PhoneTime.ms(Self.base) == 1_800_000_000_000)
        #expect(PhoneTime.ms(Date(timeIntervalSince1970: -0.0005)) == -1)
    }

    @Test func textIsCutAtACharacterBoundary() {
        #expect(PhoneText.capped("short") == "short")
        let cut = PhoneText.capped(String(repeating: "名", count: 100))
        #expect(cut == String(repeating: "名", count: 85))
        let mixed = PhoneText.capped(Self.longText)
        #expect(mixed.utf8.count <= PhoneText.fieldLimit)
        #expect(Self.longText.hasPrefix(mixed))
    }

    // MARK: - Size

    /// 1,200 rows, every text field at its limit with multi-byte and escaped
    /// characters: the snapshot keeps the first 1,000, counts the rest, and
    /// every row and the layout fit their share of a frame.
    @Test func aHugeFleetSplitsAcrossFrames() throws {
        let r = UUID()
        let profile = ModelProfile(name: Self.longText, kind: .oauth)
        var worktrees: [Worktree] = []
        var terminals: [TBDShared.Terminal] = []
        var labels: [UUID: String] = [:]
        var states: [UUID: SessionState] = [:]
        for index in 0..<1_200 {
            let w = Self.worktree(Self.longText, repo: r, sortOrder: index)
            worktrees.append(w)
            let t = Self.terminal(in: w.id, kind: .claude, profileID: profile.id)
            terminals.append(t)
            labels[t.id] = Self.longText
            states[t.id] = Self.state(.unknown(why: Self.longText))
        }

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: r, path: "/tmp/acme", displayName: Self.longText)], worktrees: worktrees,
            terminals: terminals, tabLabels: labels, profiles: [profile], states: states))

        #expect(s.rows.count == 1_000)
        #expect(s.omittedRows == 200)
        let keptIDs = s.rows.map(\.id)
        let firstIDs = worktrees.prefix(1_000).map(\.id.uuidString)
        #expect(keptIDs == firstIDs)
        try #require(s.layout.count == 1)
        #expect(s.layout[0].rows.count == 1_000)
        #expect(s.layout[0].name.utf8.count <= PhoneText.fieldLimit)

        let encoder = PhoneAppCoding.makeEncoder()
        #expect(try encoder.encode(s.layout).count <= PhoneSnapshotBuilder.layoutByteLimit)
        var largestRow = 0
        for row in s.rows {
            let size = try encoder.encode(row).count
            largestRow = max(largestRow, size)
        }
        #expect(largestRow <= PhoneSnapshotBuilder.rowByteLimit)
        let firstRow = try #require(s.rows.first)
        let session = try #require(firstRow.sessions.first)
        let profileName = try #require(session.profileName)
        let reason = try #require(session.status.reason)
        #expect(firstRow.name.utf8.count <= PhoneText.fieldLimit)
        #expect(session.tabName.utf8.count <= PhoneText.fieldLimit)
        #expect(profileName.utf8.count <= PhoneText.fieldLimit)
        #expect(reason.utf8.count <= PhoneText.fieldLimit)
    }

    /// A worktree with so many agent tabs that its row alone would not fit a
    /// frame is left out and counted; the rows around it stay.
    @Test func anOverSizeRowIsLeftOutAndCounted() throws {
        let r = UUID()
        let crowded = Self.worktree("crowded", repo: r)
        let small = Self.worktree("small", repo: r, sortOrder: 1)
        var terminals = [Self.terminal(in: small.id, kind: .claude)]
        var labels: [UUID: String] = [:]
        for index in 0..<60 {
            let t = Self.terminal(in: crowded.id, kind: .claude, createdAt: Self.base.addingTimeInterval(Double(index)))
            terminals.append(t)
            labels[t.id] = Self.longText
        }
        var states: [UUID: SessionState] = [:]
        for t in terminals {
            states[t.id] = Self.state(.unknown(why: Self.longText))
        }

        let s = PhoneSnapshotBuilder.build(Self.input(
            repos: [Repo(id: r, path: "/tmp/acme", displayName: "acme")], worktrees: [crowded, small],
            terminals: terminals, tabLabels: labels, states: states))

        let rowIDs = s.rows.map(\.id)
        #expect(rowIDs == [small.id.uuidString])
        #expect(s.omittedRows == 1)
        try #require(s.layout.count == 1)
        #expect(s.layout[0].rows == [PhoneRowPlacement(id: small.id.uuidString, depth: 0)])
    }
}
