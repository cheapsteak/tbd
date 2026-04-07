# Phase 09: Settings → Claude Tokens Tab

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 08
> **Unblocks:** nothing (terminal UI phase)

**Scope:** A new Settings tab for managing Claude tokens: list with usage badges and reset tooltips, add modal with `claude setup-token` guidance, rename/delete with in-use warning, and a global-default picker.

## Context

Phase 08 wired up `AppState.claudeTokens`, `globalDefaultClaudeTokenID`, `addClaudeToken(name:token:)`, `renameClaudeToken`, `deleteClaudeToken`, `setGlobalDefaultClaudeToken`, and `refreshClaudeTokens()`. Each `ClaudeToken` carries `id`, `name`, `kind` ("oauth" | "api_key"), `usage: ClaudeTokenUsage?` (with `fiveHourPercent`, `sevenDayPercent`, `fiveHourResetsAt`, `sevenDayResetsAt`, `fetchedAt`), and `lastStatus: String?`.

This phase is purely SwiftUI. Mirror the rename UX from `RepoSettingsRow` (double-click to edit inline, Enter to commit, Esc to cancel).

## Tasks

### Task 1: Create file skeleton

Create `Sources/TBDApp/Settings/ClaudeTokensSettingsView.swift` with imports and the top-level `ClaudeTokensSettingsView` struct stub:

```swift
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
}
```

### Task 2: Global default header

Add the picker bound to `appState.globalDefaultClaudeTokenID`. The `nil` option represents the keychain login fallback.

```swift
private var globalDefaultHeader: some View {
    HStack {
        Text("Global default:")
            .font(.headline)
        Picker("", selection: Binding(
            get: { appState.globalDefaultClaudeTokenID },
            set: { newValue in
                Task { await appState.setGlobalDefaultClaudeToken(newValue) }
            }
        )) {
            Text("Default (claude keychain login)").tag(String?.none)
            ForEach(appState.claudeTokens) { token in
                Text(token.name).tag(String?.some(token.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        Spacer()
    }
}
```

### Task 3: Token list

Render rows in a `List` so selection/scrolling feels native. Use `ForEach` over `appState.claudeTokens`.

```swift
private var tokenList: some View {
    List {
        ForEach(appState.claudeTokens) { token in
            ClaudeTokenRow(token: token)
                .environmentObject(appState)
        }
    }
    .listStyle(.inset)
    .frame(minHeight: 200)
}
```

### Task 4: Add button

```swift
private var addButton: some View {
    Button {
        showAddSheet = true
    } label: {
        Label("Add token", systemImage: "plus")
    }
}
```

### Task 5: ClaudeTokenRow scaffolding

Create `ClaudeTokenRow` with state for inline rename and delete confirmation:

```swift
struct ClaudeTokenRow: View {
    @EnvironmentObject var appState: AppState
    let token: ClaudeToken

    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            nameView
            kindBadge
            Spacer()
            statusBadges
            usageView
            timestampView
            menuButton
        }
        .contentShape(Rectangle())
        .confirmationDialog("Delete token?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await appState.deleteClaudeToken(token.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }
}
```

### Task 6: Inline rename UX (mirror RepoSettingsRow)

Double-click to enter edit mode, commit on Enter, cancel on Esc.

```swift
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
    Task { await appState.renameClaudeToken(token.id, to: trimmed) }
}
```

### Task 7: Kind and status badges

```swift
private var kindBadge: some View {
    Text(token.kind == "oauth" ? "OAuth" : "API key")
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
}

@ViewBuilder
private var statusBadges: some View {
    if token.lastStatus == "http_401" {
        Text("Invalid")
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.red.opacity(0.2))
            .foregroundColor(.red)
            .clipShape(Capsule())
    } else if token.lastStatus == "http_429" {
        Text("Stale")
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.2))
            .foregroundColor(.orange)
            .clipShape(Capsule())
    }
}
```

### Task 8: Usage text + reset tooltip

Format `5h X% · 7d Y%`. Show `—` when usage is nil. Tooltip shows reset times computed from `resetsAt`.

