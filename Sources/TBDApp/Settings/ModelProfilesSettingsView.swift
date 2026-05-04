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

    private var profile: ModelProfile { entry.profile }
    private var usage: ModelProfileUsage? { entry.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                nameView
                kindBadge
                Spacer()
                if profile.baseURL != nil {
                    Button("Edit endpoint") { showEditEndpoint = true }
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
    }

    private var endpointCaption: String? {
        guard let baseURL = profile.baseURL else { return nil }
        if let model = profile.model, !model.isEmpty {
            return "via \(baseURL) · \(model)"
        }
        return "via \(baseURL)"
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
        Text(profile.kind == .oauth ? "OAuth" : "API key")
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

private enum AddPreset: String, CaseIterable, Identifiable {
    case claudeDirect = "Claude (direct)"
    case proxy = "Anthropic-compatible proxy"
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

struct AddModelProfileSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var preset: AddPreset = .claudeDirect
    @State private var name = ""
    @State private var token = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var probeStatus: ProbeStatus = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Model Profile").font(.headline)

            Picker("", selection: $preset) {
                ForEach(AddPreset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                TextField("Name", text: $name)
                SecureField("Token", text: $token)
                if preset == .proxy {
                    TextField("Base URL", text: $baseURL,
                              prompt: Text("http://127.0.0.1:3456"))
                    TextField("Model", text: $model,
                              prompt: Text("e.g. gpt-5-codex"))
                    Text("Leave blank to pass through whatever model Claude Code selects.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    (Text("Run ")
                        + Text("claude setup-token").font(.system(.caption, design: .monospaced))
                        + Text(" in a terminal and paste the resulting sk-ant-oat01-… token."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
        .frame(width: 460)
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
        guard !trimmedName.isEmpty, !token.isEmpty, !isSaving else { return false }
        let duplicate = appState.modelProfiles.contains { $0.profile.name == trimmedName }
        if duplicate { return false }
        if preset == .proxy {
            let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
            if trimmedBase.isEmpty { return false }
        }
        return true
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tokenValue = token
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let useProxy = preset == .proxy
        isSaving = true
        errorMessage = nil
        Task {
            if useProxy {
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
                token: tokenValue,
                baseURL: useProxy ? trimmedBase : nil,
                model: useProxy ? (trimmedModel.isEmpty ? nil : trimmedModel) : nil
            )
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert, let msg = newAlert {
                    errorMessage = msg
                    appState.alertMessage = priorAlert
                    return
                }
                // OAuth-add returned a non-nil verification warning (e.g. 429
                // or network error from the Anthropic usage endpoint). Show it
                // inline and keep the sheet open — the user must acknowledge
                // before deciding whether to keep the unverified profile.
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

    @State private var baseURL: String
    @State private var model: String
    @State private var isSaving = false
    @State private var probeStatus: ProbeStatus = .idle

    init(profile: ModelProfile) {
        self.profile = profile
        _baseURL = State(initialValue: profile.baseURL ?? "")
        _model = State(initialValue: profile.model ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Endpoint").font(.headline)
            Form {
                TextField("Base URL", text: $baseURL,
                          prompt: Text("http://127.0.0.1:3456"))
                TextField("Model", text: $model,
                          prompt: Text("e.g. gpt-5-codex"))
                Text("Leave blank to pass through whatever model Claude Code selects.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            probeLabel
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action: save) {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
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

    private func save() {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        isSaving = true
        Task {
            await MainActor.run { probeStatus = .checking }
            let result = await appState.healthCheckProfile(baseURL: trimmedBase)
            await MainActor.run {
                if result.reachable {
                    probeStatus = .ok(result.statusCode)
                } else {
                    probeStatus = .warn(probeWarningMessage(for: result.detail))
                }
            }
            let priorAlert = await MainActor.run { appState.alertMessage }
            await appState.updateModelProfileEndpoint(
                id: profile.id,
                baseURL: trimmedBase,
                model: trimmedModel.isEmpty ? nil : trimmedModel
            )
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert, let msg = newAlert {
                    // Surface inline and keep the sheet open so the user can
                    // correct the input without losing what they typed.
                    probeStatus = .warn(msg)
                    appState.alertMessage = priorAlert
                    return
                }
                dismiss()
            }
        }
    }
}
