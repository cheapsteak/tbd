import AppKit
import SwiftTerm
import SwiftUI
import TBDShared

struct TerminalSettingsView: View {
    @EnvironmentObject var appearance: AppearanceSettings
    @EnvironmentObject var appState: AppState
    @AppStorage(AppState.terminalAutoResizeKey) private var enableTerminalAutoResize: Bool = false

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

            Section {
                HStack {
                    Picker("Scheme", selection: $appearance.schemeID) {
                        ForEach(ColorSchemes.bundled, id: \.id) { scheme in
                            Text(scheme.displayName).tag(scheme.id)
                        }
                    }
                    .pickerStyle(.menu)
                    if appearance.hasTmuxStyleOverrides {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Your ~/.tmux.conf sets window-style or a similar option that paints every cell with explicit colors. tmux's paint will override the scheme's foreground/background. To let this scheme drive the appearance, unset those options in your tmux config (e.g. `set -gu window-style`).")
                    }
                }
            } header: {
                Text("Color Scheme")
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
    }

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
