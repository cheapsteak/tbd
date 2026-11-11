import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TBDShared

/// The Phone pane's text rules, as pure functions the tests pin
/// (`docs/specs/2026-11-07-phone-control-design.md`, section 10).
enum PhonePresentation {
    /// Cloudflare's Deploy page for the relay in this repository.
    static let deployURL = URL(
        string: "https://deploy.workers.cloudflare.com/?url=https://github.com/cheapsteak/tbd/tree/main/relay/cloudflare")!
    /// The setup guide.
    static let guideURL = URL(string: "https://github.com/cheapsteak/tbd/blob/main/docs/phone-control.md")!

    /// The relay setup sheet's numbered steps.
    static let relaySetupSteps = [
        "Open the Deploy page and sign in to Cloudflare and GitHub",
        "Deploy the relay",
        "Copy its workers.dev address",
        "Paste it below",
    ]

    /// The line under the relay URL for `status`, or nil with no relay set.
    /// The relay's state means something only while the bridge runs: a
    /// stopped bridge checks nothing, so the line says so instead.
    static func relayLine(for status: PhoneStatusResult) -> String? {
        guard status.relayURL != nil else { return nil }
        guard status.running else {
            return status.enabled
                ? "Not checked while phone control is not running"
                : "Not checked while phone control is off"
        }
        return relayLine(status.relay)
    }

    /// The line under the relay URL while the bridge runs.
    static func relayLine(_ relay: PhoneRelayStatus) -> String {
        switch relay.state {
        case .notSetUp:
            return "Not set up"
        case .checking:
            return "Checking…"
        case .connected:
            return relay.version.map { "Connected (relay \($0))" } ?? "Connected"
        case .unreachable:
            return relay.detail.map { "Unreachable: \($0)" } ?? "Unreachable"
        case .incompatible:
            return relay.detail.map { "Not usable: \($0)" } ?? "Not usable"
        case .updateAvailable:
            let version = relay.version ?? "unknown"
            return "Relay update available (relay \(version), this TBD expects \(relay.bundledVersion))"
        case .unknown:
            return "Status unknown"
        }
    }

    /// The loader URL field's placeholder: the address used while the field
    /// is blank.
    static let loaderURLPlaceholder = Config.phoneLoaderURLDefault
    /// The loader URL field's help text.
    static let loaderURLHelp = "The page your phone opens from the QR code. Leave blank to use TBD's default. "
        + "Press Return to save."

    /// Whether "Pair a Phone…" can start an offer: phone control is on, the
    /// bridge runs, a relay is set, and the relay is usable.
    static func canPair(_ status: PhoneStatusResult?) -> Bool {
        guard let status else { return false }
        return status.enabled && status.running && status.relayURL != nil
            && status.relay.state != .incompatible
    }

    /// Why "Pair a Phone…" is disabled, for its help text; nil when it is not.
    static func pairDisabledReason(_ status: PhoneStatusResult?) -> String? {
        guard let status else { return "Phone control's status is not available yet." }
        if !status.enabled { return "Turn on phone control first." }
        if status.relayURL == nil { return "Set up a phone relay first." }
        if status.relay.state == .incompatible {
            return "This relay is not usable. Set up a phone relay again."
        }
        if !status.running { return status.problem ?? "Phone control is not running." }
        return nil
    }

