import SwiftUI
import TBDShared

/// "Reclaimed" collapsed section rendered at the bottom of
/// `ArchivedWorktreesView`'s leftRail, below the archived-worktree List.
/// Shows orphan-GC's reap history for the repo (Task 12) — hand-rolled
/// disclosure per `FileStatusSection` (FileViewer/FileViewerPanel.swift
/// ~259-301), collapsed by default. Caller renders this only when
/// `appState.reapRecords[repoID]` is non-empty.
struct ReclaimedSectionView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var isExpanded = false

    /// Single SF Symbol used everywhere GC/reclaim needs a glyph — header,
    /// row icon, scratchpad rollup row. Keep this the only place it's picked.
    static let glyph = "arrow.3.trianglepath"

    private var summary: ReclaimedSummary {
        ReclaimedSummary(records: appState.reapRecords[repoID] ?? [])
    }

    private var selectedReapRecordID: UUID? {
        appState.selectedReapRecordIDs[repoID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(summary.agentRecords) { record in
                        ReclaimedRow(record: record, isSelected: selectedReapRecordID == record.id)
                            .contentShape(Rectangle())
                            .onTapGesture { select(record) }
                    }
                    if let rollup = summary.scratchpadRollup {
                        scratchpadRow(rollup)
                    }
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: Self.glyph)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("RECLAIMED")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                let unrestored = summary.unrestored
                Text("(\(unrestored.count) · \(Self.byteString(unrestored.totalApparentBytes)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scratchpadRow(_ rollup: (count: Int, bytes: Int64)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.glyph)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(rollup.count) scratchpad\(rollup.count == 1 ? "" : "s") cleaned · \(Self.byteString(rollup.bytes))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Selecting a reap row is mutually exclusive with the archived-row
    /// selection above it — clear the archived selection so the right pane
    /// unambiguously shows this record's detail.
    private func select(_ record: ReapRecord) {
        appState.selectReapRecord(record.id, repoID: repoID)
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Row

private struct ReclaimedRow: View {
    let record: ReapRecord
    let isSelected: Bool

    /// Restored records stay in the list (audit trail) but are no longer
    /// reclaimed disk — dim the row a step and swap the reaped-at date for
    /// a "Restored <date>" label so they're visually distinct.
    private var isRestored: Bool { record.restoredAt != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ReclaimedSectionView.glyph)
                .font(.caption2)
                .foregroundStyle(isRestored ? .tertiary : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(basename)
                    .font(.callout)
                    .foregroundStyle(isRestored ? .tertiary : .secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let branch = record.branch {
                        Text("branch \(branch) kept")
                        separator
                    }
                    Text("\(ReclaimedSectionView.byteString(record.apparentBytes ?? 0)) (apparent)")
                    if record.snapshotRef != nil {
                        separator
                        Text("snapshot ✓")
                    }
                    Spacer(minLength: 6)
                    if let restoredAt = record.restoredAt {
                        Text("Restored \(restoredAt, format: .relative(presentation: .named))")
                            .lineLimit(1)
                    } else {
                        Text(record.reapedAt, format: .relative(presentation: .named))
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(isRestored ? .quaternary : .tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary).font(.caption2)
    }

    private var basename: String {
        URL(fileURLWithPath: record.worktreePath).lastPathComponent
    }
}

// MARK: - Detail pane

/// Right-pane detail for a selected reap record — mirrors the "select an
/// archived worktree" detail shell but for a `ReapRecord`. Restore button
/// mirrors the revive-button error handling (`AppState.restoreReap` already
/// catches and calls `showAlert`, per `AppState+Worktrees.swift:608-619`).
struct ReclaimedDetailView: View {
    let record: ReapRecord
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: ReclaimedSectionView.glyph)
                    .foregroundStyle(.secondary)
                Text(basename)
                    .font(.title3)
                    .fontWeight(.medium)
            }

            detailRow("Path", record.worktreePath)
            if let branch = record.branch {
                detailRow("Branch", branch)
            }
            detailRow("Reaped", record.reapedAt.formatted(.relative(presentation: .named)))
            detailRow("Size", "\(ReclaimedSectionView.byteString(record.apparentBytes ?? 0)) (apparent)")
            detailRow("Snapshot", record.snapshotRef != nil ? "✓ captured" : "clean (no snapshot)")

            Spacer(minLength: 0)

            if let restoredAt = record.restoredAt {
                Text("Restored \(restoredAt, format: .relative(presentation: .named))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Restore") {
                    Task { await appState.restoreReap(record, repoID: repoID) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private var basename: String {
        URL(fileURLWithPath: record.worktreePath).lastPathComponent
    }
}
