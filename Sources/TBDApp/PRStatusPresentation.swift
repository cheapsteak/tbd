import AppKit
import SwiftUI
import TBDShared

struct PRStatusPresentation: Equatable {
    enum ColorSemantic: Equatable {
        case pending
        case nonMergeable
        case draft
        case mergeable
        case merged
    }

    let iconName: String
    let colorSemantic: ColorSemantic

    var color: Color {
        switch colorSemantic {
        case .pending:
            // Light: GitHub WIP olive #936921 — readable on light sidebar (~#F1F1F1).
            // Dark:  GitHub attention.fg #D29922 — readable on dark sidebar (~#1E1E1E).
            return adaptiveColor(
                light: NSColor(srgbRed: 147 / 255, green: 105 / 255, blue: 33 / 255, alpha: 1),
                dark: NSColor(srgbRed: 210 / 255, green: 153 / 255, blue: 34 / 255, alpha: 1)
            )
        case .nonMergeable:     return .red
        case .draft:            return .secondary
        case .mergeable:
            // Light: muted forest #3D7D40.
            // Dark:  GitHub success.fg #3FB950.
            return adaptiveColor(
                light: NSColor(srgbRed: 61 / 255, green: 125 / 255, blue: 64 / 255, alpha: 1),
                dark: NSColor(srgbRed: 63 / 255, green: 185 / 255, blue: 80 / 255, alpha: 1)
            )
        case .merged:           return .purple
        }
    }

    static func make(for prStatus: PRStatus?) -> PRStatusPresentation? {
        guard let prStatus else { return nil }
        switch prStatus.state {
        case .pending:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .pending)
        case .blocked:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .nonMergeable)
        case .changesRequested:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .nonMergeable)
        case .checksFailed:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .nonMergeable)
        case .draft:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .draft)
        case .mergeable:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .mergeable)
        case .merged:
            return PRStatusPresentation(iconName: "git-merge", colorSemantic: .merged)
        case .closed:
            return PRStatusPresentation(iconName: "git-pull-request-closed", colorSemantic: .nonMergeable)
        }
    }
}
