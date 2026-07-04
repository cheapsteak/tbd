import SwiftUI
import TBDShared

/// Spawn-time account picker: the sheet shown when the user clicks the plain
/// "Claude" action (unless "Use default without asking" is on) or the
/// "Choose account…" item in the "+" menu.
///
/// Lists every model profile with full usage data — identity, 5h window bar +
/// reset time, weekly-all bar, per-family bars — sorted
/// healthiest-session-window first (display order only; nothing is
/// auto-picked). Cached snapshots render immediately; a forced daemon-side
/// usage sweep runs on open and updates rows in place ("refreshing…", never a
/// blocking spinner). Selecting a row spawns a Claude session pinned to that
/// profile for life.
struct AccountPickerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Called with the chosen profile id; the caller owns the actual spawn.
    let onPick: (UUID) -> Void

    @State private var isRefreshing = false

    private var sortedEntries: [ModelProfileWithUsage] {
        ProfileUsagePresentation.sortedForPicker(appState.modelProfiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if sortedEntries.isEmpty {
                Text("No model profiles configured — add one in Settings → Model Profiles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sortedEntries, id: \.profile.id) { entry in
                            AccountPickerRow(
                                entry: entry,
                                isDefault: entry.profile.id == appState.defaultProfileID,
                                onPick: {
                                    onPick(entry.profile.id)
                                    dismiss()
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 380)
            }

            Divider()

            HStack {
                Toggle("Use default without asking", isOn: $appState.skipAccountPicker)
                    .font(.caption)
                    .help("Skip this dialog: plain Claude spawns on the global default profile. Toggle back here or in Settings → Model Profiles.")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            // Decision-grade data: force a sweep on open. Cached rows are
            // already on screen; fresh snapshots merge in when they land.
            isRefreshing = true
            await appState.refreshUsageSnapshots()
            isRefreshing = false
        }
    }

    private var header: some View {
        HStack {
            Text("Choose account for Claude")
                .font(.headline)
            Spacer()
            if isRefreshing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("refreshing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Row

private struct AccountPickerRow: View {
    let entry: ModelProfileWithUsage
    let isDefault: Bool
    let onPick: () -> Void

    @State private var isHovering = false

    private var isSelectable: Bool {
        ProfileUsagePresentation.isSelectable(entry)
    }

    private var identityText: String? {
        if ProfileLoginPresentation.needsLogin(kind: entry.profile.kind,
                                               loginIdentity: entry.loginIdentity) {
            return "not logged in — run /login first"
        }
        return ProfileLoginPresentation.normalizedIdentity(entry.loginIdentity)
    }

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.profile.name)
                        .font(.system(size: 13, weight: .medium))
                    if isDefault {
                        Text("default")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                    if let identityText {
                        Text(identityText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                if let snapshot = entry.usageSnapshot, !snapshot.buckets.isEmpty {
                    bucketRows(snapshot)
                } else if isSelectable {
                    Text("No usage data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let note = ProfileUsagePresentation.stalenessNote(for: entry.usageSnapshot) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering && isSelectable
                          ? Color.primary.opacity(0.06)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .opacity(isSelectable ? 1 : 0.5)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func bucketRows(_ snapshot: ProfileUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let session = ProfileUsagePresentation.sessionBucket(snapshot) {
                bucketRow(label: "5h", bucket: session, showsReset: true)
            }
            if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
                bucketRow(label: "week", bucket: weekly, showsReset: false)
            }
            ForEach(Array(ProfileUsagePresentation.scopedBuckets(snapshot).enumerated()),
                    id: \.offset) { _, scoped in
                bucketRow(label: scoped.modelDisplayName ?? "model",
                          bucket: scoped, showsReset: false)
            }
        }
    }

    private func bucketRow(label: String, bucket: ClaudeUsageLimitBucket,
                           showsReset: Bool) -> some View {
        let level = ProfileUsagePresentation.severityLevel(
            severity: bucket.severity, percent: bucket.percent
        )
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            ProgressView(value: min(max(bucket.percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(level.color)
                .frame(width: 140)
            Text(ProfileUsagePresentation.percentText(bucket.percent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(level == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(level.color))
                .frame(width: 38, alignment: .trailing)
            if showsReset, let resets = bucket.resetsAt {
                Text("resets \(ProfileUsagePresentation.resetTimeText(resets))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Severity color

extension ProfileUsagePresentation.SeverityLevel {
    /// Bar/percent tint per severity tier.
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
