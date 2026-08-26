import SwiftUI
import TBDShared
import os

private let createSheetLogger = Logger(subsystem: "com.tbd.app", category: "remoteCreate")

/// Generic create-session form, rendered entirely from `describe.create_params`
/// (`docs/remote-provider-contract.md` § `describe`). The provider is the
/// validator of record — this sheet only does required/type checks locally
/// (matching the contract's own framing) before submitting, and surfaces
/// whatever message the provider's `create` verb returns on failure.
///
/// Opened from a `+` button in the Remote section's provider header
/// (`RemoteProviderHeaderRow`, no repo context — `repoPrefill: nil`) or from
/// a repo's context menu (`RepoSectionView`, `repoPrefill` derived from that
/// repo's `remoteURL` via `RemoteCreateFormLogic.repoPrefill` — the SAME
/// normalization `RemoteRepoMatching` uses to resolve a session back to a
/// repo, so a session created this way round-trips into the section its `+`
/// was clicked from instead of landing unmatched), or from a worktree row's
/// nested `+` (`WorktreeRowView`, which adds `parentWorktreeID`).
///
/// The two `+` menus reach this sheet only when `RemoteCreateFormLogic.launch`
/// found something it could not answer; when it can answer everything they
/// create outright and this sheet never appears. The repo context menu's "New
/// Remote Session…" is the unconditional way in, and is how you get here to
/// type a prompt or pick a branch on a form that would otherwise have been
/// skipped.
struct RemoteCreateSheet: View {
    let provider: RemoteProviderConfig
    let describe: ProviderDescribe?
    var repoPrefill: String?
    /// The owning repo's stored create-param defaults, or empty when the sheet
    /// was opened without a repo context. The machine-wide map beneath it is
    /// read from `appState` rather than passed, since it has no per-call
    /// variation. Both feed `RemoteCreateFormLogic.plan`, so a form opened
    /// here starts on exactly the values the one-click path would have sent.
    var repoDefaults: [String: String] = [:]
    /// The worktree the new lane should nest under — set only when the sheet
    /// was opened from that worktree's nested `+`. Not a form field and not a
    /// provider parameter: it rides the `remote.create` RPC as a TBD-local
    /// request, and the daemon applies it when it adopts the session. A parent
    /// the parent rules refuse costs the edge, never the session.
    var parentWorktreeID: UUID?
    /// The repo section the optimistic lane row is drawn in while the provider
    /// starts the session, or nil when the sheet was opened with no repo
    /// context (the Remote section's own provider header) — then no row is
    /// drawn and creation behaves exactly as it did before placeholders.
    /// Distinct from `repoPrefill`, which is a create-param value the provider
    /// sees; this one never leaves the app.
    var repoID: UUID?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var stringValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var didInitializeValues = false
    @State private var errorFieldName: String?
    @State private var submitError: String?
    @State private var isSubmitting = false

