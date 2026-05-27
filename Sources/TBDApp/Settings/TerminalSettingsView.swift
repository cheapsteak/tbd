import AppKit
import SwiftTerm
import SwiftUI
import TBDShared

private typealias SwiftUIColor = SwiftUI.Color

struct TerminalSettingsView: View {
    @EnvironmentObject var appearance: AppearanceSettings
    @EnvironmentObject var appState: AppState
    @AppStorage(AppState.terminalAutoResizeKey) private var enableTerminalAutoResize: Bool = false

    @StateObject private var editorVM = TerminalThemeEditorViewModel()
    @State private var showingSaveAsDialog = false
    @State private var saveAsName = ""
    @State private var deleteConfirmation = false
    @State private var importError: String?
    @State private var errorTitle: String = "Error"
    @State private var pendingSchemeSwitch: String?
    @State private var showingPendingSwitchConfirm = false

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text(displayFontName)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Choose Font…") {
                        FontPickerCoordinator.shared.show(current: appearance.font) { newFont in
                            appearance.fontName = newFont.fontName
                            appearance.fontSize = newFont.pointSize
                        }
                    }
                }
                Stepper(value: $appearance.fontSize, in: 8...48, step: 1) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(appearance.fontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Toggle("Thin strokes", isOn: $appearance.thinStrokes)
                    .help("Disables font smoothing for thinner text on Retina displays. Matches iTerm's 'Thin Strokes' setting.")
            }

            Section("Color Scheme") {
                Picker("Scheme", selection: schemeBinding) {
                    Section("Bundled") {
                        ForEach(ColorSchemes.bundled, id: \.id) { scheme in
                            Text(scheme.displayName).tag(scheme.id)
                        }
                    }
                    if !appState.themeStore.userThemes.isEmpty {
                        Section("My Themes") {
                            ForEach(appState.themeStore.userThemes, id: \.id) { scheme in
                                Text(scheme.displayName + (editorVM.isDirty && scheme.id == appearance.schemeID ? " — Draft" : ""))
                                    .tag(scheme.id)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    if editorVM.isDirty {
                        if editorVM.canSave {
                            Button("Save") { performSave() }
                        }
                        Button("Save as…") {
                            saveAsName = editorVM.displayName + " Copy"
                            showingSaveAsDialog = true
                        }
                        Button("Reset") {
                            editorVM.reset()
                            appearance.draftSchemeOverride = nil
                        }
                    } else {
                        Button("Save as…") {
                            saveAsName = editorVM.displayName + " Copy"
                            showingSaveAsDialog = true
                        }
                    }
                    if currentSourceKind == .user {
                        Button("Delete", role: .destructive) { deleteConfirmation = true }
                    }
                    Button("Import…") { performImport() }
                }

                if !appState.themeStore.loadErrors.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(appState.themeStore.loadErrors.count) theme file(s) failed to load")
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                appState.themeStore.loadErrors.map {
                                    appState.themeStore.themesDirectory.appendingPathComponent($0.filename)
                                }
                            )
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(SwiftUIColor.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(appState.themeStore.loadErrors.map { "\($0.filename): \($0.message)" }.joined(separator: "\n"))
                }

                TerminalThemeEditorView(viewModel: editorVM)
                    .onAppear { syncEditorWithScheme() }
                    .onChange(of: appearance.schemeID) { _, _ in syncEditorWithScheme() }
                    .onChange(of: editorVM.draftHex) { _, _ in updateDraftOverride() }
                    .onChange(of: editorVM.displayNameDraft) { _, _ in updateDraftOverride() }
            }

            Section("Cursor") {
                Picker("Style", selection: $appearance.cursorStyle) {
                    Text("Block").tag(CursorStyle.steadyBlock)
                    Text("Block (blinking)").tag(CursorStyle.blinkBlock)
                    Text("Underline").tag(CursorStyle.steadyUnderline)
                    Text("Underline (blinking)").tag(CursorStyle.blinkUnderline)
                    Text("Bar").tag(CursorStyle.steadyBar)
                    Text("Bar (blinking)").tag(CursorStyle.blinkBar)
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle("Auto-resize tmux windows to match the app pane (WIP)", isOn: $enableTerminalAutoResize)
                    .help("When on, TBD broadcasts the live pane size to the daemon and resizes every tmux window on app resize. Currently unstable — can leave panes smaller than the visible area and clip the bottom rows.")
            } header: {
                Text("Experimental")
            } footer: {
                Text("Off by default — under active development. Known bugs around tmux \"window-size manual\" lock-in can clip the bottom rows of a pane. To bail out, turn it off and restart the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ClaudeEnvRegistry.all, id: \.id) { setting in
                    ClaudeEnvSettingRow(setting: setting) {
                        appState.pushClaudeSpawnPreferences()
                    }
                }
            } header: {
                Text("Claude Environment")
            } footer: {
                Text("Applies to newly spawned Claude sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingSaveAsDialog) { saveAsDialog }
        .confirmationDialog(
            "Delete \(editorVM.displayName)?",
            isPresented: $deleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This theme will be moved to .trash/; your terminals will revert to Tango.")
        }
        .alert(errorTitle, isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) { Button("OK") {} } message: { Text(importError ?? "") }
        .confirmationDialog(
            "Unsaved changes to \(editorVM.displayName)",
            isPresented: $showingPendingSwitchConfirm,
            titleVisibility: .visible
        ) {
            if editorVM.canSave {
                Button("Save") {
                    performSave()
                    commitPendingSwitch()
                }
            }
            Button("Save as…") {
                saveAsName = editorVM.displayName + " Copy"
                showingSaveAsDialog = true
                // pendingSchemeSwitch is intentionally left set — performSaveAs reads it.
            }
            Button("Discard", role: .destructive) {
                editorVM.reset()
                commitPendingSwitch()
            }
            Button("Cancel", role: .cancel) {
                pendingSchemeSwitch = nil
            }
        }
    }

    // MARK: - Computed helpers

    private var currentScheme: TerminalColorScheme {
        ColorSchemes.scheme(forID: appearance.schemeID, store: appState.themeStore)
    }

    private var currentSourceKind: TerminalThemeEditorViewModel.SourceKind {
        ColorSchemes.bundled.contains { $0.id == appearance.schemeID } ? .bundled : .user
    }

    private var schemeBinding: Binding<String> {
        Binding(
            get: { appearance.schemeID },
            set: { newID in
                if editorVM.isDirty {
                    pendingSchemeSwitch = newID
                    showingPendingSwitchConfirm = true
                } else {
                    appearance.schemeID = newID
                    appearance.draftSchemeOverride = nil
                    syncEditorWithScheme()
                }
            }
        )
    }

    private func commitPendingSwitch() {
        guard let target = pendingSchemeSwitch else { return }
        pendingSchemeSwitch = nil
        appearance.schemeID = target
        appearance.draftSchemeOverride = nil
        syncEditorWithScheme()
    }

    // MARK: - Editor sync

    private func syncEditorWithScheme() {
        editorVM.load(source: currentScheme, kind: currentSourceKind)
        appearance.draftSchemeOverride = nil
    }

    private func updateDraftOverride() {
        guard editorVM.isDirty else {
            appearance.draftSchemeOverride = nil
            return
        }
        if let valid = try? editorVM.snapshot(id: appearance.schemeID).toScheme() {
            appearance.draftSchemeOverride = valid
        }
        // Otherwise: keep the previous valid override in place — don't snap back
        // to source mid-typing. The next valid edit will refresh it.
    }

    // MARK: - Actions

    private func performSave() {
        do {
            let theme = editorVM.snapshot(id: appearance.schemeID)
            try appState.themeStore.save(theme)
            editorVM.load(source: try theme.toScheme(), kind: .user)
            appearance.draftSchemeOverride = nil
        } catch {
            errorTitle = "Save failed"
            importError = String(describing: error)
        }
    }

    @discardableResult
    private func performSaveAs(name: String) -> Bool {
        do {
            let draft = editorVM.snapshot(id: "")
            let newID = try appState.themeStore.saveAs(draft, suggestedDisplayName: name)
            appearance.schemeID = newID
            syncEditorWithScheme()
            // If the user invoked Save as… from the unsaved-draft confirm dialog,
            // they had also picked a different scheme they wanted to switch to.
            // The save-as activated the new user theme; honor their original
            // switch intent unless they meant to stay on the new theme.
            if let target = pendingSchemeSwitch, target != newID {
                commitPendingSwitch()
            } else {
                pendingSchemeSwitch = nil
            }
            return true
        } catch ThemeStore.SaveError.bundledIDCollision(let slug) {
            errorTitle = "Name already taken"
            importError = "\"\(slug)\" is a built-in theme ID. Please choose a different name."
            // Leave pendingSchemeSwitch alone on failure so the user can decide
            // what to do next.
            return false
        } catch {
            errorTitle = "Save as failed"
            importError = String(describing: error)
            // Leave pendingSchemeSwitch alone on failure so the user can decide
            // what to do next.
            return false
        }
    }

    private func performDelete() {
        let active = appearance.schemeID
        do {
            try appState.themeStore.delete(id: active)
        } catch {
            errorTitle = "Delete failed"
            importError = String(describing: error)
            return
        }
        appearance.schemeID = ColorSchemes.defaultScheme.id
        syncEditorWithScheme()
    }

    private func performImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "toml")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try AlacrittyImporter().importFile(url)
            let id = try appState.themeStore.saveAs(imported, suggestedDisplayName: imported.displayName)
            appearance.schemeID = id
            syncEditorWithScheme()
        } catch {
            errorTitle = "Import failed"
            importError = String(describing: error)
        }
    }

    // MARK: - Save-as dialog

    private var saveAsDialog: some View {
        VStack(spacing: 12) {
            Text("Save as new theme").font(.headline)
            TextField("Name", text: $saveAsName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Button("Cancel") { showingSaveAsDialog = false }
                Button("Save") {
                    if performSaveAs(name: saveAsName) {
                        showingSaveAsDialog = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - Font name

    private var displayFontName: String {
        // Use the resolved font's display name so a poisoned/missing font name
        // shows the actual fallback in the Settings label, not the invalid stored value.
        appearance.font.displayName ?? appearance.fontName
    }
}

/// One row in the registry-driven Claude Environment settings section.
/// Renders the control matching the setting's `Kind`. v1 handles `.toggle`;
/// adding `.integer` / `.choice` is a new `switch` arm here.
private struct ClaudeEnvSettingRow: View {
    let setting: ClaudeEnvSetting
    let onChange: () -> Void
    @AppStorage private var boolValue: Bool

    init(setting: ClaudeEnvSetting, onChange: @escaping () -> Void) {
        self.setting = setting
        self.onChange = onChange
        let def: Bool
        switch setting.kind {
        case .toggle(let d, _): def = d
        }
        _boolValue = AppStorage(wrappedValue: def, AppState.claudeEnvKey(setting.id))
    }

    var body: some View {
        switch setting.kind {
        case .toggle:
            Toggle(setting.title, isOn: $boolValue)
                .help(setting.help)
                .onChange(of: boolValue) { _, _ in onChange() }
        }
    }
}

/// Bridges NSFontPanel into AppKit. NSFontPanel is a singleton that delivers
/// font choices via `changeFont(_:)` on the first responder; we route it
/// through a coordinator so SwiftUI views can opt into the panel.
@MainActor
final class FontPickerCoordinator: NSObject {
    static let shared = FontPickerCoordinator()
    private var completion: ((NSFont) -> Void)?

    func show(current: NSFont, completion: @escaping (NSFont) -> Void) {
        self.completion = completion
        NSFontManager.shared.setSelectedFont(current, isMultiple: false)
        NSFontManager.shared.target = self
        let panel = NSFontPanel.shared
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let current = sender.selectedFont ?? NSFont.systemFont(ofSize: 12)
        let newFont = sender.convert(current)
        completion?(newFont)
        completion = nil
    }
}
