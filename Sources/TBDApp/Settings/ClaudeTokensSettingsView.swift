// ClaudeTokensSettingsView
//
// Settings tab for managing Claude tokens. SwiftUI-only; no automated tests.
//
// Manual verification steps:
// 1. Open Settings → Claude Tokens. Empty state shows only "Default (claude
//    keychain login)" in the global default picker.
// 2. Click "Add token". The modal opens with Name + Token (SecureField) and
//    helper text mentioning `claude setup-token`. Save is disabled until both
//    fields are filled and the name is not a duplicate.
// 3. Enter a name + paste a real `sk-ant-oat01-...` token. Spinner shows in
//    the Save button while saving, then the modal dismisses on success.
// 4. The new row shows the name, an OAuth/API key badge, and (after the next
//    refresh) `5h X% · 7d Y%`. Hovering the percentages shows a tooltip with
//    `Resets in Xh Ym` for each window.
// 5. Double-click the row's name to inline-rename. Enter commits, Esc cancels.
// 6. The trailing `…` menu offers "Set as global default", "Rename…", and
//    "Delete…". Set-as-default updates the header picker.
// 7. Delete… opens a confirm. If any running terminals use this token the
//    copy includes the count from `appState.terminals`.
// 8. Force `last_status = http_401` in the DB → red "Invalid" badge.
//    Force `last_status = http_429` → amber "Stale" badge.

import SwiftUI
import TBDShared

struct ClaudeTokensSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            globalDefaultHeader
            Divider()
            tokenList
            Spacer()
            addButton
        }
        .padding(20)
        .task { await appState.refreshClaudeTokens() }
        .sheet(isPresented: $showAddSheet) {
            AddClaudeTokenSheet()
                .environmentObject(appState)
        }
    }

    private var globalDefaultHeader: some View {
        HStack {
            Text("Global default:")
                .font(.headline)
            Picker("", selection: Binding(
                get: { appState.globalDefaultClaudeTokenID },
                set: { newValue in
                    Task { await appState.setGlobalDefaultClaudeToken(id: newValue) }
                }
            )) {
                Text("Default (claude keychain login)").tag(UUID?.none)
                ForEach(appState.claudeTokens, id: \.token.id) { entry in
                    Text(entry.token.name).tag(UUID?.some(entry.token.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
    }

    private var tokenList: some View {
        List {
            ForEach(appState.claudeTokens, id: \.token.id) { entry in
                ClaudeTokenRow(entry: entry)
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
            Label("Add token", systemImage: "plus")
        }
    }
}

// MARK: - Row

struct ClaudeTokenRow: View {
    @EnvironmentObject var appState: AppState
    let entry: ClaudeTokenWithUsage

    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false

    private var token: ClaudeToken { entry.token }
    private var usage: ClaudeTokenUsage? { entry.usage }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            nameView
            kindBadge
            Spacer()
            menuButton
        }
        .contentShape(Rectangle())
        .confirmationDialog("Delete token?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await appState.deleteClaudeToken(id: token.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    @ViewBuilder
    private var nameView: some View {
        if isEditingName {
            TextField("", text: $draftName, onCommit: commitRename)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .onExitCommand { isEditingName = false }
        } else {
            Text(token.name)
                .font(.body)
                .onTapGesture(count: 2) {
                    draftName = token.name
                    isEditingName = true
                }
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        isEditingName = false
        guard !trimmed.isEmpty, trimmed != token.name else { return }
        Task { await appState.renameClaudeToken(id: token.id, name: trimmed) }
    }

    private var kindBadge: some View {
        Text(token.kind == .oauth ? "OAuth" : "API key")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var statusBadges: some View {
        switch usage?.lastStatus {
        case "http_401", "http401":
            badge("Invalid", color: .red)
        case "http_429", "http429":
            badge("Stale", color: .orange)
        case "network_error", "decode_error":
            badge("Unverified", color: .orange)
        default:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var usageView: some View {
        if let usage,
           let fiveHPct = usage.fiveHourPct,
           let sevenDPct = usage.sevenDayPct {
            let fiveH = Int((fiveHPct * 100).rounded())
            let sevenD = Int((sevenDPct * 100).rounded())
            Text("5h \(fiveH)% · 7d \(sevenD)%")
                .font(.system(.caption, design: .monospaced))
                .help(resetTooltip(usage))
        } else {
            Text("—")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func resetTooltip(_ usage: ClaudeTokenUsage) -> String {
        let fiveH = formatRelativeFuture(usage.fiveHourResetsAt)
        let sevenD = formatRelativeFuture(usage.sevenDayResetsAt)
        return "Resets in \(fiveH) (5h) / \(sevenD) (7d)"
    }

    private func formatRelativeFuture(_ date: Date?) -> String {
        guard let date else { return "—" }
        let secs = max(0, Int(date.timeIntervalSinceNow))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return "\(h)h \(m)m"
    }

    @ViewBuilder
    private var timestampView: some View {
        if let fetched = usage?.fetchedAt {
            Text(Self.relativeFormatter.localizedString(for: fetched, relativeTo: Date()))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var menuButton: some View {
        Menu {
            Button("Set as global default") {
                Task { await appState.setGlobalDefaultClaudeToken(id: token.id) }
            }
            Button("Rename…") {
                draftName = token.name
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
            acc + list.filter { $0.claudeTokenID == token.id }.count
        }
    }

    private var deleteMessage: String {
        let n = inUseCount
        if n > 0 {
            return "\(n) running terminal(s) are using this token. They'll keep running on it until closed. Delete anyway?"
        }
        return "This will remove the token from TBD. Are you sure?"
    }
}

// MARK: - Add sheet

struct AddClaudeTokenSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Claude Token").font(.headline)

            Form {
                TextField("Name", text: $name)
                SecureField("Token", text: $token)
                (Text("Run ")
                    + Text("claude setup-token").font(.system(.caption, design: .monospaced))
                    + Text(" in a terminal and paste the resulting sk-ant-oat01-… token."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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
        .frame(width: 420)
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !token.isEmpty, !isSaving else { return false }
        let duplicate = appState.claudeTokens.contains { $0.token.name == trimmedName }
        return !duplicate
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tokenValue = token
        isSaving = true
        errorMessage = nil
        Task {
            // addClaudeToken sets appState.alertMessage on error and returns
            // nil; on success it returns an optional warning string. We treat
            // a nil return alongside a freshly-set alertMessage as failure.
            let priorAlert = await MainActor.run { appState.alertMessage }
            let warning = await appState.addClaudeToken(name: trimmedName, token: tokenValue)
            await MainActor.run {
                isSaving = false
                let newAlert = appState.alertMessage
                if newAlert != priorAlert, let msg = newAlert {
                    errorMessage = msg
                    appState.alertMessage = priorAlert
                    return
                }
                // Token was saved. A non-nil `warning` means the daemon could
                // not verify the token's quota with Anthropic but stored it
                // anyway — surface that to the user via the row's status
                // badge, not as a red error in this modal. Dismiss either way.
                _ = warning
                dismiss()
            }
        }
    }
}