    private var fields: [ProviderCreateParamField] { describe?.createParams ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The registry key, not `describe.name`: two entries of the same
            // kind report the same kind, and the sheet must say which entry
            // this session will be created under.
            Text("New \(provider.name) session")
                .font(.headline)

            if fields.isEmpty {
                Text(describe == nil
                     ? "This provider hasn't reported its create form yet."
                     : "This provider has no create parameters — Create will start a session with defaults.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(fields, id: \.name) { field in
                            fieldRow(field)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            if let submitError {
                Text(submitError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSubmitting ? "Creating…" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(describe == nil || isSubmitting)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            guard !didInitializeValues else { return }
            didInitializeValues = true
            // Its OWN slug, not one handed down: a sheet only opens when the
            // one-click path declined to create, so no lane has claimed that
            // caller's slug and minting a fresh one costs nothing.
            let plan = RemoteCreateFormLogic.plan(
                fields: fields,
                repoPrefill: repoPrefill,
                repoDefaults: repoDefaults,
                globalDefaults: appState.globalRemoteCreateDefaults,
                generatedSlug: NameGenerator.generate())
            stringValues = plan.stringValues
            boolValues = plan.boolValues
        }
    }

    // MARK: - Field rendering

    /// `field.type` dispatch — deliberately dumb per the contract's own
    /// framing: the most complex widget is an enum dropdown, everything else
    /// (including any future/unknown type) falls back to a plain text field.
    ///
    /// Text-shaped controls get the field's label as a caption ABOVE them —
    /// a `TextField`'s own title argument is only a placeholder, which macOS
    /// hides as soon as the field has content, so a prefilled field would
    /// otherwise render as an unlabeled box. `Toggle`/`Picker` display the
    /// label they're handed, so they carry it themselves and get no caption
    /// (see `RemoteCreateFormLogic.rendersCaptionLabel(forType:)`). The
    /// required `*` marker lives in `fieldLabel` alone, so it appears exactly
    /// once per field either way.
    @ViewBuilder
    private func fieldRow(_ field: ProviderCreateParamField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if RemoteCreateFormLogic.rendersCaptionLabel(forType: field.type) {
                Text(fieldLabel(field)).font(.caption).foregroundStyle(.secondary)
            }
            switch field.type {
            case "text":
                TextEditor(text: stringBinding(field.name))
                    .font(.body)
                    .frame(height: 80)
                    .overlay(fieldBorder(field.name))
            case "bool":
                Toggle(fieldLabel(field), isOn: boolBinding(field.name))
            case "enum":
                Picker(fieldLabel(field), selection: stringBinding(field.name)) {
                    if !field.required {
                        Text("—").tag("")
                    }
                    ForEach(field.values ?? [], id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
            default:
                // "int", "string", and any unrecognized future type. The
                // caption above is the visible label, so the TextField's own
                // title stays empty rather than repeating it as a
                // disappearing placeholder.
                TextField("", text: stringBinding(field.name))
                    .textFieldStyle(.roundedBorder)
                    .overlay(fieldBorder(field.name))
            }
        }
    }

    private func fieldLabel(_ field: ProviderCreateParamField) -> String {
        let base = field.label ?? field.name
        return field.required ? "\(base) *" : base
    }

    @ViewBuilder
    private func fieldBorder(_ fieldName: String) -> some View {
        if errorFieldName == fieldName {
            RoundedRectangle(cornerRadius: 4).stroke(Color.red, lineWidth: 1.5)
        }
    }

    private func stringBinding(_ name: String) -> Binding<String> {
        Binding(get: { stringValues[name] ?? "" }, set: { stringValues[name] = $0 })
    }

    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { boolValues[name] ?? false }, set: { boolValues[name] = $0 })
    }

    // MARK: - Submit

    private func submit() {
        errorFieldName = nil
        submitError = nil
        switch RemoteCreateFormLogic.buildParamsJSON(fields: fields, stringValues: stringValues, boolValues: boolValues) {
        case .failure(.missingRequired(let name)):
            errorFieldName = name
            submitError = "\(labelFor(name)) is required."
        case .failure(.invalidInt(let name)):
            errorFieldName = name
            submitError = "\(labelFor(name)) must be a whole number."
        case .success(let json):
            submitCreate(paramsJSON: json)
        }
    }

    private func labelFor(_ fieldName: String) -> String {
        fields.first(where: { $0.name == fieldName })?.label ?? fieldName
    }

    private func submitCreate(paramsJSON: String) {
        isSubmitting = true
        Task {
            do {
                // Through `AppState` rather than the client directly, so the
                // optimistic lane row is drawn, swapped and — on the failure
                // below — removed by the same path every other create uses.
                // The sheet still stays up until the provider answers: its
                // inline error next to the offending field is a better report
                // than a toast, and it keeps the typed values for a retry.
                _ = try await appState.createRemoteLane(
                    provider: provider.name, paramsJSON: paramsJSON,
                    parentWorktreeID: parentWorktreeID, repoID: repoID)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                submitError = error.localizedDescription
                createSheetLogger.error(
                    "remoteCreate failed for provider=\(provider.name, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}
