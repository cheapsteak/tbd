import SwiftUI
import TBDShared

struct RepoDetailView: View {
    let repoID: UUID

    enum Tab: String, CaseIterable {
        case archived = "Archived"
        case instructions = "Instructions"
    }

    @State private var selectedTab: Tab = .archived

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .padding(.vertical, 12)

            Divider()

            switch selectedTab {
            case .archived:
                ArchivedWorktreesView(repoID: repoID)
            case .instructions:
                RepoInstructionsView(repoID: repoID)
                    .id(repoID)
            }
        }
    }
}
