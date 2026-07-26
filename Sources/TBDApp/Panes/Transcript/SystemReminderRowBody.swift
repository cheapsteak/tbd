import AppKit
import SwiftUI
import TBDShared

/// Overlay body for a `.systemReminder` item (non-skillBody kinds).
///
/// Injected-context rows (CLAUDE.md bodies, hook output) are capped at
/// `TranscriptParser.bodyCharCap` like any other body, so this offers the same
/// "Show full output" fetch the tool cards do. Only truncated items
/// (`truncatedTo != nil`) get the affordance — short reminders never make the
/// round-trip.
///
/// Injected rows additionally fetch their *injection metadata* (which hook,
/// which command, which tool call triggered it) on appear. That rides the same
/// `terminal.transcriptItemFullBody` RPC, so nothing is paid until a row is
/// opened, and no field is added to `TranscriptItem`. The on-appear fetch passes
/// `includeBody: false` — it only reads `attachment`, and an injected CLAUDE.md
/// body is routinely tens of KB.
///
/// Expanding a truncated row therefore re-reads the JSONL a second time. That
/// is deliberate: the second read is user-initiated, bounded to one row, and
/// caching the body from the metadata fetch would both defeat the truncation
/// footer (the body would appear expanded unasked) and re-introduce the large
/// payload on every open.
struct SystemReminderRowBody: View {
    let id: String
    let kind: SystemKind
    let text: String
    let truncatedTo: Int?
    let terminalID: UUID?

    @State private var fullText: String? = nil
    @State private var metadata: TranscriptAttachmentMetadata? = nil
    @EnvironmentObject var appState: AppState

    /// Only hook output and injected file bodies come from `attachment` rows;
    /// every other reminder kind would round-trip for a guaranteed-nil result.
    private var carriesInjectionMetadata: Bool {
        kind == .hookOutput || kind == .nestedMemory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let metadata {
                metadataBlock(metadata)
                Divider()
            }
            // `.caption`/`.primary` — this is the content the row was opened to
            // read, matching `SkillBodyRow`'s injected body. `.caption2` +
            // `.tertiary` is for small section labels, not a whole body.
            Text(fullText ?? text)
                .font(.caption)
                .foregroundStyle(.primary)
                .transcriptSelectableText()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let cap = truncatedTo, fullText == nil, terminalID != nil {
                TruncationFooter(truncatedTo: cap, currentLength: text.count) {
                    Task { await fetchFull() }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: id) { await fetchMetadata() }
    }

    // MARK: Injection metadata

    @ViewBuilder
    private func metadataBlock(_ m: TranscriptAttachmentMetadata) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let triggeredBy = m.triggeredBy { field("Triggered by", triggeredBy) }
            if let hookName = m.hookName { field("Hook", hookName) }
            if let hookEvent = m.hookEvent { field("Event", hookEvent) }
            if let command = m.command { field("Command", command, monospaced: true) }
            if let exitCode = m.exitCode { field("Exit code", "\(exitCode)") }
            if let durationMs = m.durationMs { field("Duration", "\(durationMs) ms") }
            if let memoryType = m.memoryType { field("Memory", memoryType) }
            if let path = m.path { pathField(path) }
            if let stderr = m.stderr { field("stderr", stderr, monospaced: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // One step up from the `.tertiary`/`.secondary` pair the rest of the
            // file uses for section labels: the label/value contrast survives,
            // but both stay legible against the overlay's light background.
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption2.monospaced() : .caption2)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    /// `$HOME` → `~`, on path-component boundaries. A plain substring replace
    /// would turn `/Users/changelog-archive/x` into `~elog-archive/x` — a
    /// different directory presented as living inside the user's home. Foundation
    /// reads the same `NSHomeDirectory()`, so the daemon's `injectedPathSource`
    /// abbreviates identically.
    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Tilde-abbreviated path + copy button, matching `RepoHooksSettingsView`'s
    /// backing-path affordance. The abbreviation is display-only: the button
    /// copies the full absolute path.
    @ViewBuilder
    private func pathField(_ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Path")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.abbreviatedPath(path))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                // Head, not middle: when the field is too narrow the filename
                // must survive and the path prefix goes.
                .truncationMode(.head)
                .help(path)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy full path")
        }
    }

    // MARK: Fetches

    private func fetchMetadata() async {
        guard carriesInjectionMetadata, metadata == nil, let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(
            terminalID: terminalID, itemID: id, includeBody: false), let attachment = r.attachment {
            await MainActor.run { metadata = attachment }
        }
    }

    private func fetchFull() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id) {
            await MainActor.run { fullText = r.text }
        }
    }
}
