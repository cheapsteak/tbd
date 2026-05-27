import AppKit
import SwiftTerm
import SwiftUI
import TBDShared

struct TerminalSettingsView: View {
    @EnvironmentObject var appearance: AppearanceSettings
    @EnvironmentObject var appState: AppState
    @AppStorage(AppState.terminalAutoResizeKey) private var enableTerminalAutoResize: Bool = false

    @StateObject private var editorVM = TerminalThemeEditorViewModel()
    @State private var showingSaveAsDialog = false
    @State private var saveAsName = ""
    @State private var deleteConfirmation = false
    @State private var importError: String?

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
                    Text("\(appState.themeStore.loadErrors.count) theme(s) failed to load — see console")
                        .font(.caption).foregroundStyle(.orange)
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
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) { Button("OK") {} } message: { Text(importError ?? "") }
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
                // Unsaved-draft confirmation is added in Task 14 by overriding this setter.
                appearance.schemeID = newID
                appearance.draftSchemeOverride = nil
                syncEditorWithScheme()
            }
        )
    }

    // MARK: - Editor sync

    private func syncEditorWithScheme() {
        editorVM.load(source: currentScheme, kind: currentSourceKind)
        appearance.draftSchemeOverride = nil
    }

    private func updateDraftOverride() {
        if editorVM.isDirty {
            appearance.draftSchemeOverride = try? editorVM.snapshot(id: appearance.schemeID).toScheme()
        } else {
            appearance.draftSchemeOverride = nil
        }
    }

    // MARK: - Actions

    private func performSave() {
        do {
            let theme = editorVM.snapshot(id: appearance.schemeID)
            try appState.themeStore.save(theme)
            editorVM.load(source: try theme.toScheme(), kind: .user)
            appearance.draftSchemeOverride = nil
        } catch {
            importError = "Save failed: \(error)"
        }
    }

    private func performSaveAs(name: String) {
        do {
            let draft = editorVM.snapshot(id: "")
            let newID = try appState.themeStore.saveAs(draft, suggestedDisplayName: name)
            appearance.schemeID = newID
            syncEditorWithScheme()
        } catch {
            importError = "Save as failed: \(error)"
        }
    }

    private func performDelete() {
        let active = appearance.schemeID
        try? appState.themeStore.delete(id: active)
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
            importError = "Import failed: \(error)"
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
                    performSaveAs(name: saveAsName)
                    showingSaveAsDialog = false
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
