import SwiftUI

/// Responsive transcript composition: a reading surface plus a session-local
/// reference index. Wide panes get a quiet trailing rail; narrow panes get one
/// unobtrusive inspector button over the transcript.
struct SessionWorkbenchView<Content: View>: View {
    let sections: [SessionIndexSection]
    let onOpen: (String) -> Void
    @ViewBuilder let content: () -> Content

    @State private var showsInlineRail = true
    @State private var showsInspector = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let mode = SessionIndexDisplayMode.resolve(width: proxy.size.width)
            HStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if mode == .inlineRail, showsInlineRail {
                    Divider()
                    SessionIndexRail(
                        sections: sections,
                        onOpen: onOpen,
                        onClose: { showsInlineRail = false }
                    )
                    .frame(width: 248)
                    .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if mode == .inspector || !showsInlineRail {
                    indexButton(mode: mode)
                        .padding(10)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsInlineRail)
        }
    }

    private var entryCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }

    @ViewBuilder
    private func indexButton(mode: SessionIndexDisplayMode) -> some View {
        Button {
            if mode == .inlineRail {
                showsInlineRail = true
            } else {
                showsInspector = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sidebar.trailing")
                if entryCount > 0 {
                    Text("\(entryCount)")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .help("Show session index")
        .accessibilityLabel("Show session index, \(entryCount) references")
        .popover(isPresented: $showsInspector, arrowEdge: .trailing) {
            SessionIndexRail(
                sections: sections,
                onOpen: { itemID in
                    showsInspector = false
                    onOpen(itemID)
                },
                onClose: { showsInspector = false }
            )
            .frame(width: 280, height: 460)
        }
    }
}

private struct SessionIndexRail: View {
    let sections: [SessionIndexSection]
    let onOpen: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session index")
                    .font(.system(.headline, design: .rounded, weight: .medium))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "sidebar.trailing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Hide session index")
                .accessibilityLabel("Hide session index")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if sections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No durable references yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
    }

    private func sectionView(_ section: SessionIndexSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: section.category.iconSystemName)
                Text(section.category.title.uppercased())
                Spacer()
                Text("\(section.entries.count)")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)

            ForEach(section.entries) { entry in
                Button {
                    onOpen(entry.transcriptItemID)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: section.category.iconSystemName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                                .font(section.category == .changed || section.category == .sources
                                      ? .system(.callout, design: .monospaced)
                                      : .callout)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 4)
                        if entry.count > 1 {
                            Text("\(entry.count)×")
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SessionIndexEntryButtonStyle())
                .help(entry.target)
                .accessibilityLabel(
                    "Open \(section.category.title.lowercased()) \(entry.target)"
                        + (entry.count > 1 ? ", used \(entry.count) times" : "")
                )
            }
        }
    }
}

private struct SessionIndexEntryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055), lineWidth: 1)
            )
    }
}
