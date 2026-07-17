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
    @Environment(\.colorScheme) private var colorScheme

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
                bucketRow(presentation: ProfileUsagePresentation.bucketPresentation(session), label: "5h")
            }
            if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
                bucketRow(presentation: ProfileUsagePresentation.bucketPresentation(weekly), label: "week")
            }
            ForEach(Array(ProfileUsagePresentation.scopedBuckets(snapshot).enumerated()),
                    id: \.offset) { _, scoped in
                bucketRow(presentation: ProfileUsagePresentation.bucketPresentation(scoped),
                          label: scoped.modelDisplayName ?? "model")
            }
        }
    }

    private func bucketRow(presentation: ProfileUsagePresentation.BucketPresentation,
                           label: String) -> some View {
        let fillColor = presentation.fill.barColor(colorScheme)
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            ProgressView(value: min(max(presentation.percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(fillColor)
                .frame(width: 140)
            Text(presentation.percentText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(presentation.fill == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(fillColor))
                .frame(width: 38, alignment: .trailing)
            if presentation.resetDisplay != .tooltipOnly, let resetPhrase = presentation.resetPhrase {
                Text(resetPhrase)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
