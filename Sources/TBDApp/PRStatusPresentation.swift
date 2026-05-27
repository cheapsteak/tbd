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
        case .pending:          return Color(red: 147 / 255, green: 105 / 255, blue: 33 / 255)
        case .nonMergeable:     return .red
        case .draft:            return .secondary
        case .mergeable:        return Color(red: 61 / 255, green: 125 / 255, blue: 64 / 255)
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
