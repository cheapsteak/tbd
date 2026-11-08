import AppKit
import SwiftUI
import TBDShared

/// "Set Up Phone Relay…": the steps to deploy a relay, and the field that
/// saves its address (`docs/specs/2026-11-07-phone-control-design.md`,
/// section 10). The daemon checks the relay before it saves it, and its
/// reason shows here when it refuses.
struct PhoneRelaySetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var urlDraft = ""
    @State private var isChecking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Phone Relay")
                .font(.headline)
            Text("The relay passes encrypted messages between this laptop and your phone. You run your own, on Cloudflare's free plan.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(PhonePresentation.relaySetupSteps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
            }
            HStack {
                Button("Open Deploy Page") { NSWorkspace.shared.open(PhonePresentation.deployURL) }
                Button("Read the Guide") { NSWorkspace.shared.open(PhonePresentation.guideURL) }
            }
            TextField("Relay address", text: $urlDraft, prompt: Text("https://tbd-relay.acme.workers.dev"))
                .onSubmit { save() }
                .disabled(isChecking)
            if isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                }
            }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if appState.phoneStatus?.relayURL != nil {
                    Button("Remove Relay", role: .destructive) { remove() }
                        .disabled(isChecking)
                }
                Spacer()
                // The check cannot be called off, so a Cancel during it would
                // close the sheet and the save would still land. The daemon
                // bounds the check, so the wait is short.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isChecking)
                Button("Check and Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking || AppState.nonBlankPhoneURL(urlDraft) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { urlDraft = appState.phoneStatus?.relayURL ?? "" }
    }

    /// Checks and saves the address as typed, and closes on success.
    private func save() {
        guard !isChecking, AppState.nonBlankPhoneURL(urlDraft) != nil else { return }
        submit(urlDraft)
    }

    /// Removes the relay, and closes on success.
    private func remove() {
        guard !isChecking else { return }
        submit(nil)
    }

    private func submit(_ url: String?) {
        isChecking = true
        errorText = nil
        Task {
            let failure = await appState.setPhoneRelayURL(url)
            isChecking = false
            if let failure {
                errorText = failure
            } else {
                dismiss()
            }
        }
    }
}
