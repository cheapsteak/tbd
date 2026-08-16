import SwiftUI
import TBDShared

enum RepoDetailTab: String, CaseIterable {
    case archived = "Archived"
    case instructions = "Instructions"
    case settings = "Settings"
}

struct RepoDetailView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var selectedTab: RepoDetailTab = .archived
    /// The repo whose pre-session hook editor should be revealed, pending
    /// consumption by `RepoSettingsView`. Cleared the moment that view scrolls,
    /// so a later remount (repo switch, or tabbing away and back) does not
    /// re-scroll or re-steal focus.
    @State private var pendingHookReveal: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(RepoDetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .padding(.vertical, 12)

            Divider()

            switch selectedTab {
            case .archived:
                ArchivedWorktreesView(repoID: repoID)
            case .instructions:
                RepoInstructionsView(repoID: repoID)
                    .id(repoID)
            case .settings:
                RepoSettingsView(repoID: repoID, pendingHookReveal: $pendingHookReveal)
                    .id(repoID)
            }
        }
        // Fresh mount (no repo was selected before).
        .onAppear {
            consumeReveal(appState.repoDetailReveal)
            applyPendingTab()
        }
        // Reused instance (another repo was selected, or this one on another tab).
        .onChange(of: appState.repoDetailReveal) { _, reveal in consumeReveal(reveal) }
        .onChange(of: appState.pendingRepoDetailTab) { _, _ in applyPendingTab() }
    }

    /// Apply a reveal addressed to this repo, then clear it so navigating back
    /// does not replay it. Reveals for another repo are ignored, not consumed.
    private func consumeReveal(_ reveal: AppState.RepoDetailReveal?) {
        guard case let .preSessionHook(id) = reveal, id == repoID else { return }
        selectedTab = .settings
        pendingHookReveal = repoID
        appState.repoDetailReveal = nil
    }

    private func applyPendingTab() {
        if let pending = appState.pendingRepoDetailTab {
            selectedTab = pending
            appState.pendingRepoDetailTab = nil
        }
    }
}

struct RepoSettingsView: View {
    let repoID: UUID
    /// Set by `RepoDetailView` when a pre-session-hook reveal targets this
    /// repo; consumed (set back to `nil`) the moment this view acts on it.
    @Binding var pendingHookReveal: UUID?
    @EnvironmentObject var appState: AppState
    /// Drives focus into the pre-session TextEditor once scrolled.
    @FocusState private var focusedHook: RepoHooksSettingsView.HookField?

    private var repo: Repo? {
        appState.repos.first { $0.id == repoID }
    }

    var body: some View {
        if let repo = repo {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Model profile override", selection: profileOverrideBinding(repo: repo)) {
                            Text("Inherit global default").tag(UUID?.none)
                            ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                                Text(profileLabel(entry: entry)).tag(UUID?.some(entry.profile.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let caption = profileOverrideCaption(repo: repo) {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        EnvOverridesEditor(
                            initial: repo.envOverrides,
                            caption: "Overrides global; overridden by the repo's model profile."
                        ) { await appState.setRepoEnvOverrides(repoID: repo.id, overrides: $0) }

                        Divider()
                            .padding(.vertical, 4)

                        RemoteCreateDefaultsEditor(
                            scope: .repo,
                            providers: appState.remoteProviders,
                            initial: repo.remoteCreateDefaults,
                            inheritedDefaults: appState.globalRemoteCreateDefaults
                        ) { await appState.setRepoRemoteCreateDefaults(repoID: repo.id, defaults: $0) }

                        Divider()
                            .padding(.vertical, 4)

                        ClaudeSettingsOverlayEditor(repoID: repo.id)

                        Divider()
                            .padding(.vertical, 4)

                        RepoHooksSettingsView(repoID: repoID, focusedHook: $focusedHook)
                    }
                    .padding()
                }
                .onAppear { consumeHookReveal(proxy) }
                .onChange(of: pendingHookReveal) { _, _ in consumeHookReveal(proxy) }
            }
        }
    }

    /// Scroll the pre-session hook section into view and focus its editor,
    /// but only if a reveal is pending for this repo. Consumes the reveal
    /// (clears it to `nil`) before acting, so it is a true one-shot: a later
    /// remount of this view (repo switch, or tab away and back) does not
    /// re-scroll or re-steal focus.
    private func consumeHookReveal(_ proxy: ScrollViewProxy) {
        guard pendingHookReveal == repoID else { return }
        pendingHookReveal = nil
        withAnimation { proxy.scrollTo(RepoHooksSettingsView.preSessionAnchor, anchor: .top) }
        focusedHook = .preSession
    }

    private func profileOverrideBinding(repo: Repo) -> Binding<UUID?> {
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

    private func profileOverrideCaption(repo: Repo) -> String? {
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
}

/// Per-repo editor for the Claude settings overlay fragment, file-backed like
/// the hook editors in `RepoHooksSettingsView`: the fragment lives at
/// `~/tbd/repos/<repoID>/claude-settings.json` and is read fresh at every
/// Claude spawn, so it can also be edited externally. Empty/whitespace save
/// deletes the file. Passthrough by design — no JSON validation beyond what
/// the daemon logs at spawn time. See docs/claude-settings-overlay.md.
private struct ClaudeSettingsOverlayEditor: View {
    let repoID: UUID

    @State private var text = ""
    @State private var showSaved = false

    private var filePath: String { TBDConstants.claudeSettingsOverlayPath(repoID: repoID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude settings overlay")
                .font(.callout)
                .fontWeight(.medium)
            Text("JSON object deep-merged into TBD's --settings overlay when Claude spawns in this repo (fresh, resume, wake). Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )

            HStack {
                HStack(spacing: 4) {
                    Text(filePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(filePath, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy full path")
                }

                Spacer()

                if showSaved {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button("Save") { save() }
                    .controlSize(.small)
            }
        }
        .onAppear {
            text = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(atPath: filePath)
        } else {
            let dir = (filePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? trimmed.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
        withAnimation(.easeInOut(duration: 0.3)) { showSaved = true }
        Task {
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = false }
        }
    }
}
