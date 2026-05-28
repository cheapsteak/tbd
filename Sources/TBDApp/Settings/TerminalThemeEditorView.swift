// Sources/TBDApp/Settings/TerminalThemeEditorView.swift
import SwiftUI
import SwiftTerm

private typealias SwiftUIColor = SwiftUI.Color

/// Inline editor below the Color Scheme picker in Settings → Terminal.
/// Always visible; touching any field enters draft state on the bound view-model.
/// Action buttons (Save / Save as / Reset) and surrounding affordances (Import /
/// Delete) are rendered by the parent so they sit in the same row as the picker.
@MainActor
struct TerminalThemeEditorView: View {
    @ObservedObject var viewModel: TerminalThemeEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name:")
                    .frame(width: 100, alignment: .trailing)
                TextField("Display name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }

            slotRow("Foreground", slot: .foreground)
            slotRow("Background", slot: .background)
            slotRow("Cursor",     slot: .cursor)
            slotRow("Selection",  slot: .selection)

            Divider().padding(.vertical, 4)

            Text("ANSI 0 – 7").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    VStack(spacing: 2) {
                        let slot = TerminalThemeEditorViewModel.Slot.ansi(i)
                        ColorPicker("", selection: colorBinding(for: slot), supportsOpacity: false)
                            .labelsHidden()
                            .help("ANSI \(i) — \(viewModel.hex(slot: slot))")
                        resetCell(for: slot)
                    }
                }
            }
            Text("ANSI 8 – 15").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(8..<16, id: \.self) { i in
                    VStack(spacing: 2) {
                        let slot = TerminalThemeEditorViewModel.Slot.ansi(i)
                        ColorPicker("", selection: colorBinding(for: slot), supportsOpacity: false)
                            .labelsHidden()
                            .help("ANSI \(i) — \(viewModel.hex(slot: slot))")
                        resetCell(for: slot)
                    }
                }
            }

            if let err = viewModel.lastValidationError {
                Text(humanMessage(for: err))
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SwiftUIColor.secondary.opacity(0.3))
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { viewModel.displayName },
            set: { viewModel.setDisplayName($0) }
        )
    }

    @ViewBuilder
    private func slotRow(_ label: String, slot: TerminalThemeEditorViewModel.Slot) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .trailing)
            TextField("", text: hexBinding(for: slot))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 100)
            ColorPicker("", selection: colorBinding(for: slot), supportsOpacity: false)
                .labelsHidden()
            resetCell(for: slot)
        }
    }

    /// Per-slot ↺ button. Always rendered at opacity 0 when clean to avoid
    /// insertion animation. The container always reserves layout space (20×20 frame)
    /// so the row doesn't shift as slots dirty/clean.
    @ViewBuilder
    private func resetCell(for slot: TerminalThemeEditorViewModel.Slot) -> some View {
        let dirty = viewModel.isSlotDirty(slot)
        Button {
            viewModel.unsetSlot(slot)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.caption2)
        }
        .buttonStyle(.borderless)
        .help("Revert this color to the source")
        .opacity(dirty ? 1 : 0)
        .allowsHitTesting(dirty)
        .frame(width: 20, height: 20)
    }

    private func hexBinding(for slot: TerminalThemeEditorViewModel.Slot) -> Binding<String> {
        Binding(
            get: { viewModel.hex(slot: slot) },
            set: { viewModel.setHex(slot: slot, hex: $0) }
        )
    }

    private func colorBinding(for slot: TerminalThemeEditorViewModel.Slot) -> Binding<SwiftUIColor> {
        Binding(
            get: {
                let (r, g, b) = UserTerminalTheme.parseHex(viewModel.hex(slot: slot)) ?? (0, 0, 0)
                return SwiftUIColor(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
            },
            set: { newColor in
                let nsColor = NSColor(newColor).usingColorSpace(.sRGB) ?? .black
                let r = Int((nsColor.redComponent * 255).rounded())
                let g = Int((nsColor.greenComponent * 255).rounded())
                let b = Int((nsColor.blueComponent * 255).rounded())
                viewModel.setHex(slot: slot, hex: String(format: "#%02x%02x%02x", r, g, b))
            }
        )
    }

    private func humanMessage(for error: UserTerminalTheme.ValidationError) -> String {
        switch error {
        case .invalidHex(let field, let value):
            return "\"\(value)\" isn't a valid #rrggbb color for \(field)."
        case .wrongAnsiCount(let count):
            return "Expected 16 ANSI colors, got \(count)."
        case .invalidID(let id):
            return "\"\(id)\" isn't a valid theme id (lowercase letters, digits, and hyphens only)."
        case .unsupportedSchemaVersion(let v):
            return "Theme file uses schema version \(v), which this version of TBD doesn't support."
        }
    }
}
