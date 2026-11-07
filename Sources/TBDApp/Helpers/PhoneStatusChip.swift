import AppKit
import SwiftUI
import TBDShared

/// What the status bar's phone chip shows, as a value. `make` returns nil
/// where the bar shows no chip.
struct PhoneChipPresentation: Equatable {
    var title: String
    var accessibilityLabel: String

    /// The chip's tooltip.
    static let help = "Phone control: click to open Settings → Phone"

    /// The chip for `status`: shown only while at least one paired phone is
    /// connected, that is, its first encrypted message has decrypted.
    static func make(status: PhoneStatusResult?) -> PhoneChipPresentation? {
        guard let count = status?.connectedDeviceIDs.count, count > 0 else { return nil }
        let title = count == 1 ? "Phone connected" : "\(count) phones connected"
        return PhoneChipPresentation(title: title, accessibilityLabel: title)
    }
}

/// The status bar's phone chip, in the bar's right-hand group after the
/// Servers chip: a green capsule with the `iphone` glyph while a paired phone
/// is connected. A click opens Settings on the Phone tab.
///
/// It reads `appState.phoneStatus` itself, so a phone connecting or leaving
/// re-evaluates the chip and not the whole bar. The capsule matches the
/// Servers chip's running style.
struct PhoneStatusChip: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    private static let green = Color(nsColor: .systemGreen)

    var body: some View {
        if let chip = PhoneChipPresentation.make(status: appState.phoneStatus) {
            Button {
                appState.openPhoneSettings(relaySetup: false)
            } label: {
                HStack(spacing: ServersStatusChip.glyphTextGap) {
                    Image(systemName: "iphone")
                    // One line, as every label in the bar.
                    Text(chip.title)
                        .lineLimit(1)
                }
                .fontWeight(.medium)
                .foregroundStyle(Self.green)
                .padding(.horizontal, ServersStatusChip.capsuleHorizontalPadding)
                .padding(.vertical, ServersStatusChip.capsuleVerticalPadding)
                .background(Self.green.opacity(ServersStatusChip.fillOpacity), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(PhoneChipPresentation.help)
            .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
            .accessibilityLabel(chip.accessibilityLabel)
        }
    }
}
