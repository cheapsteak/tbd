import SwiftUI
import TBDShared

struct ModelProfilesSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            globalDefaultHeader
            Divider()
            profileList
            Spacer()
            addButton
        }
        .padding(20)
        .task { await appState.loadModelProfiles() }
        .sheet(isPresented: $showAddSheet) {
            AddModelProfileSheet()
                .environmentObject(appState)
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
                    .environmentObject(appState)
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
    @EnvironmentObject var appState: AppState
    let entry: ModelProfileWithUsage

    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false
    @State private var showEditEndpoint = false
    @State private var showEditBedrock = false
    @State private var showEditClaudeDirect = false

    private var profile: ModelProfile { entry.profile }
    private var usage: ModelProfileUsage? { entry.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                nameView
                kindBadge
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
            if let caption = endpointCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .environmentObject(appState)
        }
        .sheet(isPresented: $showEditBedrock) {
            EditBedrockSheet(profile: profile)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showEditClaudeDirect) {
            EditClaudeDirectSheet(profile: profile)
                .environmentObject(appState)
        }
    }

    private var endpointCaption: String? { profile.detailCaption }

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

private enum AddPreset: String, CaseIterable, Identifiable {
    case claudeDirect = "Claude"
    case proxy        = "Proxy"
    case bedrock      = "Bedrock"
    var id: String { rawValue }
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
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var preset: AddPreset = .claudeDirect
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

    var body: some View {
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
                    (Text("After creating this profile, open a session with it and run ")
                        + Text("/login").font(.system(.caption, design: .monospaced))
                        + Text(" once. TBD keeps each profile's login isolated in its own config directory."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .padding(20)
        .frame(width: 520)
        .onAppear { awsProfileSuggestions = AWSProfiles.discover() }
        .task(id: "\(preset)|\(awsRegion)|\(awsProfile)") {
            guard preset == .bedrock else { return }
            // Debounce so rapid keystrokes don't spam subprocess calls.
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
            return true
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
                token: preset == .claudeDirect ? nil : tokenValue,
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
                dismiss()
            }
        }
    }
}

// MARK: - Edit endpoint sheet

struct EditEndpointSheet: View {
    @EnvironmentObject var appState: AppState
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
    @EnvironmentObject var appState: AppState
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
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: ModelProfile

    @State private var name: String
    @State private var model: String
    @State private var fallbackModels: [String]
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
                FallbackModelsEditor(models: $fallbackModels)
            }
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
