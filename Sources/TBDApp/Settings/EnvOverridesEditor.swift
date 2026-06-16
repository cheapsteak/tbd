import SwiftUI

/// Reusable key/value editor for free-form environment overrides applied to
/// spawned Claude/Codex sessions. Presentation-only: it owns the in-progress
/// row state and hands the committed `[String: String]` back through `onSave`;
/// the caller persists it (e.g. an RPC-backed `AppState` action). Modeled on
/// `FallbackModelsEditor`. No validation/denylist/secret handling — values are
/// free-form by design.
struct EnvOverridesEditor: View {
    /// Scope-specific precedence note shown under the title.
    let caption: String
    /// Hands the committed overrides to the caller for persistence.
    let onSave: ([String: String]) async -> Void

    @State private var rows: [Row]
    @State private var isSaving = false
    @State private var showSaved = false

    private struct Row: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(
        initial: [String: String],
        caption: String,
        onSave: @escaping ([String: String]) async -> Void
    ) {
        self.caption = caption
        self.onSave = onSave
        _rows = State(initialValue: initial
            .sorted { $0.key < $1.key }
            .map { Row(key: $0.key, value: $0.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environment overrides")
                .font(.callout)
                .fontWeight(.medium)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach($rows) { $row in
                    HStack(spacing: 6) {
                        TextField("KEY", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Text("=")
                            .foregroundStyle(.secondary)
                        TextField("VALUE", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this variable")
                    }
                }

                HStack {
                    Button {
                        rows.append(Row(key: "", value: ""))
                    } label: {
                        Label("Add variable", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Spacer()

                    if showSaved {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }

                    Button("Save") { save() }
                        .controlSize(.small)
                        .disabled(isSaving)
                }
            }
        }
    }

    /// Map non-empty-key rows back to a dict (last duplicate key wins). Keys are
    /// trimmed; values are kept verbatim.
    private func committedOverrides() -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = row.value
        }
        return result
    }

    private func save() {
        isSaving = true
        let overrides = committedOverrides()
        Task {
            await onSave(overrides)
            // Reseed the displayed rows from the deduped map so duplicate-key
            // rows collapse to match what was persisted, using the same
            // sort/Row construction as the initializer for stable order.
            rows = overrides.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
            isSaving = false
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = false }
        }
    }
}
