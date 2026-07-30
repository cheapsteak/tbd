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
/// ## Row hierarchy
///
/// Two things live here, and the rows say so. The webview toggle is the
/// feature switch; the stylesheet picker is the setting. Everything else —
/// where the stylesheets live, how to make one, how to write one — is
/// *subordinate to the picker*, so it collapses into a single `LabeledContent`
/// row beneath it rather than floating as unlabelled siblings of equal weight.
/// The trailing cluster (path + copy, create, docs) reads as the picker's
/// toolbox, which is what it is.
///
/// File-backed setting, so it carries the affordance CLAUDE.md requires for one:
/// the tilde-abbreviated backing path and a copy-path button. "New from Default"
/// additionally reveals the file it just wrote in Finder, since that is the
/// moment a new file exists to point at.
struct MarkdownSettingsSection: View {
    @AppStorage(MarkdownViewerPreferences.useWebViewKey) private var useWebView: Bool = false
    /// `""` means "no selection" — the bundled default. `MarkdownStylesheet`
    /// already treats blank as unset, so the empty tag needs no special case.
    @AppStorage(MarkdownStylesheet.themeKey) private var themeID: String = ""

    @State private var catalog = MarkdownThemeCatalog.Catalog()

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

            stylesheetsFolderRow
        }
        // No watcher: re-enumerate on appear and after anything that could have
        // changed the directory or the selection.
        .onAppear { refresh() }
        .onChange(of: themeID) { refresh() }
    }

    /// The picker's subordinate row: where stylesheets live, how to get one,
    /// and where the guide is — one labelled form row instead of three floating
    /// ones. The path + copy-path button follow `RepoHooksSettingsView`, which is
    /// the shape every file-backed settings surface in this app uses.
    @ViewBuilder
    private var stylesheetsFolderRow: some View {
        LabeledContent("Stylesheets folder") {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(themesDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    copyPathButton
                }

                Button("New from Default") { newStylesheetFromDefault() }
                    .controlSize(.small)
                    .help("Copy TBD's bundled \u{201C}Default (bundled)\u{201D} stylesheet into this folder as a new stylesheet, select it, and reveal the copy in Finder. The copy is a snapshot — it will not pick up later changes to the bundled sheet.")

                stylesheetDocsButton
            }
        }
    }

    private var copyPathButton: some View {
        Button {
            let path = themesDirectory.path
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

    private var stylesheetDocsButton: some View {
        Button {
            revealStylesheetDocs()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Read the docs on writing a stylesheet — reveals the guide in Finder.")
        .disabled(MarkdownStylesheet.stylesheetDocsURL == nil)
    }

    private func refresh() {
        catalog = MarkdownThemeCatalog.load(themesDirectory: themesDirectory)
    }

    private func newStylesheetFromDefault() {
        guard let id = MarkdownThemeCatalog.duplicateBundledDefault(in: themesDirectory) else {
            refresh()
            return
        }
        themeID = id
        refresh()
        // Reveal the file that was just written — not the themes folder in
        // general — so the new copy is the thing selected in Finder.
        let newFileURL = themesDirectory.appendingPathComponent("\(id).css")
        NSWorkspace.shared.activateFileViewerSelecting([newFileURL])
    }

    /// Reveals the bundled doc in Finder rather than opening it. It lives inside
    /// the `.app` bundle, so handing the user its location is the deliberate
    /// behavior here — they decide what to open it with.
    private func revealStylesheetDocs() {
        guard let url = MarkdownStylesheet.stylesheetDocsURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