    /// The time an offer has left, as "m:ss", floored at "0:00".
    static func countdown(remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.down)))
        let tail = seconds % 60
        return "\(seconds / 60):\(tail < 10 ? "0" : "")\(tail)"
    }

    /// A 6-digit confirmation code as the phone shows it: "123456" becomes
    /// "123 456".
    static func formatCode(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        return "\(digits.prefix(3)) \(digits.dropFirst(3))"
    }

    /// The Allow prompt. It appears only once the phone's first encrypted
    /// message has decrypted, so a replayed handshake never raises it.
    static func approvalPrompt(name: String, code: String) -> String {
        "Allow '\(name)' to control this laptop? Code \(formatCode(code))"
    }

    /// The pairing sheet's sentence for an offer that ended without a phone.
    /// An interrupted offer names no cause: a page reload, a relay refusal, a
    /// row that could not be stored and an undone Allow all end that way, and
    /// the status does not say which.
    static func endedSentence(_ state: PhonePairingState) -> String {
        switch state {
        case .denied: return "Pairing was denied."
        case .expired: return "The code expired."
        case .interrupted: return "Pairing was interrupted. Start again to pair this phone."
        case .waitingForPhone, .awaitingApproval, .paired, .unknown: return "Pairing stopped."
        }
    }

    /// Whether an offer in `state` is still live, so closing the sheet must
    /// deny it.
    static func isLive(_ state: PhonePairingState) -> Bool {
        state == .waitingForPhone || state == .awaitingApproval
    }

    /// The offer the pairing sheet shows, from the offer it `started` and the
    /// daemon's last `status`. Once there is a status, its report stands: the
    /// offer as it is now, or nil when the daemon reports no offer or another
    /// one, which ended this one. With no status yet, as before the first
    /// `phone.status` answers, the offer stands as `phone.pairStart` returned
    /// it, so the sheet shows its code and closing the sheet denies it.
    static func sheetPairing(started: PhonePairingStatus, status: PhoneStatusResult?) -> PhonePairingStatus? {
        guard let status else { return started }
        guard let pairing = status.pairing, pairing.offerID == started.offerID else { return nil }
        return pairing
    }

    /// The offer closing the pairing sheet denies: the one it shows, while
    /// that offer is live; nil once it has ended.
    static func offerToDeny(started: PhonePairingStatus, status: PhoneStatusResult?) -> UUID? {
        guard let shown = sheetPairing(started: started, status: status), isLive(shown.state) else { return nil }
        return shown.offerID
    }

    /// The line the pane shows when phone control's status could not be read.
    /// A daemon without the methods needs a restart; any other failure is
    /// shown as the daemon put it.
    static func statusErrorLine(_ error: String) -> String {
        if error.contains("Unknown method") {
            return "This daemon does not support phone control. Restart TBD."
        }
        return "Could not read phone control's status: \(error)"
    }

    /// The Revoke confirmation's title and message.
    static func revokeTitle(name: String) -> String { "Revoke '\(name)'?" }
    static let revokeMessage = "This phone can no longer control this laptop."

    /// One row of the paired-phones list, with its date text already
    /// formatted, so the view's body formats nothing.
    struct DeviceRow: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// "Paired <date>".
        let pairedText: String
        /// "Connected", "Last seen <relative>" or "Never connected".
        let seenText: String
        let isConnected: Bool
    }

    /// The paired-phones list for `devices`, `connected` being the phones
    /// connected at `now`, which "Last seen" is relative to. Built when the
    /// devices or the connected set change and once a minute, never in a
    /// view body.
    static func deviceRows(_ devices: [PhoneDevice], connected: Set<UUID>, now: Date) -> [DeviceRow] {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return devices.map { device in
            let isConnected = connected.contains(device.id)
            let seen: String
            if isConnected {
                seen = "Connected"
            } else if let lastSeen = device.lastSeenAt {
                seen = "Last seen \(relative.localizedString(for: lastSeen, relativeTo: now))"
            } else {
                seen = "Never connected"
            }
            return DeviceRow(
                id: device.id, name: device.name,
                pairedText: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))",
                seenText: seen, isConnected: isConnected)
        }
    }
}

/// Renders a pairing link as a QR code. Called when the link changes, never
/// in a view body.
enum PhoneQRCode {
    /// The blank margin, in modules, that a QR reader needs around the code.
    static let quietZoneModules: CGFloat = 4

    /// `text` as a QR code at error-correction level M, each module `scale`
    /// points square with hard edges, with a white quiet zone around it.
    static func image(for text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let margin = quietZoneModules
        let padded = code
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: CIColor.white).cropped(to: CGRect(
                x: 0, y: 0, width: code.extent.width + 2 * margin, height: code.extent.height + 2 * margin)))
        let scaled = padded
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
