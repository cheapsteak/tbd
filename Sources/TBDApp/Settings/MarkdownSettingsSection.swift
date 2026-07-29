import AppKit
import SwiftUI
import TBDShared

/// Settings › General › Markdown — the file viewer's stylesheet surface.
///
/// A thin shell: every decision (what is installed, whether the selection is
/// dead, which name a copy gets) lives in `MarkdownThemeCatalog`, which takes an
/// explicit directory so it is testable without touching `~/tbd`. This view only
/// binds, calls, and re-enumerates.
///
/// File-backed setting, so it carries the affordance CLAUDE.md requires for one:
/// the tilde-abbreviated backing path, a copy-path button, and a reveal.
struct MarkdownSettingsSection: View {
    @AppStorage(MarkdownViewerPreferences.useWebViewKey) private var useWebView: Bool = false
    /// `""` means "no selection" — the bundled default. `MarkdownStylesheet`
    /// already treats blank as unset, so the empty tag needs no special case.
    @AppStorage(MarkdownStylesheet.themeKey) private var themeID: String = ""

    @State private var catalog = MarkdownThemeCatalog.Catalog()
    @State private var showingBundled = false

    private var themesDirectory: URL { TBDConstants.markdownThemesDir }

    var body: some View {
        Section("Markdown") {
            Toggle("Render markdown files in a webview", isOn: $useWebView)
                .help("Replaces the native markdown renderer in the file viewer with an HTML/WebView one, which is what makes CSS stylesheets apply. Off by default (soaking).")

            Picker("Stylesheet", selection: $themeID) {
                Text("Default (bundled)").tag("")
                ForEach(catalog.installed, id: \.self) { id in
                    Text(id).tag(id)
                }
                // Keep a tag matching the dead selection, or the picker would
                // render blank and read as a rendering glitch.
                if let missing = catalog.missingSelection {
                    Text("\(missing) — missing").tag(missing)
                }
            }
            .help("Stylesheets are the *.css files in the folder below. Applies to the webview renderer only.")

            if let missing = catalog.missingSelection {
                Text("\u{201C}\(missing).css\u{201D} is no longer in the folder below, so the bundled default is being used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Duplicate Default…") { duplicateDefault() }
                    .help("Copy TBD's bundled stylesheet into the folder below as a new theme and select it. The copy is a snapshot — it will not pick up later changes to the bundled sheet.")
                Button("Show Default…") { showingBundled = true }
                    .help("View the bundled stylesheet, read-only.")
                Spacer()
            }
            .controlSize(.small)

            themesDirectoryRow

            Text("""
                A stylesheet is free-form CSS. TBD injects no theme attribute and defines no CSS \
                variable contract, so the --md-* tokens in the bundled sheet are internal \
                convention rather than an API. The only classes TBD's own sheet styles are \
                .markdown-alert (with its -note, -tip, -important, -warning and -caution \
                variants), .markdown-alert-title, .tbd-oversized-image, and .footnotes.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // No watcher: re-enumerate on appear and after anything that could have
        // changed the directory or the selection.
        .onAppear { refresh() }
        .onChange(of: themeID) { refresh() }
        .sheet(isPresented: $showingBundled) {
            MarkdownDefaultStylesheetSheet(css: MarkdownStylesheet.bundledCSS)
        }
    }

    /// Backing path + copy + reveal, modelled on `RepoHooksSettingsView`.
    @ViewBuilder
    private var themesDirectoryRow: some View {
        let path = themesDirectory.path
        HStack(spacing: 4) {
            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

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

            Spacer()

            Button("Reveal in Finder") { revealThemesDirectory() }
                .controlSize(.small)
        }
    }

    private func refresh() {
        catalog = MarkdownThemeCatalog.load(themesDirectory: themesDirectory)
    }

    private func duplicateDefault() {
        guard let id = MarkdownThemeCatalog.duplicateBundledDefault(in: themesDirectory) else {
            refresh()
            return
        }
        themeID = id
        refresh()
    }

    private func revealThemesDirectory() {
        // Created on demand rather than at launch, so people who never touch
        // this setting get no stray folder in ~/tbd.
        MarkdownStylesheet.ensureThemesDirectoryExists(themesDirectory)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: themesDirectory.path)
        refresh()
    }
}

/// Read-only view of the bundled stylesheet.
///
/// Deliberately not a reveal-in-Finder: the bundled sheet lives inside the
/// `.app`, and sending users in there invites edits that a rebuild silently
/// discards. Copy or "Duplicate Default…" instead.
private struct MarkdownDefaultStylesheetSheet: View {
    let css: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bundled default stylesheet")
                .font(.headline)
            Text("Read-only — it ships inside TBD. Copy it, or use \u{201C}Duplicate Default…\u{201D} to start an editable theme.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView([.vertical, .horizontal]) {
                Text(css)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(css, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 460)
    }
}
