import AppKit
import SwiftUI
import TBDShared
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            RepositoriesSettingsTab()
                .tabItem {
                    Label("Repositories", systemImage: "folder")
                }

            TerminalSettingsView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }

            ModelProfilesSettingsView()
                .tabItem { Label("Model Profiles", systemImage: "key.fill") }
        }
        .frame(width: 500, height: 520)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("enableNotifications") private var enableNotifications: Bool = true
    @AppStorage("skipPermissions") private var skipPermissions: Bool = true
    @AppStorage(AppState.autoSuspendClaudeKey) private var autoSuspend: Bool = false
    @AppStorage(AppState.enableTranscriptKey) private var enableTranscript: Bool = AppState.enableTranscriptDefault
    @AppStorage(AppState.nightwatchExperimentalKey) private var nightwatchExperimental: Bool = false
    @AppStorage(AppState.showScratchSectionKey) private var showScratchSection: Bool = true
    @AppStorage(AppState.showClaudeTabUsageTooltipKey) private var showClaudeTabUsageTooltip: Bool = true
    @AppStorage(AppState.usageResetTimeStyleKey)
    private var usageResetTimeStyle: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset
    @AppStorage("enableNotificationSounds") private var enableSounds: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""
    @AppStorage("errorNotificationSoundName") private var errorSoundName: String = "Sosumi"
    @AppStorage("errorNotificationSoundCustomPath") private var errorCustomPath: String = ""

    /// In-progress amount text for the hibernate-idle-threshold field. Kept
    /// separate from the committed `hibernateIdleDuration` so a keystroke
    /// never fires an RPC — only `.onSubmit` / focus-loss / a unit-picker
    /// change commits (see `hibernateIdleThresholdRow`).
    @State private var hibernateIdleAmountText: String = ""
    @State private var hibernateIdleDuration = HibernateIdleDuration(totalMinutes: Config.defaultHibernateIdleMinutes)
    @FocusState private var hibernateIdleFieldFocused: Bool
    /// Bumped on every `applyHibernateIdleDuration` call so a commit's
    /// post-await re-sync can detect a newer commit landed while it was in
    /// flight and skip applying its now-stale response.
    @State private var hibernateIdleCommitGeneration = 0

    private var systemSounds: [String] { NotificationSoundPlayer.systemSoundNames() }
    private let soundPlayer = NotificationSoundPlayer()

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable macOS notifications", isOn: $enableNotifications)
                    .help("Show system notifications when background tasks complete")
                Toggle("Enable notification sounds", isOn: $enableSounds)
                    .help("Play a sound when background tasks complete")

                if enableSounds {
                    HStack {
                        Picker("Sound", selection: Binding(
                            get: { customPath.isEmpty ? soundName : "__custom__" },
                            set: { newValue in
                                if newValue == "__custom__" {
                                    pickCustomSound()
                                } else {
                                    soundName = newValue
                                    customPath = ""
                                }
                            }
                        )) {
                            ForEach(systemSounds, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("Custom…").tag("__custom__")
                            if !customPath.isEmpty {
                                Text(URL(fileURLWithPath: customPath).lastPathComponent)
                                    .tag("__custom__")
                            }
                        }
                        .frame(maxWidth: 200)

                        Button("Test") {
                            soundPlayer.playTest()
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Picker("Error sound", selection: Binding(
                            get: { errorCustomPath.isEmpty ? errorSoundName : "__custom__" },
                            set: { newValue in
                                if newValue == "__custom__" {
                                    pickErrorCustomSound()
                                } else {
                                    errorSoundName = newValue
                                    errorCustomPath = ""
                                }
                            }
                        )) {
                            ForEach(systemSounds, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("Custom…").tag("__custom__")
                            if !errorCustomPath.isEmpty {
                                Text(URL(fileURLWithPath: errorCustomPath).lastPathComponent)
                                    .tag("__custom__")
                            }
                        }
                        .frame(maxWidth: 200)

                        Button("Test") {
                            soundPlayer.playTestError()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Agents") {
                Picker("Default primary agent", selection: primaryAgentPreferenceBinding) {
                    Text("Claude Code").tag(PrimaryAgentPreference.claude)
                    Text("Codex").tag(PrimaryAgentPreference.codex)
                }
                .pickerStyle(.segmented)
                .help("Used when TBD needs to choose the primary agent for a worktree and there is no prior agent state to restore.")
            }

            Section("Worktrees") {
                Toggle("Auto-archive worktrees when their PR merges", isOn: Binding(
                    get: { appState.autoArchiveOnMergeDefault },
                    set: { newValue in Task { await appState.setAutoArchiveOnMergeDefault(newValue) } }
                ))
                .help("Default for new worktrees. Each worktree can override this from its toolbar toggle.")

                Toggle("Auto-hibernate sessions when their PR merges", isOn: Binding(
                    get: { appState.autoHibernateOnMergeDefault },
                    set: { newValue in Task { await appState.setAutoHibernateOnMergeDefault(newValue) } }
                ))
                .help("Default for new worktrees. Parks each idle Claude session (freeing its memory, keeping the frozen screen and resumability) instead of archiving the worktree. Each worktree can override this from its PR toolbar menu.")

                Toggle("Show Scratch section", isOn: $showScratchSection)
                    .help("Hide the repo-less Scratch section. Existing scratch spaces and their terminals keep running.")

                Toggle("Automatically clean up orphaned agent worktrees", isOn: Binding(
                    get: { appState.gcEnabled },
                    set: { newValue in Task { await appState.setGCEnabled(newValue) } }
                ))
                .help("Reaps Claude agent worktrees whose run has ended, snapshot-first. Restore from History → Reclaimed.")
            }

            Section("Claude") {
                Toggle("Launch claude with --dangerously-skip-permissions", isOn: $skipPermissions)
                    .help("Skip the interactive permission prompt when launching claude in new worktrees")
                autoTrustWorktreesToggle
                Toggle("Auto-resume Claude sessions when the usage limit resets",
                       isOn: Binding(
                    get: { appState.autoResumeOnLimitReset },
                    set: { newValue in Task { await appState.setAutoResumeOnLimitReset(newValue) } }
                ))
                .help("When a session hits the usage limit, TBD schedules a resume for the reset time and types \"continue\" into the pane. Off by default; detection and notifications run regardless.")
                Toggle("Auto-continue after transient API errors",
                       isOn: Binding(
                    get: { appState.autoResumeOnApiError },
                    set: { newValue in Task { await appState.setAutoResumeOnApiError(newValue) } }
                ))
                .help("When a turn dies on a transient API error (connection drop, server error, overload), TBD types \"continue\" after a backoff (60s, 2m, 5m, 10m) and gives up after 4 straight failures. Off by default. Auth and billing errors are never retried.")
                Toggle("Live transcript pane", isOn: $enableTranscript)
                    .help("Show a chat-style live transcript pane for Claude sessions, following the session's conversation as it streams. On by default; turn it off to keep the pane out of new tabs.")
                Toggle("Show usage tooltip on Claude tabs", isOn: $showClaudeTabUsageTooltip)
                    .help("Show a hover card on Claude tabs with the session's account, profile, 5h/weekly usage, and spawn time.")
                Picker("Usage reset times", selection: $usageResetTimeStyle) {
                    Text("Time of reset").tag(ProfileUsagePresentation.ResetTimeStyle.timeOfReset)
                    Text("Time until reset").tag(ProfileUsagePresentation.ResetTimeStyle.timeUntilReset)
                }
                .help("How usage-window resets are shown: the wall-clock time they reset (\"at 7:59pm\", \"at Fri 7pm\") or the time remaining (\"in 2h 10m\", \"in 4d 2h\").")
            }

            Section("Session Hibernation") {
                Toggle("Auto-hibernate idle Claude sessions", isOn: Binding(
                    get: { appState.autoHibernateEnabled },
                    set: { newValue in
                        Task { await appState.setAutoHibernate(
                            enabled: newValue, idleMinutes: appState.hibernateIdleMinutes) }
                    }
                ))
                .help("Kill the claude process of a session idle at rest, keeping its tab alive. It respawns automatically on focus. The prompt cache has already expired by then, so resume is cheap. Never touches a running turn, a permission prompt, or a keep-warm session.")

                if appState.autoHibernateEnabled {
                    hibernateIdleThresholdRow
                }
            }

            Section("Remote Sessions") {
                remoteBackendsToggle
                remoteProvidersRegistryRow
            }

            MarkdownSettingsSection()

            Section {
                EnvOverridesEditor(
                    initial: appState.globalEnvOverrides,
                    caption: "Applied to every spawned Claude/Codex session. Repo and model-profile overrides take precedence."
                ) { await appState.setGlobalEnvOverrides($0) }
            }

            Section("Fleet Automation") {
                Toggle("Nightwatch / Daywatch", isOn: $nightwatchExperimental)
                    .help("""
                    An autonomous fleet babysitter. It sweeps your \
                    worktrees, keeps stuck agents unblocked, and gates open PRs, using \
                    cheap local scripts and only paging a model for genuine judgment \
                    calls. Daywatch (◐) is a lighter pass for when you're at the \
                    keyboard; Nightwatch (🌙) is the fuller autonomous mode for when \
                    you're away. It acts on your live fleet — nudging stuck \
                    sessions and dispatching work — and its behavior and safety \
                    rules are still changing. Turning this \
                    on reveals the mode controls (sidebar footer and menu bar); \
                    off hides both. You still merge PRs and make prod/access \
                    calls yourself.
                    """)
            }

            Section("Experimental") {
                Toggle("Suspend idle Claude before sleep", isOn: $autoSuspend)
                    .help("Experimental: best-effort exit idle Claude instances when the machine is about to sleep, so a tmux server that dies during a long sleep has less to recover. Off by default — may interrupt long-running work.")
                controlModeToggle
                hibernateInputVetoToggle
                autoCloseSetupToggle
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Tmux control-mode opt-in. Reads the daemon's EFFECTIVE gate from
    /// `daemon.capabilities` (env || persisted flag) and writes via
    /// `config.setControlMode`. Disabled with an explanation when the
    /// daemon's tmux is older than 3.2 (or wasn't detected).
    @ViewBuilder
    private var controlModeToggle: some View {
        let capabilities = appState.daemonCapabilities
        let supported = capabilities?.controlModeSupported ?? false
        Toggle("tmux control mode for terminal panes", isOn: Binding(
            get: { capabilities?.controlModeEnabled ?? false },
            set: { newValue in Task { await appState.setControlModeEnabled(newValue) } }
        ))
        .help("Applies to newly created terminal panes.")
        .disabled(!supported)
        if !supported {
            Text(
                capabilities?.tmuxVersion.map {
                    "Requires tmux 3.2 or later (detected \($0))."
                } ?? "Requires tmux 3.2 or later (tmux not detected)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Pending-input veto for auto-hibernate. Reads the persisted flag from
    /// `daemon.capabilities` and writes via `config.setHibernateInputVeto`.
    /// Off by default (soaking).
    @ViewBuilder
    private var hibernateInputVetoToggle: some View {
        let capabilities = appState.daemonCapabilities
        Toggle("Pending-input veto for auto-hibernate", isOn: Binding(
            get: { capabilities?.hibernateInputVetoEnabled ?? false },
            set: { newValue in Task { await appState.setHibernateInputVetoEnabled(newValue) } }
        ))
        .help("Guard that prevents hibernation of sessions with typed-but-unsent input (machine-interface input detector). Off by default (soaking). Independent of the auto-hibernate idle sweep, which is also off by default.")
    }

    /// Auto-close the setup-hook tab after a clean run. Reads the persisted
    /// flag from `daemon.capabilities` and writes via
    /// `config.setAutoCloseSetup`. Off by default (soaking).
    @ViewBuilder
    private var autoCloseSetupToggle: some View {
        let capabilities = appState.daemonCapabilities
        Toggle("Auto-close the setup tab on success", isOn: Binding(
            get: { capabilities?.autoCloseSetupEnabled ?? false },
            set: { newValue in Task { await appState.setAutoCloseSetupEnabled(newValue) } }
        ))
        .help("When a repo's setup hook exits cleanly, close its tab automatically. A failed hook keeps the tab open with a shell for debugging. Off by default (soaking). Applies to newly created worktrees.")
    }

    /// Pre-accept Claude's folder-trust dialog for the worktrees of registered
    /// repos. Reads the persisted flag from `daemon.capabilities` and writes via
    /// `config.setAutoTrustWorktrees`. ON by default — the trust question has
    /// a known answer for a worktree TBD made from a repo you registered (and
    /// for that repo's own checkout, which you registered deliberately), and
    /// the dialog blocks before any hook fires, so a stalled session is
    /// invisible to TBD. Worktrees checked out from a PR head are excluded:
    /// their contents may be fork-authored, which is what the prompt gates.
    @ViewBuilder
    private var autoTrustWorktreesToggle: some View {
        let capabilities = appState.daemonCapabilities
        Toggle("Trust repos you add and the worktrees TBD makes in them", isOn: Binding(
            get: { capabilities?.autoTrustWorktrees ?? true },
            set: { newValue in Task { await appState.setAutoTrustWorktrees(newValue) } }
        ))
        .help("Answer Claude's \u{201C}do you trust the files in this folder?\u{201D} prompt ahead of time for worktrees TBD created and for the checkout of each repo you added. You registered the repo and TBD made the worktree, so the answer is already known \u{2014} and the prompt blocks before any Claude hook fires, so a session waiting on it looks idle to TBD instead of stuck. Worktrees checked out from a pull request head are never pre-trusted, on or off: their files may come from someone else's fork, which is exactly what the prompt is for. On by default. Turning it off stops any further pre-trusting, including for worktrees that already exist; nothing already trusted is undone, and TBD's own scratch spaces are always trusted.")
    }

    /// Amount + unit control for `Config.hibernateIdleMinutes`, replacing a
    /// `Stepper` that was capped at 240 minutes / 5-minute steps (48 clicks
    /// for a day, impossible past 4 hours). Never fires an RPC per keystroke:
    /// the amount commits on `.onSubmit` or focus loss, the unit commits
    /// immediately on picker change. `HibernateIdleDuration` (its own file)
    /// holds the pure amount/unit math; this view owns only the SwiftUI
    /// commit timing.
    @ViewBuilder
    private var hibernateIdleThresholdRow: some View {
        HStack {
            Text("Idle before hibernating:")
            TextField("", text: $hibernateIdleAmountText)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .focused($hibernateIdleFieldFocused)
                .onSubmit { commitHibernateIdleAmount() }
            Picker("", selection: hibernateIdleUnitBinding) {
                ForEach(HibernateIdleDuration.Unit.allCases) { unit in
                    Text(unit.displayName(count: hibernateIdleDisplayAmount).capitalized)
                        .tag(unit)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
        .help("How long a Claude session must sit idle before it's hibernated. Accepts 1 minute to 99 days. Below about 5 minutes, the prompt cache may not have expired yet, so resume can cost more.")
        .onAppear { syncHibernateIdleFromAppState() }
        .onChange(of: appState.hibernateIdleMinutes) { _, _ in syncHibernateIdleFromAppState() }
        .onChange(of: hibernateIdleFieldFocused) { _, focused in
            if !focused { commitHibernateIdleAmount() }
        }
    }

    /// The amount used to pluralize the unit-picker labels: the in-progress
    /// typed value when it parses, otherwise the last committed amount — so
    /// "1" -> "Minute" updates live as the user types, without waiting for
    /// commit.
    private var hibernateIdleDisplayAmount: Int {
        Int(hibernateIdleAmountText.trimmingCharacters(in: .whitespaces)) ?? hibernateIdleDuration.amount
    }

    /// Unit-picker binding. Changing the unit commits immediately (unlike the
    /// amount field), reinterpreting the currently-typed amount in the new
    /// unit — 2 + hours -> Days means 2 days, not an equivalent-total
    /// conversion. Uses the same resolve rule as `commitHibernateIdleAmount`
    /// (see `HibernateIdleDuration.resolveAmount(fromText:targetUnit:)`).
    private var hibernateIdleUnitBinding: Binding<HibernateIdleDuration.Unit> {
        Binding(
            get: { hibernateIdleDuration.unit },
            set: { newUnit in
                let amount = hibernateIdleDuration.resolveAmount(fromText: hibernateIdleAmountText, targetUnit: newUnit)
                applyHibernateIdleDuration(HibernateIdleDuration(amount: amount, unit: newUnit))
            }
        )
    }

    /// Re-sync the field from the daemon's current value. Called on appear,
    /// whenever `appState.hibernateIdleMinutes` changes externally (a config
    /// delta from another window/session), and — with `force: true` — after
    /// this view's own commit RPC settles (`applyHibernateIdleDuration` —
    /// success or failure).
    ///
    /// The focus guard exists only to stop an *external* delta from stomping
    /// an in-progress edit; it is skipped when `force` is true. That
    /// distinction matters because `.onSubmit` does not resign first
    /// responder on macOS: pressing Return leaves the field focused while
    /// its own commit RPC is in flight, so a non-forced sync would silently
    /// swallow the revert-on-failure this view relies on, leaving an
    /// unpersisted value on screen until the user happens to click away.
    /// This view reconciling its own settled write is not an external
    /// delta, so it always applies regardless of focus.
    ///
    /// Returns early — force or not — when the local duration's total
    /// already agrees with `appState.hibernateIdleMinutes`: there is nothing
    /// to sync, and re-deriving amount+unit from the total would undo the
    /// user's deliberately chosen unit even though nothing actually changed
    /// — typing "120" with unit Minutes and clicking away would otherwise
    /// silently renormalize to "2 Hours" the moment the commit round-trips
    /// and this fires from `.onChange(of: appState.hibernateIdleMinutes)`.
    /// Only a genuine external delta — a different total — re-derives the
    /// unit.
    private func syncHibernateIdleFromAppState(force: Bool = false) {
        guard force || !hibernateIdleFieldFocused else { return }
        guard hibernateIdleDuration.totalMinutes != appState.hibernateIdleMinutes else { return }
        hibernateIdleDuration = HibernateIdleDuration(totalMinutes: appState.hibernateIdleMinutes)
        hibernateIdleAmountText = String(hibernateIdleDuration.amount)
    }

    /// Commit the typed amount for the current unit. See
    /// `HibernateIdleDuration.resolveAmount(fromText:targetUnit:)` for the
    /// revert-vs-clamp rule, shared with `hibernateIdleUnitBinding`.
    private func commitHibernateIdleAmount() {
        let amount = hibernateIdleDuration.resolveAmount(fromText: hibernateIdleAmountText, targetUnit: hibernateIdleDuration.unit)
        applyHibernateIdleDuration(HibernateIdleDuration(amount: amount, unit: hibernateIdleDuration.unit))
    }

    /// Commit a validated duration: update local state immediately (so the
    /// field/picker reflect it without waiting on the RPC round-trip),
    /// persist via the same `setAutoHibernate` path the master-switch toggle
    /// uses, and then force a re-sync from `appState` once the RPC settles —
    /// `force: true` because this is the view reconciling its own settled
    /// write, not an external delta, so the focus guard in
    /// `syncHibernateIdleFromAppState` must not apply here (see that
    /// method's doc comment). On success the force-sync is still a no-op
    /// (the persisted total now matches, so the totals-agree early return
    /// fires and the chosen unit survives); on failure
    /// `appState.hibernateIdleMinutes` never moved, so the re-sync reverts
    /// the field to what is actually persisted instead of stranding an
    /// unsaved value that silently looks committed.
    ///
    /// The amount commit and the unit-picker commit can each land in this
    /// method while the other's RPC is still in flight. `hibernateIdleCommitGeneration`
    /// tags each call so a response that settles after a newer commit was
    /// already issued skips its re-sync instead of clobbering the newer
    /// commit's local state with a stale round-trip.
    private func applyHibernateIdleDuration(_ duration: HibernateIdleDuration) {
        hibernateIdleDuration = duration
        hibernateIdleAmountText = String(duration.amount)
        hibernateIdleCommitGeneration += 1
        let generation = hibernateIdleCommitGeneration
        Task {
            await appState.setAutoHibernate(enabled: appState.autoHibernateEnabled, idleMinutes: duration.totalMinutes)
            guard generation == hibernateIdleCommitGeneration else { return }
            syncHibernateIdleFromAppState(force: true)
        }
    }

    /// Remote agent sessions master switch. Reads the persisted flag from
    /// `daemon.capabilities` and writes via `config.setRemoteBackends`
    /// (`AppState.setRemoteBackendsEnabled`). The caption below the toggle
    /// distinguishes "on" from "on and actually polling" — the daemon only
    /// constructs its provider manager at boot, so a fresh toggle needs a
    /// restart before anything happens (see `AppState.remoteBackendsStatusCaption`).
    @ViewBuilder
    private var remoteBackendsToggle: some View {
        let capabilities = appState.daemonCapabilities
        let enabled = capabilities?.remoteBackendsEnabled ?? false
        let live = capabilities?.remoteBackendsLive ?? false
        Toggle("Enable remote agent sessions", isOn: Binding(
            get: { enabled },
            set: { newValue in Task { await appState.setRemoteBackendsEnabled(newValue) } }
        ))
        .help("Providers are registered in the file below. The daemon only builds its provider manager at boot, so turning this on requires a daemon restart before polling starts.")
        Text(AppState.remoteBackendsStatusCaption(enabled: enabled, live: live))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The registry file row — tilde-abbreviated path + copy-path button,
    /// copying the exact row implementation style `RepoHooksSettingsView`
    /// uses for every other file-backed settings surface (repo convention:
    /// user-authored blobs get a path+copy editor, not a DB column). The
    /// file may not exist yet; when providers ARE loaded, list them with
    /// their health so the user can see whether their JSON took effect
    /// without leaving Settings.
    @ViewBuilder
    private var remoteProvidersRegistryRow: some View {
        let path = TBDConstants.agentProvidersPath
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy full path")

                Spacer()
            }

            if appState.remoteProviders.isEmpty {
                Text("No providers loaded yet. Add entries to the file above, then restart the daemon.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(appState.remoteProviders) { provider in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.healthColor(provider.health))
                            .frame(width: 6, height: 6)
                        Text(provider.config.name)
                            .font(.caption)
                        Text(Self.healthLabel(provider.health))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Short human label for a provider's health, as reported by
    /// `remote.providers`. Presentation-only — not behavior-gating, so no
    /// dedicated test per the repo's branching-conditional rule.
    private static func healthLabel(_ health: ProviderHealth) -> String {
        switch health {
        case .ok: return "OK"
        case .stale: return "Stale"
        case .needsAuth: return "Needs auth"
        case .error: return "Error"
        }
    }

    private static func healthColor(_ health: ProviderHealth) -> Color {
        switch health {
        case .ok: return .green
        case .stale: return .yellow
        case .needsAuth: return .orange
        case .error: return .red
        }
    }

    private var primaryAgentPreferenceBinding: Binding<PrimaryAgentPreference> {
        Binding(
            get: { appState.primaryAgentPreference },
            set: { newValue in
                Task { await appState.setPrimaryAgentPreference(newValue) }
            }
        )
    }

    private func pickCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["aiff", "mp3", "wav", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a notification sound"

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }

    private func pickErrorCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["aiff", "mp3", "wav", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an error notification sound"

        if panel.runModal() == .OK, let url = panel.url {
            errorCustomPath = url.path
        }
    }
}

// MARK: - Repositories Tab

struct RepositoriesSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.repos.isEmpty {
                VStack {
                    Spacer()
                    Text("No repositories added yet.")
                        .foregroundStyle(.secondary)
                    Text("Use the + button in the sidebar to add a repository.")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(appState.repos) { repo in
                        RepoSettingsRow(repo: repo)
                    }
                }
            }
        }
        .padding()
    }
}

struct RepoSettingsRow: View {
    let repo: Repo
    @EnvironmentObject var appState: AppState
    @State private var editingName: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isEditing {
                    TextField("Display Name", text: $editingName, onCommit: {
                        commitRename()
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                    Button("Save") {
                        commitRename()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Cancel") {
                        isEditing = false
                    }
                    .controlSize(.small)
                } else {
                    Text(repo.displayName)
                        .font(.headline)

                    Button {
                        editingName = repo.displayName
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    Task {
                        await appState.removeRepo(repoID: repo.id)
                    }
                } label: {
                    Text("Remove")
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Label(repo.defaultBranch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(repo.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Picker("Model profile override", selection: profileOverrideBinding) {
                Text("Inherit global default").tag(UUID?.none)
                ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                    Text(profileLabel(entry: entry)).tag(UUID?.some(entry.profile.id))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.caption)

            if let caption = profileOverrideCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var profileOverrideBinding: Binding<UUID?> {
        Binding(
            get: { repo.profileOverrideID },
            set: { newValue in
                Task {
                    await appState.setRepoProfileOverride(repoID: repo.id, profileID: newValue)
                }
            }
        )
    }

    private func profileLabel(entry: ModelProfileWithUsage) -> String {
        if let detail = entry.profile.detailCaption {
            return "\(entry.profile.name) — \(detail)"
        }
        return entry.profile.name
    }

    private var profileOverrideCaption: String? {
        if let overrideID = repo.profileOverrideID {
            let name = appState.modelProfiles.first(where: { $0.profile.id == overrideID })?.profile.name ?? "Unknown profile"
            return "Overriding with: \(name)"
        }
        if let defaultID = appState.defaultProfileID,
           let name = appState.modelProfiles.first(where: { $0.profile.id == defaultID })?.profile.name {
            return "Inheriting: \(name)"
        }
        return "Inheriting: Default (claude keychain login)"
    }

    private func commitRename() {
        let newName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            isEditing = false
            return
        }
        isEditing = false
        // Update display name locally (daemon rename is for worktrees, not repos)
        // For repos we update the local model; the daemon doesn't store display name overrides
        if let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) {
            appState.repos[idx].displayName = newName
        }
    }
}
