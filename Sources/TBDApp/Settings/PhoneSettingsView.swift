import AppKit
import SwiftUI
import TBDShared

/// Settings → Phone: the phone control switch, the relay, the paired phones
/// and the loader URL (`docs/specs/2026-11-07-phone-control-design.md`,
/// section 10).
///
/// Everything it shows comes from `AppState.phoneStatus` and
/// `AppState.phoneDevices`. It refreshes both when it appears, because the
/// daemon answers the phone RPCs only for the TBD app and may refuse the
/// first read while the app is still starting.
struct PhoneSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var showPairing = false
    @State private var showRelaySetup = false
    @State private var deviceToRevoke: PhonePresentation.DeviceRow?
    @State private var deviceRows: [PhonePresentation.DeviceRow] = []
    @State private var loaderURLDraft = ""
    @State private var loaderURLError: String?
    @State private var isSavingLoaderURL = false

    var body: some View {
        Form {
            controlSection
            relaySection
            phonesSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding()
        .task { await appState.refreshPhone() }
        .onChange(of: appState.phoneDevices, initial: true) { rebuildDeviceRows() }
        .onChange(of: appState.phoneStatus?.connectedDeviceIDs) { rebuildDeviceRows() }
        .onChange(of: appState.phoneStatus?.loaderURLOverride, initial: true) { _, override in
            loaderURLDraft = override ?? ""
        }
        .onChange(of: appState.phoneRelaySetupRequested, initial: true) { _, requested in
            guard requested else { return }
            appState.phoneRelaySetupRequested = false
            showRelaySetup = true
        }
        .confirmationDialog(
            deviceToRevoke.map { PhonePresentation.revokeTitle(name: $0.name) } ?? "",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }),
            titleVisibility: .visible,
            presenting: deviceToRevoke
        ) { row in
            Button("Revoke", role: .destructive) {
                Task { await appState.revokePhone(deviceID: row.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(PhonePresentation.revokeMessage)
        }
        .sheet(isPresented: $showPairing) {
            PhonePairingSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showRelaySetup) {
            PhoneRelaySetupSheet()
                .environment(appState)
        }
    }

    // MARK: - Phone control

    private var controlSection: some View {
        Section("Phone control") {
            Toggle("Control this laptop from a paired phone", isOn: Binding(
                get: { appState.phoneStatus?.enabled ?? Config.phoneControlEnabledDefault },
                set: { newValue in Task { await appState.setPhoneControlEnabled(newValue) } }
            ))
            .disabled(appState.phoneStatus == nil)
            .help("A paired phone reaches this laptop through your own relay, end-to-end encrypted. Off by default.")
            if let problem = appState.phoneStatus?.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appState.phoneStatusError {
                HStack(alignment: .firstTextBaseline) {
                    Text(PhonePresentation.statusErrorLine(error))
                        .font(.caption)
                        .foregroundStyle(appState.phoneStatus == nil ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again") {
                        Task { await appState.refreshPhone() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Relay

    private var relaySection: some View {
        Section("Relay") {
            LabeledContent("Address") {
                Text(appState.phoneStatus?.relayURL ?? "Not set up")
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let status = appState.phoneStatus, let line = PhonePresentation.relayLine(for: status) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(status.relay.state == .incompatible ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.relay.state == .incompatible {
                    Link("Read the Guide", destination: PhonePresentation.guideURL)
                        .font(.caption)
                } else if status.relay.state == .updateAvailable {
                    Link("How to update", destination: PhonePresentation.guideURL)
                        .font(.caption)
                }
            }
            HStack {
                Spacer()
                Button("Set Up Phone Relay…") { showRelaySetup = true }
                    .disabled(appState.phoneStatus == nil)
            }
        }
    }

    // MARK: - Phones

    private var phonesSection: some View {
        Section("Phones") {
            if deviceRows.isEmpty {
                Text("No phones are paired.")
                    .foregroundStyle(.secondary)
            }
            ForEach(deviceRows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text("\(row.pairedText) · \(row.seenText)")
                            .font(.caption)
                            .foregroundStyle(row.isConnected ? Color(nsColor: .systemGreen) : Color.secondary)
                    }
                    Spacer()
                    Button("Revoke…") { deviceToRevoke = row }
                }
            }
            HStack {
                Spacer()
                Button("Pair a Phone…") { showPairing = true }
                    .disabled(!PhonePresentation.canPair(appState.phoneStatus))
                    .help(PhonePresentation.pairDisabledReason(appState.phoneStatus) ?? "Show a QR code to scan with your phone.")
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                TextField("Loader URL", text: $loaderURLDraft, prompt: Text(Config.phoneLoaderURLDefault))
                    .onSubmit { saveLoaderURL() }
                    .disabled(appState.phoneStatus == nil || isSavingLoaderURL)
                    .help("The page your phone opens from the QR code. Leave blank for the default. Press Return to save.")
                if let loaderURLError {
                    Text(loaderURLError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Actions

    private func rebuildDeviceRows() {
        let rows = PhonePresentation.deviceRows(
            appState.phoneDevices, connected: Set(appState.phoneStatus?.connectedDeviceIDs ?? []))
        if rows != deviceRows { deviceRows = rows }
    }

    /// Saves the loader URL as typed; blank goes back to the default.
    private func saveLoaderURL() {
        let draft = loaderURLDraft
        isSavingLoaderURL = true
        loaderURLError = nil
        Task {
            loaderURLError = await appState.setPhoneLoaderURL(draft)
            isSavingLoaderURL = false
        }
    }
}
