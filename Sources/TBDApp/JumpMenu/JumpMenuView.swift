import SwiftUI

struct JumpMenuView: View {
    @ObservedObject var viewModel: JumpMenuViewModel
    let onSubmit: (JumpMenuRow) -> Void
    let onCancel: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            list
        }
        .frame(width: 440)
        .background(
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Jump to worktree…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.resetSelection()
                }
                .onKeyPress(.downArrow) {
                    viewModel.moveSelectionDown()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    viewModel.moveSelectionUp()
                    return .handled
                }
                .onKeyPress(.return) {
                    if let row = viewModel.selectedRow {
                        onSubmit(row)
                    } else {
                        onCancel()
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
        }
    }

    @ViewBuilder
    private var list: some View {
        let rows = viewModel.rows
        if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            sectionHeaderIfNeeded(rows: rows, index: idx)
                            JumpMenuRowView(
                                row: row,
                                isSelected: idx == viewModel.selectedIndex,
                                showTimestamp: viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty
                            )
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSubmit(row)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
                .onChange(of: viewModel.selectedIndex) { _, newIndex in
                    guard newIndex < rows.count else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(rows[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeaderIfNeeded(rows: [JumpMenuRow], index: Int) -> some View {
        let prevSection: JumpMenuRow.Section? = index > 0 ? rows[index - 1].section : nil
        let section = rows[index].section
        // Skip section headers entirely while the user is filtering — the
        // typed-query mode is one flat ranked list.
        if section != .match, section != prevSection {
            Text(section == .unread ? "UNREAD" : "RECENT")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, index == 0 ? 4 : 8)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        let trimmed = viewModel.query.trimmingCharacters(in: .whitespaces)
        let message = trimmed.isEmpty ? "No recent activity" : "No matching worktrees"
        return Text(message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}

/// AppKit visual-effect bridge so the panel picks up the system menu material.
private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