```swift
@ViewBuilder
private var usageView: some View {
    if let usage = token.usage {
        let fiveH = Int((usage.fiveHourPercent * 100).rounded())
        let sevenD = Int((usage.sevenDayPercent * 100).rounded())
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
    return "5h resets in \(fiveH) / 7d resets in \(sevenD)"
}

private func formatRelativeFuture(_ date: Date?) -> String {
    guard let date else { return "—" }
    let secs = max(0, Int(date.timeIntervalSinceNow))
    let h = secs / 3600
    let m = (secs % 3600) / 60
    return "\(h)h \(m)m"
}
```

### Task 9: Relative fetched-at timestamp

Use `RelativeDateTimeFormatter`. Cache it as a static.

```swift
private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

@ViewBuilder
private var timestampView: some View {
    if let fetched = token.usage?.fetchedAt {
        Text(Self.relativeFormatter.localizedString(for: fetched, relativeTo: Date()))
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
```

### Task 10: Trailing menu

```swift
private var menuButton: some View {
    Menu {
        Button("Set as global default") {
            Task { await appState.setGlobalDefaultClaudeToken(token.id) }
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
    appState.terminals.filter { $0.claudeTokenID == token.id }.count
}

private var deleteMessage: String {
    let n = inUseCount
    if n > 0 {
        return "\(n) running terminal(s) are using this token. They'll keep running on it until closed. Delete anyway?"
    }
    return "This will remove the token from TBD. Are you sure?"
}
```

### Task 11: AddClaudeTokenSheet — fields

Use `SecureField` for the token (it's a secret).

```swift
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
                    + Text(" in a terminal and paste the resulting sk-ant-oat01-... token."))
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
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

### Task 12: AddClaudeTokenSheet — validation + save

Client-side: name non-empty, not duplicate, token non-empty. Server-side covers format checks.

```swift
private var canSave: Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty, !token.isEmpty, !isSaving else { return false }
    let duplicate = appState.claudeTokens.contains { $0.name == trimmedName }
    return !duplicate
}

private func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    isSaving = true
    errorMessage = nil
    Task {
        do {
            try await appState.addClaudeToken(name: trimmedName, token: token)
            await appState.refreshClaudeTokens()
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

### Task 13: Wire tab into SettingsView

Open `Sources/TBDApp/Settings/SettingsView.swift`. Add the new `TabView` item alongside the existing tabs:

```swift
ClaudeTokensSettingsView()
    .tabItem { Label("Claude Tokens", systemImage: "key.fill") }
```

Bump the frame height from `420` to `520` (or as needed) so the token list and add button fit comfortably without scrolling jitter.

### Task 14: Build + manual verification

Run `swift build` to confirm everything compiles. Then `scripts/restart.sh` and walk through:

1. Open Settings → Claude Tokens tab. List is empty, global default picker shows only "Default (claude keychain login)".
2. Click "+ Add token". Modal opens. Try Save with empty name → button disabled. Enter "Personal" + paste a real `sk-ant-oat01-...` token. Spinner appears, then modal dismisses.
3. Row appears showing "Personal" + "OAuth" badge. Within a few seconds usage populates: e.g. `5h 12% · 7d 4%`. Hover the percentages → tooltip shows reset times.
4. Double-click the name → inline edit. Type "Work", press Enter. Row updates.
5. Open the `•••` menu → "Set as global default". Header picker now shows "Work".
6. Add a second token "Bad" with an obviously invalid string → modal shows red error inline, stays open.
7. Open a terminal that uses the "Work" token (Phase 10 work, may need to fake by inserting a row). Then `•••` → Delete… → confirm copy mentions "1 running terminal(s) are using this token". Cancel.
8. Cancel modal closes without saving. Re-open and Cancel mid-spinner — should not crash.
9. Force a 401 by editing the DB row's `last_status` to `http_401` → row shows red "Invalid" badge after refresh.
10. Force a 429 similarly → amber "Stale" badge.

Commit when green: `feat: add Claude Tokens settings tab`.
