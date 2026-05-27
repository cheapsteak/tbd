import Foundation
import Combine
import SwiftUI

@MainActor
final class TerminalThemeEditorViewModel: ObservableObject {

    enum SourceKind { case bundled, user }

    enum Slot: Hashable {
        case foreground, background, cursor, selection, ansi(Int)
    }

    private(set) var source: TerminalColorScheme = ColorSchemes.defaultScheme
    private(set) var sourceKind: SourceKind = .bundled

    @Published private(set) var draftHex: [Slot: String] = [:]
    @Published private(set) var displayNameDraft: String?
    @Published private(set) var lastValidationError: UserTerminalTheme.ValidationError?

    var isDirty: Bool { !draftHex.isEmpty || displayNameDraft != nil }
    var canReset: Bool { isDirty }
    var canSaveAs: Bool { true }
    var canSave: Bool { isDirty && sourceKind == .user }

    func load(source: TerminalColorScheme, kind: SourceKind) {
        self.source = source
        self.sourceKind = kind
        self.draftHex = [:]
        self.displayNameDraft = nil
        self.lastValidationError = nil
    }

    func hex(slot: Slot) -> String {
        if let drafted = draftHex[slot] { return drafted }
        switch slot {
        case .foreground: return UserTerminalTheme.hex(from: source.foreground)
        case .background: return UserTerminalTheme.hex(from: source.background)
        case .cursor:     return UserTerminalTheme.hex(from: source.cursor)
        case .selection:  return UserTerminalTheme.hex(from: source.selection)
        case .ansi(let i): return UserTerminalTheme.hex(from: source.ansi[i])
        }
    }

    var displayName: String { displayNameDraft ?? source.displayName }

    func setDisplayName(_ name: String) {
        displayNameDraft = (name == source.displayName) ? nil : name
    }

    func setHex(slot: Slot, hex: String) {
        guard UserTerminalTheme.parseHex(hex) != nil else {
            lastValidationError = .invalidHex(field: "\(slot)", value: hex)
            return
        }
        lastValidationError = nil
        let srcHex: String
        switch slot {
        case .foreground: srcHex = UserTerminalTheme.hex(from: source.foreground)
        case .background: srcHex = UserTerminalTheme.hex(from: source.background)
        case .cursor:     srcHex = UserTerminalTheme.hex(from: source.cursor)
        case .selection:  srcHex = UserTerminalTheme.hex(from: source.selection)
        case .ansi(let i): srcHex = UserTerminalTheme.hex(from: source.ansi[i])
        }
        if hex == srcHex {
            draftHex.removeValue(forKey: slot)
        } else {
            draftHex[slot] = hex
        }
    }

    func reset() {
        draftHex = [:]
        displayNameDraft = nil
        lastValidationError = nil
    }

    /// Revert a single slot's draft back to the source value. No-op if the slot
    /// isn't currently drafted.
    func unsetSlot(_ slot: Slot) {
        draftHex.removeValue(forKey: slot)
        // Don't touch displayNameDraft or lastValidationError — those are scoped
        // to other affordances.
    }

    /// Whether the given slot currently has a draft override.
    func isSlotDirty(_ slot: Slot) -> Bool {
        draftHex[slot] != nil
    }

    func snapshot(id: String) -> UserTerminalTheme {
        UserTerminalTheme(
            schemaVersion: 1,
            id: id,
            displayName: displayName,
            ansi: (0..<16).map { hex(slot: .ansi($0)) },
            foreground: hex(slot: .foreground),
            background: hex(slot: .background),
            cursor: hex(slot: .cursor),
            selection: hex(slot: .selection)
        )
    }
}
