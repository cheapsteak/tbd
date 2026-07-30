import AppKit
import SwiftUI
import TBDShared

/// Settings › General › Markdown — the file viewer's stylesheet surface.
///
/// A thin shell: every decision (what is installed, whether the selection is
/// dead, which name a copy gets, what the path row points at, whether the
/// mirrored README needs rewriting) lives in `MarkdownThemeCatalog`, which takes
/// an explicit directory so it is testable without touching `~/tbd`. This view
/// only binds, calls, and re-enumerates.
///
/// ## Row hierarchy
///
/// Three rows, in decreasing scope. The webview toggle is the feature switch;
/// the stylesheet picker is the setting; the path row is where the setting
/// lives on disk. Making a stylesheet is not a fourth concern — it is a way of
/// choosing one, so it rides in the picker as a trailing action entry below a
/// divider rather than as a button competing with it.
///
/// File-backed setting, so it carries the affordance CLAUDE.md requires for
/// one: the tilde-abbreviated backing path and a copy-path button, in the third
/// row.
struct MarkdownSettingsSection: View {
    @AppStorage(MarkdownViewerPreferences.useWebViewKey) private var useWebView: Bool = false
    /// `""` means "no selection" — the bundled default. `MarkdownStylesheet`
    /// already treats blank as unset, so the empty tag needs no special case.
    @AppStorage(MarkdownStylesheet.themeKey) private var themeID: String = ""

    @State private var catalog = MarkdownThemeCatalog.Catalog()

    private var themesDirectory: URL { TBDConstants.markdownThemesDir }

    private var revealTarget: MarkdownThemeCatalog.RevealTarget {
        MarkdownThemeCatalog.revealTarget(themesDirectory: themesDirectory, catalog: catalog)
    }

    var body: some View {
        Section("Markdown") {
            Toggle("Render markdown files in a webview", isOn: $useWebView)
                .help("Replaces the native markdown renderer in the file viewer with an HTML/WebView one, which is what makes CSS stylesheets apply. Off by default (soaking).")

            stylesheetPicker

            if let missing = catalog.missingSelection {
                Text("\u{201C}\(missing).css\u{201D} is no longer in the stylesheets folder, so the bundled default is being used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            pathRow
        }
        // No watcher: re-enumerate on appear and after anything that could have
        // changed the directory or the selection. The README is mirrored here
        // too — on appear, not at launch, so TBD only creates the folder for
        // someone who has actually opened this section.
        .onAppear {
            MarkdownThemeCatalog.syncManagedReadme(in: themesDirectory)
            refresh()
        }
        .onChange(of: themeID) { refresh() }
    }

    /// The stylesheet entries, then a separated action entry.
    ///
    /// The action's tag is a sentinel the binding's setter intercepts, so it is
    /// never stored; and because the action selects the stylesheet it just
    /// created, the picker settles on that new entry rather than displaying the
    /// action as though it were the current value.
    private var stylesheetPicker: some View {
        Picker("Stylesheet", selection: stylesheetSelection) {
            Text("Default (bundled)").tag("")
            ForEach(catalog.installed, id: \.self) { id in
                Text(id).tag(id)
            }
            // Keep a tag matching the dead selection, or the picker would
            // render blank and read as a rendering glitch.
            if let missing = catalog.missingSelection {
                Text("\(missing) — missing").tag(missing)
            }

            Divider()

            Text("New from Default\u{2026}").tag(MarkdownThemeCatalog.newFromDefaultTag)
        }
        .help("Stylesheets are the *.css files in the folder below. Applies to the webview renderer only. \u{201C}New from Default\u{201D} copies TBD's bundled sheet into that folder as a new stylesheet, selects it, and reveals it in Finder; the copy is a snapshot and will not pick up later changes to the bundled sheet.")
    }

    /// Reads through to the stored theme ID — which is never the sentinel — and
    /// routes the action tag to `newStylesheetFromDefault()` instead of storage.
    private var stylesheetSelection: Binding<String> {
        Binding(
            get: { themeID },
            set: { tag in
                switch MarkdownThemeCatalog.pickerSelection(forTag: tag) {
                case .newFromDefault: newStylesheetFromDefault()
                case .bundledDefault: themeID = ""
                case .theme(let id): themeID = id
                }
            }
        )
    }

    /// Where the selection lives on disk, plus the two things worth doing with
    /// a path: copy it, or open it. Both follow `revealTarget`, so the path
    /// shown and the thing revealed are always the same object.
    private var pathRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(revealTarget.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                copyPathButton
            }

            Spacer(minLength: 12)

            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([revealTarget.url])
            }
            .controlSize(.small)
            .help(revealTarget.isFolder
                ? "Reveal the stylesheets folder in Finder."
                : "Reveal the selected stylesheet in Finder.")
        }
    }

    private var copyPathButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(revealTarget.url.path, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy full path")
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
}
