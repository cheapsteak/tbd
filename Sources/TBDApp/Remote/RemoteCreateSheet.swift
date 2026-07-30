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
/// was clicked from instead of landing unmatched).
struct RemoteCreateSheet: View {
    let provider: RemoteProviderConfig
    let describe: ProviderDescribe?
    var repoPrefill: String?

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
            Text("New \(describe?.name ?? provider.name) session")
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
            stringValues = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: repoPrefill)
            boolValues = RemoteCreateFormLogic.prefillBools(fields: fields)
        }
    }

    // MARK: - Field rendering

    /// `field.type` dispatch — deliberately dumb per the contract's own
    /// framing: the most complex widget is an enum dropdown, everything else
    /// (including any future/unknown type) falls back to a plain text field.
    @ViewBuilder
    private func fieldRow(_ field: ProviderCreateParamField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case "text":
                Text(fieldLabel(field)).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: stringBinding(field.name))
                    .font(.body)
                    .frame(height: 80)
                    .overlay(fieldBorder(field.name))
            case "bool":
                Toggle(fieldLabel(field), isOn: boolBinding(field.name))
            case "int":
                TextField(fieldLabel(field), text: stringBinding(field.name))
                    .textFieldStyle(.roundedBorder)
                    .overlay(fieldBorder(field.name))
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
                // "string" and any unrecognized future type.
                TextField(fieldLabel(field), text: stringBinding(field.name))
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
                _ = try await appState.daemonClient.remoteCreate(provider: provider.name, paramsJSON: paramsJSON)
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
