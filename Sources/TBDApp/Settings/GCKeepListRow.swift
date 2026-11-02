import AppKit
import SwiftUI
import TBDShared

/// Settings → Cleanup row for the orphan-process sweep's keep-list file.
/// Reads and writes the file directly (no RPC), like the hook editors.
struct GCKeepListRow: View {
    @State private var loaded: GCKeepList.Loaded = GCKeepList.load(path: TBDConstants.gcKeepProcessesPath)
    @State private var errorText: String?

    private var path: String { TBDConstants.gcKeepProcessesPath }

    /// Customize is available only while the file is absent.
    nonisolated static func canCustomize(_ loaded: GCKeepList.Loaded) -> Bool {
        if case .list(_, .shippedDefaults) = loaded { return true }
        return false
    }

    /// One short sentence about the state of the list.
    nonisolated static func caption(for loaded: GCKeepList.Loaded) -> String {
        switch loaded {
        case .list(_, .shippedDefaults):
            return "Using the shipped list. Customize writes it to a file you can edit."
        case .list(let list, .file):
            return "Using your file. \(list.patterns.count) pattern(s). TBD never rewrites it."
        case .unreadable(let reason):
            return "Cannot read the file (\(reason)). Orphan-process cleanup is skipped until it can be read."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Processes to never reclaim")
                Spacer()
                Button("Customize") { customize() }
                    .disabled(!Self.canCustomize(loaded))
                    .help("Write the shipped list to the file below so you can edit it. An existing file is never overwritten.")
            }
            HStack(spacing: 4) {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy full path")
            }
            Text(errorText ?? Self.caption(for: loaded))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        loaded = GCKeepList.load(path: path)
    }

    private func customize() {
        do {
            try GCKeepList.customize(path: path)
            errorText = nil
        } catch {
            errorText = "Could not write the file: \(error.localizedDescription)"
        }
        refresh()
    }
}
