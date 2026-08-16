import SwiftUI
import TBDShared

/// Reusable editor for the remote create-param defaults at one level — a
/// repo's own map, or the machine-wide map beneath it.
///
/// Every control is built from the provider's `describe.create_params`, never
/// from a hardcoded field list: the values a field can take are the
/// provider's to declare, and a field TBD has never heard of gets an editor
/// here on the same terms as one it has. The committed map is keyed by the
/// provider's own field names and stored uninterpreted (see
/// `Repo.remoteCreateDefaults`).
///
/// "Unset" is a first-class choice at every level and is spelled out rather
/// than left blank — `Auto (use global)` on a repo, `Auto (provider default)`
/// machine-wide — because the whole point of the level is that it can defer.
struct RemoteCreateDefaultsEditor: View {
    /// Which level is being edited. Only affects how "unset" is labelled and
    /// what the caption says it falls through to.
    enum Scope: Equatable {
        case repo
        case global
    }

    let scope: Scope
    let providers: [RemoteProviderStatus]
    /// The level BELOW this one, used only to show what "Auto" resolves to.
    /// Empty for `.global`, whose next level is the provider's own `default`.
    let inheritedDefaults: [String: String]
    let onSave: ([String: String]) async -> Void

    @State private var values: [String: String]
    /// What was last handed to `onSave`, so `persist()` can stay silent when
    /// nothing actually changed (a text field submitted unedited, a view
    /// disappearing after a picker already saved).
    @State private var persisted: [String: String]

    init(
        scope: Scope,
        providers: [RemoteProviderStatus],
        initial: [String: String],
        inheritedDefaults: [String: String] = [:],
        onSave: @escaping ([String: String]) async -> Void
    ) {
        self.scope = scope
        self.providers = providers
        self.inheritedDefaults = inheritedDefaults
        self.onSave = onSave
        _values = State(initialValue: initial)
        _persisted = State(initialValue: initial)
    }

    /// Providers worth rendering a form for. A provider that has not reported
    /// a `describe` yet, or reported one with no create params, has no fields
    /// to set defaults for — showing an empty section for it would read as a
    /// broken editor rather than an absent form.
    private var editableProviders: [RemoteProviderStatus] {
        providers.filter { !($0.describe?.createParams ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote session defaults")
                .font(.callout)
                .fontWeight(.medium)
            Text(Self.caption(scope: scope))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if editableProviders.isEmpty {
                Text(providers.isEmpty
                     ? "No remote provider is registered."
                     : "No registered provider has reported a create form yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(editableProviders, id: \.config.name) { provider in
                    providerSection(provider)
                }
            }
        }
        // A text edit the user navigated away from without pressing Return is
        // still an edit they made. Closing Settings or switching repos tears
        // this view down, so catch it here rather than losing it.
        .onDisappear { persist() }
    }

    @ViewBuilder
    private func providerSection(_ provider: RemoteProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editableProviders.count > 1 {
                Text(provider.describe?.name ?? provider.config.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            ForEach(provider.describe?.createParams ?? [], id: \.name) { field in
                fieldRow(field)
            }
        }
    }

    /// One field's control. `enum` and `bool` have closed answer sets, so both
    /// lower to a picker whose first entry is the explicit unset choice; every
    /// other type takes free text, where blank IS unset and the placeholder
    /// carries what blank resolves to.
    @ViewBuilder
    private func fieldRow(_ field: ProviderCreateParamField) -> some View {
        let label = field.label ?? field.name
        switch field.type {
        case "enum":
            Picker(label, selection: immediateBinding(for: field.name)) {
                Text(autoLabel(for: field)).tag("")
                ForEach(field.values ?? [], id: \.self) { value in
                    Text(value).tag(value)
                }
            }
            .pickerStyle(.menu)
        case "bool":
            Picker(label, selection: immediateBinding(for: field.name)) {
                Text(autoLabel(for: field)).tag("")
                Text("On").tag("true")
                Text("Off").tag("false")
            }
            .pickerStyle(.menu)
        default:
            HStack {
                Text(label)
                TextField(autoLabel(for: field), text: draftBinding(for: field.name))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { persist() }
            }
        }
    }

    /// A picker selection is the whole gesture, so it writes straight through —
    /// the macOS convention, and there is no half-entered state a Save button
    /// would be protecting.
    private func immediateBinding(for fieldName: String) -> Binding<String> {
        Binding(
            get: { values[fieldName] ?? "" },
            set: { newValue in
                values = Self.updating(values, field: fieldName, to: newValue)
                persist()
            }
        )
    }

    /// A text field's gesture is not finished on each keystroke, so typing
    /// only updates local state; `persist()` runs on Return or on teardown.
    /// Saving per keystroke would put one RPC on the wire per character.
    private func draftBinding(for fieldName: String) -> Binding<String> {
        Binding(
            get: { values[fieldName] ?? "" },
            set: { values = Self.updating(values, field: fieldName, to: $0) }
        )
    }

    private func persist() {
        guard values != persisted else { return }
        let committed = values
        persisted = committed
        Task { await onSave(committed) }
    }

    private func autoLabel(for field: ProviderCreateParamField) -> String {
        Self.autoLabel(field: field, scope: scope, inheritedDefaults: inheritedDefaults)
    }

    // MARK: - Pure helpers

    /// Apply one field's new value. A blank value REMOVES the key rather than
    /// storing `""` — "no opinion" is the absence of an entry, and a level
    /// holding an empty string would otherwise be a second spelling of the
    /// same state that a reader has to know to collapse.
    nonisolated static func updating(
        _ values: [String: String], field: String, to newValue: String
    ) -> [String: String] {
        var next = values
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next.removeValue(forKey: field)
        } else {
            next[field] = newValue
        }
        return next
    }

    /// How the unset choice reads, including what it actually resolves to when
    /// the level below has an answer — so "Auto" is never a blank the user has
    /// to go and look up.
    nonisolated static func autoLabel(
        field: ProviderCreateParamField,
        scope: Scope,
        inheritedDefaults: [String: String]
    ) -> String {
        let base = scope == .repo ? "Auto (use global)" : "Auto (provider default)"
        let resolved = RemoteCreateFormLogic.resolveString(
            field: field, repoPrefill: nil, repoDefaults: [:],
            globalDefaults: inheritedDefaults, generatedSlug: nil)
        return resolved.isEmpty ? base : "\(base) — \(resolved)"
    }

    nonisolated static func caption(scope: Scope) -> String {
        switch scope {
        case .repo:
            return "Applied when starting a remote session in this repo. "
                + "Anything left on Auto falls through to the global defaults, then to the provider's own."
        case .global:
            return "Applied when starting a remote session in any repo that has not set its own. "
                + "Anything left on Auto falls through to the provider's own default."
        }
    }
}
