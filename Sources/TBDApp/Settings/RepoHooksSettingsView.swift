import SwiftUI
import TBDShared

struct RepoHooksSettingsView: View {
    let repoID: UUID

    @State private var preSessionDraft: String = ""
    @State private var setupDraft: String = ""
    @State private var archiveDraft: String = ""
    @State private var preSessionSaved = false
    @State private var setupSaved = false
    @State private var archiveSaved = false

    private var preSessionPath: String { TBDConstants.hookPath(repoID: repoID, eventName: "preSession") }
    private var setupPath: String { TBDConstants.hookPath(repoID: repoID, eventName: "setup") }
    private var archivePath: String { TBDConstants.hookPath(repoID: repoID, eventName: "archive") }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            hookSection(
                title: "Pre-session hook",
                description: "Runs in a visible terminal when a new worktree is created, and blocks "
                    + "the agent (Claude/Codex) from starting until it finishes. Use for setup the agent "
                    + "must not run without — copying env files, installing dependencies. Times out after "
                    + "10 minutes; on failure the agent starts anyway.",
                draft: $preSessionDraft,
                filePath: preSessionPath,
                showSaved: $preSessionSaved
            )

            Divider()

            hookSection(
                title: "Setup hook",
                description: "Runs in parallel alongside the agent when a new worktree is created. "
                    + "Does not block the agent from starting.",
                draft: $setupDraft,
                filePath: setupPath,
                showSaved: $setupSaved
            )

            Divider()

            hookSection(
                title: "Archive hook",
                description: "Runs before a worktree is archived. Must complete within 60 seconds.",
                draft: $archiveDraft,
                filePath: archivePath,
                showSaved: $archiveSaved
            )
        }
        .onAppear {
            preSessionDraft = readHook(at: preSessionPath)
            setupDraft = readHook(at: setupPath)
            archiveDraft = readHook(at: archivePath)
        }
    }

    @ViewBuilder
    private func hookSection(
        title: String,
        description: String,
        draft: Binding<String>,
        filePath: String,
        showSaved: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .fontWeight(.medium)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: draft)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                if draft.wrappedValue.isEmpty {
                    Text("e.g. npm install && brew bundle")
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

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

                if showSaved.wrappedValue {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button("Save") {
                    writeHook(content: draft.wrappedValue, to: filePath)
                    withAnimation(.easeInOut(duration: 0.3)) { showSaved.wrappedValue = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeInOut(duration: 0.3)) { showSaved.wrappedValue = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func readHook(at path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func writeHook(content: String, to path: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
