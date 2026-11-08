import AppKit
import SwiftUI
import TBDShared

/// The sheet "Pair a Phone…" opens (`docs/specs/2026-11-07-phone-control-design.md`,
/// sections 2 and 10). It starts an offer when it appears and follows that
/// offer through `AppState.phoneStatus`:
///
/// - **Waiting for a phone:** the QR code, the link with a Copy button, and
///   the time left.
/// - **Awaiting approval:** the phone finished the handshake and its first
///   encrypted message decrypted, so the sheet asks to Allow it by name and
///   code.
/// - **Paired, or ended:** what happened, with Start Again where it helps.
///
/// When Allow or Deny fails, the daemon's reason shows above the buttons.
///
/// Closing the sheet while the offer is live denies it, so a code nobody is
/// looking at never stays open. That holds while the offer is still starting
/// too: an offer that finishes starting after the sheet has gone is denied by
/// its ID.
struct PhonePairingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case starting
        /// The offer this sheet started, as `phone.pairStart` returned it.
        case started(PhonePairingStatus)
        case failed(String)
    }

    @State private var phase: Phase = .starting
    /// Closed when the sheet goes away, so an offer still starting then is
    /// denied.
    @State private var request = PhonePairingRequest()
    /// The QR code for the current link, rendered when the link changes.
    @State private var qrImage: NSImage?
    @State private var isActing = false
    /// Set once this sheet has denied its offer, so it never denies twice.
    @State private var didDeny = false

    /// The widest the QR code is drawn, in points.
    private static let qrMaxSide: CGFloat = 340

    /// The offer this sheet started, as the daemon last reported it, or as
    /// `phone.pairStart` returned it while there is no status yet. Nil before
    /// it starts, and once the daemon reports no offer or another one.
    private var pairing: PhonePairingStatus? {
        guard case .started(let offer) = phase else { return nil }
        return PhonePresentation.sheetPairing(started: offer, status: appState.phoneStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair a Phone")
                .font(.headline)
            content
        }
        .padding(20)
        .frame(width: 440)
        .task { await start() }
        .onChange(of: pairing?.link, initial: true) { _, link in
            qrImage = link.flatMap { PhoneQRCode.image(for: $0) }
        }
        .onDisappear { close() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            endedButtons
        case .started:
            if let pairing {
                offerView(pairing)
            } else {
                Text(PhonePresentation.endedSentence(.unknown))
                actionErrorLine
                endedButtons
            }
        }
    }

    @ViewBuilder
    private func offerView(_ pairing: PhonePairingStatus) -> some View {
        switch pairing.state {
        case .waitingForPhone:
            Text("Scan this code with your phone's camera, or open the link on your phone.")
                .fixedSize(horizontal: false, vertical: true)
            if let qrImage {
                HStack {
                    Spacer()
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(qrImage.size.width / 2, Self.qrMaxSide))
                        .accessibilityLabel("Pairing QR code")
                    Spacer()
                }
            }
            if let link = pairing.link {
                HStack(alignment: .firstTextBaseline) {
                    Text(link)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy") { copy(link) }
                        .controlSize(.small)
                }
            }
            countdown(until: pairing.expiresAt)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .awaitingApproval:
            Text(PhonePresentation.approvalPrompt(
                name: pairing.deviceName ?? "a new phone", code: pairing.confirmationCode ?? ""))
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Allow it only if your phone shows the same code.")
                .foregroundStyle(.secondary)
            countdown(until: pairing.expiresAt)
            actionErrorLine
            HStack {
                Spacer()
                Button("Deny") { deny() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isActing)
                Button("Allow") { allow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isActing)
            }
        case .paired:
            Text("Paired with \(pairing.deviceName ?? "your phone").")
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        case .denied, .expired, .interrupted, .unknown:
            Text(PhonePresentation.endedSentence(pairing.state))
                .fixedSize(horizontal: false, vertical: true)
            actionErrorLine
            endedButtons
        }
    }

    /// Why the last Allow or Deny failed, in the daemon's words, which are
    /// written to be shown as they stand. An Allow that fails can also end
    /// the offer, so the ended states show it too.
    @ViewBuilder
    private var actionErrorLine: some View {
        if let error = appState.phonePairingError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endedButtons: some View {
        HStack {
            Spacer()
            Button("Start Again") {
                Task { await start() }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The time the offer has left, updated every second.
    private func countdown(until expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Expires in \(PhonePresentation.countdown(remaining: expiresAt.timeIntervalSince(context.date)))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func start() async {
        phase = .starting
        didDeny = false
        switch await appState.startPhonePairing(for: request) {
        case .started(let offer):
            phase = .started(offer)
        case .failed(let failure):
            phase = .failed(failure)
        case .abandoned:
            // The sheet has gone, and the offer was denied.
            return
        }
    }

    /// Allows this sheet's own offer, the one whose name and code it shows,
    /// never whatever offer the daemon reports by the time the call runs.
    private func allow() {
        guard case .started(let offer) = phase else { return }
        let offerID = offer.offerID
        isActing = true
        Task {
            await appState.allowPhonePairing(offerID: offerID)
            isActing = false
        }
    }

    /// Denies this sheet's own offer, never a newer one.
    private func deny() {
        guard case .started(let offer) = phase else { return }
        let offerID = offer.offerID
        isActing = true
        didDeny = true
        Task {
            await appState.denyPhonePairing(offerID: offerID)
            isActing = false
        }
    }

    private func cancel() {
        close()
        dismiss()
    }

    /// The sheet is going away: an offer still starting is denied once it
    /// has started, and a live one now, unless it is denied already. The ID
    /// is taken now: by the time the call runs, the daemon may report a newer
    /// offer, which this sheet never showed.
    private func close() {
        request.close()
        guard !didDeny, case .started(let offer) = phase,
              let offerID = PhonePresentation.offerToDeny(started: offer, status: appState.phoneStatus) else { return }
        didDeny = true
        Task { await appState.denyPhonePairing(offerID: offerID) }
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}
