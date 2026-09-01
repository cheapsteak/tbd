import AppKit
import SwiftUI
import TBDShared

/// Closes the SwiftUI `Settings` scene window so "Open login session" lands
/// the user directly on the newly focused terminal tab in the main window
/// instead of leaving Settings floating over it.
@MainActor
enum SettingsWindowCloser {
    static func close() {
        // The SwiftUI Settings scene window carries the stable identifier
        // "com_apple_SwiftUI_Settings_window"; match on the substring so a
        // future macOS rename of the prefix doesn't silently break this.
        for window in NSApplication.shared.windows
        where window.identifier?.rawValue.contains("Settings") == true {
            window.performClose(nil)
        }
    }
}

struct ModelProfilesSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var showAddSheet = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            globalDefaultHeader
            // Same persisted flag the spawn-time account picker's checkbox
            // writes — discoverable/toggleable from either surface.
            Toggle("Use default without asking (skip the account picker when starting Claude)",
                   isOn: $appState.skipAccountPicker)
                .font(.caption)
            Divider()
            profileList
            Spacer()
            addButton
        }
        .padding(20)
        .task { await appState.loadModelProfiles() }
        .sheet(isPresented: $showAddSheet) {
            AddModelProfileSheet()
                .environment(appState)
        }
    }

    private var globalDefaultHeader: some View {
        HStack {
            Text("Global default:")
                .font(.headline)
            Picker("", selection: Binding(
                get: { appState.defaultProfileID },
                set: { newValue in
                    Task { await appState.setDefaultProfile(id: newValue) }
                }
            )) {
                Text("Default (claude keychain login)").tag(UUID?.none)
                ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                    Text(entry.profile.name).tag(UUID?.some(entry.profile.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
    }

    private var profileList: some View {
        List {
            ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                ModelProfileRow(entry: entry)
                    .environment(appState)
            }
            .onMove { source, destination in
                appState.reorderModelProfiles(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 200)
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            Label("Add profile", systemImage: "plus")
        }
    }
}

// MARK: - Row

struct ModelProfileRow: View {
    @Environment(AppState.self) var appState
    let entry: ModelProfileWithUsage

    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false
    @State private var showEditEndpoint = false
    @State private var showEditBedrock = false
    @State private var showEditClaudeDirect = false
    /// In-flight and last-outcome state for the `⋯ ▸ Refresh usage` item.
    @State private var isRefreshingUsage = false
    @State private var usageRefreshOutcome: ProfileUsageRefreshOutcome?

    private var profile: ModelProfile { entry.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                nameView
                kindBadge
                // The same in-flight signal the add/edit sheets use, so a
                // refresh that takes a moment doesn't read as a dead click.
                if isRefreshingUsage {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                // Exactly one Edit button per row, partitioned by profile shape:
                // bedrock → proxy (non-bedrock with a baseURL) → Claude-direct (the rest).
                if profile.kind == .bedrock {
                    Button("Edit") { showEditBedrock = true }
                        .controlSize(.small)
                } else if profile.baseURL != nil {
                    Button("Edit") { showEditEndpoint = true }
                        .controlSize(.small)
                } else {
                    Button("Edit") { showEditClaudeDirect = true }
                        .controlSize(.small)
                }
                menuButton
            }
            if tokenRejected {
                // The stored setup token was rejected (401/403 on the usage
                // probe). Rotation is the only repair — a /login here would be
                // shadowed by the token — so the caption carries the fix
                // inline, mirroring the "Open login session" affordance's
                // shape. Deliberately outside the `endpointCaption` gate: a
                // profile whose secret file has gone missing has no masked
                // tail to render, and that is exactly when the user most needs
                // the button.
                HStack(spacing: 8) {
                    Text("Token rejected")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Replace token…") { showEditClaudeDirect = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Paste a fresh claude setup-token value for this profile")
                }
            } else if let caption = endpointCaption {
                if needsLogin {
                    HStack(spacing: 8) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open login session") {
                            Task {
                                if await appState.openLoginSession(profileID: profile.id) {
                                    SettingsWindowCloser.close()
                                }
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(appState.selectedWorktree == nil)
                        .help(appState.selectedWorktree == nil
                              ? "Select a worktree in the main window first"
                              : "Open a Claude session with this profile — /login is typed for you")
                    }
                } else {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let usageLine {
                Text(usageLine)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            if let usageRefreshOutcome {
                // What the last manual refresh did. Load-bearing for the
                // floored case: the daemon legitimately declines a token
                // profile's probe inside its five-minute window, leaving the
                // bars byte-identical, and an unexplained no-op reads as a
                // broken button.
                Text(ProfileUsageRefreshPresentation.note(for: usageRefreshOutcome))
                    .font(.caption)
                    .foregroundStyle(
                        ProfileUsageRefreshPresentation.noteIsWarning(for: usageRefreshOutcome)
                            ? Color.orange
                            : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .confirmationDialog("Delete profile?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await appState.deleteModelProfile(id: profile.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: $showEditEndpoint) {
            EditEndpointSheet(profile: profile)
                .environment(appState)
        }
        .sheet(isPresented: $showEditBedrock) {
            EditBedrockSheet(profile: profile)
                .environment(appState)
        }
        .sheet(isPresented: $showEditClaudeDirect) {
            EditClaudeDirectSheet(profile: profile)
                .environment(appState)
        }
    }

    private var endpointCaption: String? { ProfileLoginPresentation.settingsCaption(for: entry) }

    /// True for oauth profiles with no detected login — drives the inline
    /// "Open login session" affordance next to the caption.
    private var needsLogin: Bool {
        ProfileLoginPresentation.needsLogin(kind: profile.kind, loginIdentity: entry.loginIdentity)
    }

    /// True only for a token profile whose stored token the API rejected.
    /// `needsLogin` is false for that kind by construction, so the two caption
    /// treatments are mutually exclusive rather than racing each other.
    private var tokenRejected: Bool {
        ProfileLoginPresentation.tokenRejected(for: entry)
    }

    /// Per-account usage summary shown under the identity/endpoint caption,
    /// reusing `ProfileUsagePresentation.secondaryLine` over the daemon poller's
    /// `usageSnapshot` — the SAME source and honest-state handling the account
    /// menus render, so a rate-limited / needs-re-login / stale profile shows an
    /// explicit note rather than a silent blank. `nil` (no line) only when there
    /// is genuinely no snapshot (Bedrock/proxy profiles, or not yet polled).
    private var usageLine: String? {
        // The rejected-token caption above already states the condition AND
        // carries the repair; repeating "token rejected" underneath it would
        // print the same sentence twice.
        guard !tokenRejected else { return nil }
        return ProfileUsagePresentation.secondaryLine(for: entry.usageSnapshot,
                                                      kind: profile.kind)
    }

    @ViewBuilder
    private var nameView: some View {
        if isEditingName {
            TextField("", text: $draftName, onCommit: commitRename)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .onExitCommand { isEditingName = false }
        } else {
            Text(profile.name)
                .font(.body)
                .onTapGesture(count: 2) {
                    draftName = profile.name
                    isEditingName = true
                }
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        isEditingName = false
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        Task { await appState.renameModelProfile(id: profile.id, name: trimmed) }
    }

    private var kindBadge: some View {
        Text(profile.kindLabel)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    private var menuButton: some View {
        Menu {
            Button("Set as global default") {
                Task { await appState.setDefaultProfile(id: profile.id) }
            }
            Button("Rename…") {
                draftName = profile.name
                isEditingName = true
            }
            if needsLogin {
                Button("Open login session") {
                    Task {
                        if await appState.openLoginSession(profileID: profile.id) {
                            SettingsWindowCloser.close()
                        }
                    }
                }
                .disabled(appState.selectedWorktree == nil)
            }
            if ProfileUsageRefreshPresentation.showsRefreshItem(kind: profile.kind,
                                                                loginIdentity: entry.loginIdentity) {
                Button("Refresh usage") {
                    Task { await refreshUsage() }
                }
                .disabled(isRefreshingUsage)
                .help(ProfileUsageRefreshPresentation.refreshHelp(kind: profile.kind))
            }
            Divider()
            Button("Delete…", role: .destructive) {
                showDeleteConfirm = true
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Ask the daemon for fresh usage for THIS profile and leave the outcome
    /// on the row.
    ///
    /// Named — `refreshUsageSnapshot(profileID:)`, not the account picker's
    /// `refreshUsageSnapshots()` — because an unnamed sweep only visits the
    /// daemon's 90-second cadence set, which excludes token profiles by
    /// design. Without the id this menu item would spin and do nothing for the
    /// one kind that has no other way back to fresh numbers.
    private func refreshUsage() async {
        isRefreshingUsage = true
        usageRefreshOutcome = nil
        let outcome = await appState.refreshUsageSnapshot(profileID: profile.id)
        isRefreshingUsage = false
        usageRefreshOutcome = outcome
    }

    private var inUseCount: Int {
        appState.terminals.values.reduce(0) { acc, list in
            acc + list.filter { $0.profileID == profile.id }.count
        }
    }

    private var deleteMessage: String {
        let n = inUseCount
        if n > 0 {
            return "\(n) running terminal(s) are using this profile. They'll keep running on it until closed. Delete anyway?"
        }
        return "This will remove the profile from TBD. Are you sure?"
    }
}

// MARK: - Manual usage refresh

/// Pure decision layer for the profile row's `⋯ ▸ Refresh usage` item,
/// extracted from the view the same way `AddModelProfilePresentation` was: a
/// SwiftUI `View`'s private state cannot be exercised, and each rule here has
/// an off-branch that is wrong in a way no compiler catches.
enum ProfileUsageRefreshPresentation {

    /// Whether the row's `⋯` menu offers "Refresh usage" at all.
    ///
    /// Only where the gesture can actually do something — the app-side mirror
    /// of the daemon poller's own `isSupported`. A menu item that silently
    /// no-ops is worse than one that is absent, and for `.apiKey` / `.bedrock`
    /// there is no usage endpoint to read, while a signed-out `.oauth` profile
    /// has no credential to read one with; either would spin and report
    /// nothing.
    ///
    /// `.oauthToken` is the case this item exists for. Token profiles are
    /// deliberately excluded from the 90-second cadence sweep because their
    /// probe is a billed request, and the only other trigger is a
    /// `working → idle` transition on a session using the profile. Close that
    /// session and, without this item, the bars are frozen for good.
    static func showsRefreshItem(kind: CredentialKind, loginIdentity: String?) -> Bool {
        switch kind {
        case .oauthToken:
            return true
        case .oauth:
            return ProfileLoginPresentation.normalizedIdentity(loginIdentity) != nil
        case .apiKey, .bedrock:
            return false
        }
    }

    /// Tooltip for the item. A token profile's refresh is a real, billed API
    /// request floored at five minutes — `OAuthProfileUsagePoller.tokenProfileFloor`,
    /// which lives daemon-side and is not linkable from the app — so it says
    /// so outright rather than letting the user discover the cost by clicking.
    /// A signed-in profile's refresh is a free read of the usage endpoint.
    static func refreshHelp(kind: CredentialKind) -> String {
        kind == .oauthToken
            ? "Check this profile's usage now — a small billed request, at most once every 5 minutes"
            : "Fetch this profile's usage from Anthropic now"
    }

    /// The one-line note the row shows once a refresh returns.
    ///
    /// Every outcome gets a sentence, including the two that leave the bars
    /// unchanged: a refresh whose visible result is nothing at all is exactly
    /// what a broken button looks like.
    static func note(for outcome: ProfileUsageRefreshOutcome) -> String {
        switch outcome {
        case .refreshed:
            return "Usage refreshed."
        case .probeFailed:
            return "Refresh attempted — the fetch failed."
        case .alreadyCurrent:
            return "No new request — this profile was checked too recently."
        case .noData:
            return "No usage data available for this profile."
        case .failed(let message):
            return "Refresh failed — \(message)"
        }
    }

    /// Whether that note reads as a problem (orange) rather than an ordinary
    /// observation (secondary). `alreadyCurrent` is deliberately NOT a warning:
    /// declining to spend a billed probe inside the floor is the feature
    /// working, not a fault.
    static func noteIsWarning(for outcome: ProfileUsageRefreshOutcome) -> Bool {
        switch outcome {
        case .refreshed, .alreadyCurrent:
            return false
        case .probeFailed, .noData, .failed:
            return true
        }
    }
}

// MARK: - Add sheet

/// Top-aligned label + field + optional wrapping caption. Used by the
/// add/edit-profile sheets to keep the layout from getting squeezed by
/// macOS Form's trailing-label column.
private struct LabeledField<Field: View>: View {
    let label: String
    let caption: String?
    @ViewBuilder let field: () -> Field

    init(_ label: String, caption: String? = nil, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.caption = caption
        self.field = field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            field()
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Maximum number of fallback models Claude Code accepts (documented cap of 3).
/// Top-level (nonisolated) so both the main-actor editor view and the
/// nonisolated `normalizedFallbackModels` helper can reference one constant.
let fallbackModelsMaxCount = 3

/// Ordered editor for a profile's fallback model ids (capped at 3). Each row
/// is a text field with a remove button; an "Add fallback model" button appends
/// a row while under the cap. Order is significant — Claude Code tries the
/// models top-to-bottom when the primary is overloaded/unavailable.
///
/// Binds to a `[String]` of exactly the rows shown. Callers convert empty/blank
/// rows to `nil` before sending to the daemon (the daemon also normalizes).
struct FallbackModelsEditor: View {
    @Binding var models: [String]

    var body: some View {
        LabeledField(
            "Fallback models (optional)",
            caption: "Tried in order when the primary model is overloaded or unavailable. Up to \(fallbackModelsMaxCount). e.g. claude-haiku-4-5-20251001"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(models.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        TextField("", text: Binding(
                            get: { index < models.count ? models[index] : "" },
                            set: { if index < models.count { models[index] = $0 } }
                        ), prompt: Text("model id"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button {
                            if index < models.count { models.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this fallback model")
                    }
                }
                if models.count < fallbackModelsMaxCount {
                    Button {
                        models.append("")
                    } label: {
                        Label("Add fallback model", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Convert editor rows into the daemon payload: trim, drop blanks, cap at 3,
/// and collapse an empty result to nil.
///
/// Deliberately duplicates the daemon-side `normalizeFallbackModels` in
/// `Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift` —
/// defense-in-depth at both layers. Keep the two in sync.
func normalizedFallbackModels(_ rows: [String]) -> [String]? {
    let cleaned = rows
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(fallbackModelsMaxCount)
    return cleaned.isEmpty ? nil : Array(cleaned)
}

/// Top-level shape picker in the Add sheet. Internal (not private) so the
/// pure decision layer below is reachable from tests.
enum AddPreset: String, CaseIterable, Identifiable {
    case claudeDirect = "Claude"
    case proxy        = "Proxy"
    case bedrock      = "Bedrock"
    var id: String { rawValue }
}

/// How a Claude-direct profile authenticates. A visible sub-picker inside the
/// Claude segment, deliberately NOT inferred from whether the token field is
/// non-empty: an inferred mode is undiscoverable, and it makes the resulting
/// profile's kind awkward to reason about when editing.
enum ClaudeAuthMode: String, CaseIterable, Identifiable {
    case signIn = "Sign in"
    case token  = "Paste a token"
    var id: String { rawValue }
}

/// Pure decision layer for `AddModelProfileSheet`, extracted from the view the
/// same way `ProfileLoginPresentation` was — a SwiftUI `View`'s private state
/// cannot be exercised, and every one of these rules has an off-branch that is
/// wrong in a way no compiler catches.
enum AddModelProfilePresentation {

    /// The kind to send on `modelProfile.add`, or nil to let the daemon infer
    /// it from the other fields (today's behavior for sign-in and proxy).
    ///
    /// Only the token mode names a kind, and it must: `claudeDirect` carrying a
    /// token is the legacy path that stores nothing and warns, so "store this
    /// and authenticate with it" has to be said outright rather than inferred
    /// from a non-empty field.
    static func addKind(preset: AddPreset,
                        authMode: ClaudeAuthMode) -> ModelProfileAddKind? {
        preset == .claudeDirect && authMode == .token ? .claudeToken : nil
    }

    /// The token to send. nil for a sign-in profile — the daemon must not be
    /// handed a credential the user did not mean to store — and the typed
    /// value for the proxy and token paths alike.
    static func tokenToSend(preset: AddPreset,
                            authMode: ClaudeAuthMode,
                            token: String) -> String? {
        if preset == .claudeDirect && authMode == .signIn { return nil }
        return token
    }

    /// Whether the Claude segment has everything it needs. Sign-in needs only
    /// the name the caller already checked; token mode cannot save an empty
    /// credential, which the daemon rejects and which would leave a profile
    /// that is dead on arrival.
    static func canSaveClaude(authMode: ClaudeAuthMode, token: String) -> Bool {
        authMode == .signIn
            || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the post-save sheet swaps to the "Profile Created → Open login
    /// session" step. False for the token path: the profile is usable the
    /// moment the sheet closes, and that skipped step is the entire friction
    /// this credential kind removes.
    static func showsLoginFollowUp(preset: AddPreset,
                                   authMode: ClaudeAuthMode) -> Bool {
        preset == .claudeDirect && authMode == .signIn
    }
}

private enum ProbeStatus: Equatable {
    case idle
    case checking
    case ok(Int?)
    case warn(String)
}

// Map a daemon health-probe failure detail into a user-facing warning.
// Always returns a non-empty string — both branches produce a message.
func probeWarningMessage(for detail: String?) -> String {
    guard let detail, !detail.isEmpty else { return "Could not verify reachability. Saving anyway." }
    return "Unreachable — \(detail). Saving anyway."
}

@ViewBuilder
private func modelDiscoveryStatus(profile: String, discovery: BedrockModels.DiscoveryResult) -> some View {
    switch discovery {
    case .idle:
        EmptyView()

    case .loading:
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading models from AWS…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    case .success(let models) where models.isEmpty:
        Label("No Claude inference profiles in this region.", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)

    case .success:
        EmptyView()  // populated dropdown is its own UI

    case .needsAuth:
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("AWS authentication required.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                let trimmedProfile = profile.trimmingCharacters(in: .whitespaces)
                if !trimmedProfile.isEmpty {
                    (Text("Run ")
                        + Text("aws sso login --profile \(trimmedProfile)")
                            .font(.system(.caption, design: .monospaced))
                        + Text(" then click refresh."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    (Text("Run ")
                        + Text("aws sso login").font(.system(.caption, design: .monospaced))
                        + Text(" with your profile name in a terminal, then click refresh."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

    case .awsCliMissing:
        Label {
            (Text("AWS CLI not installed. Install with ")
                + Text("brew install awscli").font(.system(.caption, design: .monospaced))
                + Text(" to see Claude inference profiles your account has access to."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }

    case .accessDenied(let detail):
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your AWS profile can't list Bedrock inference profiles in this region.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

    case .endpointUnavailable(let detail):
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bedrock is not available in this region.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

    case .timeout:
        Label("AWS request timed out (5s). Click refresh to retry.", systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)

    case .otherError(let snippet):
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't load Claude models.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(snippet)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct AddModelProfileSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss

    @State private var preset: AddPreset = .claudeDirect
    /// Only meaningful while `preset == .claudeDirect`.
    @State private var claudeAuthMode: ClaudeAuthMode = .signIn
    @State private var name = ""
    @State private var token = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var awsRegion = "us-east-1"
    @State private var awsProfile = ""
    @State private var awsProfileSuggestions: [String] = []
    @State private var modelDiscovery: BedrockModels.DiscoveryResult = .idle
    @State private var fallbackModels: [String] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var probeStatus: ProbeStatus = .idle
    /// Set after a NEW oauth (Claude-direct) profile is saved: swaps the sheet
    /// content to a follow-up step offering a one-click login session.
    @State private var createdOAuthProfile: ModelProfileWithUsage?

    var body: some View {
        Group {
            if let created = createdOAuthProfile {
                loginFollowUp(created)
            } else {
                formBody
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { awsProfileSuggestions = AWSProfiles.discover() }
        .task(id: "\(preset)|\(awsRegion)|\(awsProfile)") {
            guard preset == .bedrock else { return }
            // Debounce so rapid keystrokes don't spam subprocess calls.
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            modelDiscovery = .loading
            modelDiscovery = await BedrockModels.discover(
                region: awsRegion,
                awsProfile: awsProfile.isEmpty ? nil : awsProfile
            )
        }
    }

    /// Post-save step for new oauth profiles: the profile exists but has no
    /// login yet — offer to open a Claude session pinned to it so the user can
    /// run /login immediately.
    private func loginFollowUp(_ entry: ModelProfileWithUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profile Created").font(.headline)
            (Text("“\(entry.profile.name)” is ready. Open a Claude session with it and run ")
                + Text("/login").font(.system(.caption, design: .monospaced))
                + Text(" once to connect an account — TBD keeps the login isolated to this profile."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if appState.selectedWorktree == nil {
                Text("Select a worktree in the main window to open a login session.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Later") { dismiss() }
                Button("Open login session") {
                    let profileID = entry.profile.id
                    Task {
                        let opened = await appState.openLoginSession(profileID: profileID)
                        dismiss()
                        if opened {
                            SettingsWindowCloser.close()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.selectedWorktree == nil)
            }
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Model Profile").font(.headline)

            Picker("", selection: $preset) {
                ForEach(AddPreset.allCases) { p in
                    Text(p.rawValue).tag(p).help({
                        switch p {
                        case .claudeDirect: return "Claude (direct) — authenticate once with /login"
                        case .proxy:        return "Anthropic-compatible proxy — local LLM router with its own token"
                        case .bedrock:      return "AWS Bedrock — uses the AWS SDK credential chain"
                        }
                    }())
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 14) {
                LabeledField("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                }

                switch preset {
                case .claudeDirect:
                    // One account type, two ways to authenticate it — rather
                    // than presenting the same product twice at top level.
                    LabeledField("Authentication") {
                        Picker("", selection: $claudeAuthMode) {
                            ForEach(ClaudeAuthMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    switch claudeAuthMode {
                    case .signIn:
                        (Text("After creating this profile, open a session with it and run ")
                            + Text("/login").font(.system(.caption, design: .monospaced))
                            + Text(" once. TBD keeps each profile's login isolated in its own config directory."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .token:
                        LabeledField(
                            "Token",
                            caption: "Run claude setup-token and paste the sk-ant-oat01-… value here. The profile is usable the moment this sheet closes — no login session needed."
                        ) {
                            SecureField("", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LabeledField(
                        "Model (optional)",
                        caption: "Leave blank to use Claude Code's default model."
                    ) {
                        TextField("", text: $model, prompt: Text("e.g. opus"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }

                case .proxy:
                    LabeledField("Token") {
                        SecureField("", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    }
                    LabeledField("Base URL") {
                        TextField("", text: $baseURL, prompt: Text("http://127.0.0.1:3456"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }
                    LabeledField(
                        "Model",
                        caption: "Leave blank to pass through whatever model Claude Code selects."
                    ) {
                        TextField("", text: $model, prompt: Text("e.g. gpt-5-codex"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }

                case .bedrock:
                    LabeledField("Region") {
                        ComboBoxField(
                            text: $awsRegion,
                            suggestions: BedrockRegions.suggestions,
                            placeholder: "us-east-1"
                        )
                        .frame(maxWidth: .infinity, minHeight: 22)
                    }
                    LabeledField(
                        "AWS profile (optional)",
                        caption: "Leave blank to use the AWS SDK default credential chain — env vars, SSO, instance role."
                    ) {
                        ComboBoxField(
                            text: $awsProfile,
                            suggestions: awsProfileSuggestions,
                            placeholder: "default"
                        )
                        .frame(maxWidth: .infinity, minHeight: 22)
                    }
                    LabeledField("Model") {
                        HStack(spacing: 6) {
                            ComboBoxField(
                                text: $model,
                                suggestions: modelDiscovery.models,
                                placeholder: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
                            )
                            .frame(maxWidth: .infinity, minHeight: 22)
                            Button(action: refreshModels) {
                                if case .loading = modelDiscovery {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh model list from AWS")
                            .disabled({ if case .loading = modelDiscovery { return true } else { return false } }())
                        }
                    }
                    modelDiscoveryStatus(profile: awsProfile, discovery: modelDiscovery)
                }

                FallbackModelsEditor(models: $fallbackModels)
            }

            probeView

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action: save) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
    }

    private func refreshModels() {
        modelDiscovery = .loading
        Task {
            let result = await BedrockModels.discover(
                region: awsRegion,
                awsProfile: awsProfile.isEmpty ? nil : awsProfile
            )
            await MainActor.run {
                modelDiscovery = result
            }
        }
    }

    @ViewBuilder
    private var probeView: some View {
        switch probeStatus {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking endpoint…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let code):
            if let code {
                Label("Reachable (HTTP \(code))", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Reachable", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .warn(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !isSaving else { return false }
        let duplicate = appState.modelProfiles.contains { $0.profile.name == trimmedName }
        if duplicate { return false }
        switch preset {
        case .claudeDirect:
            return AddModelProfilePresentation.canSaveClaude(authMode: claudeAuthMode,
                                                             token: token)
        case .proxy:
            return !token.isEmpty &&
                   !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .bedrock:
            return !awsRegion.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !model.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tokenValue = token
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedRegion = awsRegion.trimmingCharacters(in: .whitespaces)
        let trimmedAwsProfile = awsProfile.trimmingCharacters(in: .whitespaces)
        let preset = self.preset  // capture for the Task
        let authMode = self.claudeAuthMode
        isSaving = true
        errorMessage = nil
        Task {
            if preset == .bedrock {
                let priorAlert = await MainActor.run { appState.alertMessage }
                let warning = await appState.addModelProfile(
                    name: trimmedName,
                    kind: .bedrock,
                    token: nil,
                    baseURL: nil,
                    model: trimmedModel.isEmpty ? nil : trimmedModel,
                    awsRegion: trimmedRegion,
                    awsProfile: trimmedAwsProfile.isEmpty ? nil : trimmedAwsProfile,
                    fallbackModels: normalizedFallbackModels(fallbackModels)
                )
                await MainActor.run {
                    isSaving = false
                    let newAlert = appState.alertMessage
                    if newAlert != priorAlert, let msg = newAlert {
                        errorMessage = msg
                        appState.alertMessage = priorAlert
                        return
                    }
                    if let warning {
                        errorMessage = warning
                        return
                    }
                    dismiss()
                }
                return
            }

            if preset == .proxy {
                await MainActor.run { probeStatus = .checking }
                let result = await appState.healthCheckProfile(baseURL: trimmedBase)
                await MainActor.run {
                    if result.reachable {
                        probeStatus = .ok(result.statusCode)
                    } else {
                        probeStatus = .warn(probeWarningMessage(for: result.detail))
                    }
                }
            }

            let priorAlert = await MainActor.run { appState.alertMessage }
            let warning = await appState.addModelProfile(
                name: trimmedName,
                kind: AddModelProfilePresentation.addKind(preset: preset,
                                                          authMode: authMode),
                token: AddModelProfilePresentation.tokenToSend(preset: preset,
                                                              authMode: authMode,
                                                              token: tokenValue),
                baseURL: preset == .proxy ? trimmedBase : nil,
                // Bedrock returns early above, so only proxy/claudeDirect reach here —
                // both carry an optional model.
                model: trimmedModel.isEmpty ? nil : trimmedModel,
                fallbackModels: normalizedFallbackModels(fallbackModels)
            )
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert, let msg = newAlert {
                    errorMessage = msg
                    appState.alertMessage = priorAlert
                    return
                }
                // For OAuth profiles with the claudeDirect preset, warning is always nil
                // (the server doesn't store the token or perform usage checks).
                // For backward-compat paths with a supplied OAuth token, the warning
                // indicates the token was not stored. Show it inline and keep the sheet
                // open so the user can acknowledge before deciding to keep the profile.
                if let warning {
                    errorMessage = warning
                    return
                }
                if AddModelProfilePresentation.showsLoginFollowUp(preset: preset,
                                                                  authMode: authMode),
                   let created = appState.modelProfiles.first(where: {
                       $0.profile.kind == .oauth && $0.profile.name == trimmedName
                   }) {
                    // New oauth profile: swap the sheet to the follow-up step
                    // offering a one-click login session instead of closing.
                    // A token profile dismisses immediately instead — gated on
                    // the mode the user chose, so a name collision with an
                    // existing oauth profile cannot resurrect the follow-up.
                    createdOAuthProfile = created
                    return
                }
                dismiss()
            }
        }
    }
}

// MARK: - Edit endpoint sheet

struct EditEndpointSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    let profile: ModelProfile

    @State private var name: String
    @State private var baseURL: String
    @State private var model: String
    @State private var fallbackModels: [String]
    @State private var isSaving = false
    @State private var probeStatus: ProbeStatus = .idle
    @State private var errorMessage: String?

    init(profile: ModelProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _baseURL = State(initialValue: profile.baseURL ?? "")
        _model = State(initialValue: profile.model ?? "")
        _fallbackModels = State(initialValue: profile.fallbackModels ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Endpoint").font(.headline)
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                }
                LabeledField("Base URL") {
                    TextField("", text: $baseURL, prompt: Text("http://127.0.0.1:3456"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }
                LabeledField(
                    "Model",
                    caption: "Leave blank to pass through whatever model Claude Code selects."
                ) {
                    TextField("", text: $model, prompt: Text("e.g. gpt-5-codex"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }
                FallbackModelsEditor(models: $fallbackModels)
            }
            Divider()
            EnvOverridesEditor(
                initial: profile.envOverrides,
                caption: "Highest precedence. Cannot override the profile's own auth/routing (token, AWS region, model)."
            ) { await appState.setProfileEnvOverrides(profileID: profile.id, overrides: $0) }
            probeLabel
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action: save) {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var probeLabel: some View {
        switch probeStatus {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking endpoint…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok:
            Label("Reachable", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .warn(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isSaving
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        isSaving = true
        errorMessage = nil
        Task {
            let priorAlert = await MainActor.run { appState.alertMessage }

            // Rename first if changed; bail on conflict so we don't update
            // fields under a stale name.
            if trimmedName != profile.name {
                await appState.renameModelProfile(id: profile.id, name: trimmedName)
                let postRenameAlert = await MainActor.run { appState.alertMessage }
                if postRenameAlert != priorAlert, let msg = postRenameAlert {
                    await MainActor.run {
                        isSaving = false
                        errorMessage = msg
                        appState.alertMessage = priorAlert
                    }
                    return
                }
            }

            await MainActor.run { probeStatus = .checking }
            let result = await appState.healthCheckProfile(baseURL: trimmedBase)
            await MainActor.run {
                if result.reachable {
                    probeStatus = .ok(result.statusCode)
                } else {
                    probeStatus = .warn(probeWarningMessage(for: result.detail))
                }
            }
            let priorAlert2 = await MainActor.run { appState.alertMessage }
            await appState.updateModelProfileEndpoint(
                id: profile.id,
                baseURL: trimmedBase,
                model: trimmedModel.isEmpty ? nil : trimmedModel,
                fallbackModels: normalizedFallbackModels(fallbackModels)
            )
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert2, let msg = newAlert {
                    // Surface inline and keep the sheet open so the user can
                    // correct the input without losing what they typed.
                    probeStatus = .warn(msg)
                    appState.alertMessage = priorAlert2
                    return
                }
                dismiss()
            }
        }
    }
}

// MARK: - Edit Bedrock sheet

struct EditBedrockSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    let profile: ModelProfile

    @State private var name: String
    @State private var awsRegion: String
    @State private var awsProfile: String
    @State private var model: String
    @State private var fallbackModels: [String]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var awsProfileSuggestions: [String] = []
    @State private var modelDiscovery: BedrockModels.DiscoveryResult = .idle

    init(profile: ModelProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _awsRegion = State(initialValue: profile.awsRegion ?? "")
        _awsProfile = State(initialValue: profile.awsProfile ?? "")
        _model = State(initialValue: profile.model ?? "")
        _fallbackModels = State(initialValue: profile.fallbackModels ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Bedrock Profile").font(.headline)

            LabeledField("Name") {
                TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            }

            LabeledField("Region") {
                ComboBoxField(
                    text: $awsRegion,
                    suggestions: BedrockRegions.suggestions,
                    placeholder: "us-east-1"
                )
                .frame(maxWidth: .infinity, minHeight: 22)
            }
            LabeledField(
                "AWS profile (optional)",
                caption: "Leave blank to use the AWS SDK default credential chain — env vars, SSO, instance role."
            ) {
                ComboBoxField(
                    text: $awsProfile,
                    suggestions: awsProfileSuggestions,
                    placeholder: "default"
                )
                .frame(maxWidth: .infinity, minHeight: 22)
            }
            LabeledField("Model") {
                HStack(spacing: 6) {
                    ComboBoxField(
                        text: $model,
                        suggestions: modelDiscovery.models,
                        placeholder: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
                    )
                    .frame(maxWidth: .infinity, minHeight: 22)
                    Button(action: refreshModels) {
                        if case .loading = modelDiscovery {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh model list from AWS")
                    .disabled({ if case .loading = modelDiscovery { return true } else { return false } }())
                }
            }
            modelDiscoveryStatus(profile: awsProfile, discovery: modelDiscovery)

            FallbackModelsEditor(models: $fallbackModels)

            Divider()
            EnvOverridesEditor(
                initial: profile.envOverrides,
                caption: "Highest precedence. Cannot override the profile's own auth/routing (token, AWS region, model)."
            ) { await appState.setProfileEnvOverrides(profileID: profile.id, overrides: $0) }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action: save) {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { awsProfileSuggestions = AWSProfiles.discover() }
        .task(id: "\(awsRegion)|\(awsProfile)") {
            // Debounce so rapid keystrokes don't spam subprocess calls.
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            modelDiscovery = .loading
            modelDiscovery = await BedrockModels.discover(
                region: awsRegion,
                awsProfile: awsProfile.isEmpty ? nil : awsProfile
            )
        }
    }

    private func refreshModels() {
        modelDiscovery = .loading
        Task {
            let result = await BedrockModels.discover(
                region: awsRegion,
                awsProfile: awsProfile.isEmpty ? nil : awsProfile
            )
            await MainActor.run {
                modelDiscovery = result
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !awsRegion.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isSaving
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedRegion = awsRegion.trimmingCharacters(in: .whitespaces)
        let trimmedAwsProfile = awsProfile.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        isSaving = true
        errorMessage = nil
        Task {
            let priorAlert = await MainActor.run { appState.alertMessage }

            // Rename first if changed; bail on conflict so we don't update
            // fields under a stale name.
            if trimmedName != profile.name {
                await appState.renameModelProfile(id: profile.id, name: trimmedName)
                let postRenameAlert = await MainActor.run { appState.alertMessage }
                if postRenameAlert != priorAlert, let msg = postRenameAlert {
                    await MainActor.run {
                        isSaving = false
                        errorMessage = msg
                        appState.alertMessage = priorAlert
                    }
                    return
                }
            }

            await appState.updateModelProfileBedrock(
                id: profile.id,
                awsRegion: trimmedRegion,
                awsProfile: trimmedAwsProfile.isEmpty ? nil : trimmedAwsProfile,
                model: trimmedModel,
                fallbackModels: normalizedFallbackModels(fallbackModels)
            )
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert, let msg = newAlert {
                    errorMessage = msg
                    appState.alertMessage = priorAlert
                    return
                }
                dismiss()
            }
        }
    }
}

// MARK: - Edit Claude (direct) sheet

struct EditClaudeDirectSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    let profile: ModelProfile

    @State private var name: String
    @State private var model: String
    @State private var fallbackModels: [String]
    /// Only shown for `.oauthToken` profiles. Blank means "keep the stored
    /// token" — never "clear it"; there is deliberately no way to leave a token
    /// profile with no credential from this sheet.
    @State private var replacementToken = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(profile: ModelProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _model = State(initialValue: profile.model ?? "")
        _fallbackModels = State(initialValue: profile.fallbackModels ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Claude Profile").font(.headline)
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                }
                LabeledField(
                    "Model (optional)",
                    caption: "Leave blank to use Claude Code's default model."
                ) {
                    TextField("", text: $model, prompt: Text("e.g. opus"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }
                if profile.kind == .oauthToken {
                    // Setup tokens expire and can be revoked, and this is the
                    // only recovery path for a profile whose token aged out —
                    // deleting and recreating would throw away its isolated
                    // config dir along with the credential.
                    LabeledField(
                        "Replace token",
                        caption: "Run claude setup-token again and paste the new sk-ant-oat01-… value."
                    ) {
                        SecureField("", text: $replacementToken,
                                    prompt: Text("Leave blank to keep the current token"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }
                }
                FallbackModelsEditor(models: $fallbackModels)
            }
            Divider()
            EnvOverridesEditor(
                initial: profile.envOverrides,
                caption: "Highest precedence. Cannot override the profile's own auth/routing (token, AWS region, model)."
            ) { await appState.setProfileEnvOverrides(profileID: profile.id, overrides: $0) }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action: save) {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let newToken = replacementToken.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        errorMessage = nil
        Task {
            let priorAlert = await MainActor.run { appState.alertMessage }

            // Rename first if changed; bail on conflict so we don't update
            // fields under a stale name.
            if trimmedName != profile.name {
                await appState.renameModelProfile(id: profile.id, name: trimmedName)
                let postRenameAlert = await MainActor.run { appState.alertMessage }
                if postRenameAlert != priorAlert, let msg = postRenameAlert {
                    await MainActor.run {
                        isSaving = false
                        errorMessage = msg
                        appState.alertMessage = priorAlert
                    }
                    return
                }
            }

            // Rotate the stored token before the endpoint update, so a
            // rejected token leaves the sheet open on the field that caused it
            // rather than after an unrelated save has already succeeded. Blank
            // skips the call entirely — the stored token is left alone.
            if profile.kind == .oauthToken, !newToken.isEmpty {
                let priorTokenAlert = await MainActor.run { appState.alertMessage }
                let replaced = await appState.updateModelProfileToken(id: profile.id,
                                                                     token: newToken)
                if !replaced {
                    await MainActor.run {
                        isSaving = false
                        // The daemon's message, never the token bytes.
                        errorMessage = appState.alertMessage ?? "Failed to replace token"
                        appState.alertMessage = priorTokenAlert
                    }
                    return
                }
            }

            let priorAlert2 = await MainActor.run { appState.alertMessage }
            await appState.updateModelProfileEndpoint(
                id: profile.id,
                baseURL: nil,
                model: trimmedModel.isEmpty ? nil : trimmedModel,
                fallbackModels: normalizedFallbackModels(fallbackModels)
            )
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert2, let msg = newAlert {
                    errorMessage = msg
                    appState.alertMessage = priorAlert2
                    return
                }
                dismiss()
            }
        }
    }
}
