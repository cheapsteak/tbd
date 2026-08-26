import SwiftUI
import TBDShared

/// What the attach pane shows when `RemoteAttachPreflight` could not resolve
/// a selection to a spawnable command.
///
/// Deliberately in the pane rather than an alert or a log line: the user is
/// looking here, so the reason belongs here. `RemoteAttachPager` used to
/// `continue` past an unresolvable selection — no tab, no error, and a blank
/// rectangle where the terminal should have been, which reads as "attach is
/// broken" whatever the actual cause was.
///
/// Every string comes from the pure diagnosis, so what a user reads is
/// exactly what `RemoteAttachPreflightTests` asserts.
struct RemoteAttachDiagnosisView: View {
    let selection: RemoteSessionSelection
    let diagnosis: RemoteAttachPreflight.Diagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SuffixRowIndicator.attention.color)
                Text(diagnosis.title)
                    .font(.headline)
            }
            Text(diagnosis.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // The selection verbatim: which provider was asked, for which
            // session. The failure class this view exists for is "I thought I
            // was talking to the other provider", so the pane never leaves
            // that implicit.
            Text("\(selection.provider) · \(selection.sessionID)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diagnosis.title). \(diagnosis.detail)")
    }
}
