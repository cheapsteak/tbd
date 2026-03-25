import SwiftUI

// Temporary stub — will be replaced in Task 7
struct CodeViewerPaneView: View {
    let path: String
    let worktreePath: String
    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
