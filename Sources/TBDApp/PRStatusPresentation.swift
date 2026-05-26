import SwiftUI
import TBDShared

struct PRStatusPresentation: Equatable {
    enum ColorSemantic: Equatable {
        case neutral
        case checksFailed
        case draft
        case mergeable
        case merged
    }

    let iconName: String
    let colorSemantic: ColorSemantic

    var color: Color {
        switch colorSemantic {
        case .neutral:          return .secondary
        case .checksFailed:     return .red
        case .draft:            return .secondary
        case .mergeable:        return .green
        case .merged:           return .purple
        }
    }

    static func make(for prStatus: PRStatus?) -> PRStatusPresentation? {
        guard let prStatus else { return nil }
        switch prStatus.state {
        case .open:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .neutral)
        case .changesRequested:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .neutral)
        case .checksFailed:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .checksFailed)
        case .draft:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .draft)
        case .mergeable:
            return PRStatusPresentation(iconName: "git-pull-request", colorSemantic: .mergeable)
        case .merged:
            return PRStatusPresentation(iconName: "git-merge", colorSemantic: .merged)
        case .closed:
            return PRStatusPresentation(iconName: "git-pull-request-closed", colorSemantic: .neutral)
        }
    }
}
