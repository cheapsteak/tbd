import SwiftUI
import TBDShared

/// A sheet the native sidebar asks for, carrying the inputs its SwiftUI
/// content takes.
enum NativeSidebarSheet: Identifiable {
    /// `RemoteCreateSheet`, from a create menu item, the picker's remote row
    /// or a provider header's `+`.
    case remoteCreate(NativeSidebarRemoteCreate)
    /// `ScratchInstructionsView`, from the Scratch header's menu.
    case scratchInstructions
    /// `RemoteRemediationTerminalSheet`, from the needs-auth popover.
    case remediation(RemoteRemediationRun)

    var id: String {
        switch self {
        case .remoteCreate(let request):
            "remoteCreate|\(request.provider.config.name)|\(request.repoID?.uuidString ?? "")|"
                + (request.parentWorktreeID?.uuidString ?? "")
        case .scratchInstructions:
            "scratchInstructions"
        case .remediation(let run):
            "remediation|\(run.id)"
        }
    }
}

/// `RemoteCreateSheet`'s inputs, as `RepoSectionView`, `WorktreeRowView` and
/// `RemoteProviderHeaderRow` hand them over.
struct NativeSidebarRemoteCreate {
    let provider: RemoteProviderStatus
    var repoPrefill: String?
    var repoDefaults: [String: String] = [:]
    var parentWorktreeID: UUID?
    var repoID: UUID?
}

/// The one sheet slot of the native sidebar. The controller sets it from a
/// menu item or a button; `NativeSidebarView` presents it with SwiftUI's
/// `.sheet(item:)`, so the content's `@Environment(\.dismiss)` — its Cancel,
/// its Done, Escape, and `RemoteCreateSheet` closing itself after a create —
/// clears the slot. An `NSHostingController` presented from AppKit would not
/// answer `dismiss` at all.
///
/// One sheet at a time: a request while one is up is dropped, so a second
/// create form cannot stack on the first.
@MainActor
@Observable
final class NativeSidebarSheetPresenter {
    var sheet: NativeSidebarSheet?

    func present(_ sheet: NativeSidebarSheet) {
        guard self.sheet == nil else { return }
        self.sheet = sheet
    }

    /// What `.sheet(item:)` binds to; `dismiss` writes nil through it.
    var binding: Binding<NativeSidebarSheet?> {
        Bindable(self).sheet
    }

    /// The existing SwiftUI content for `sheet`, unchanged. It takes its
    /// environment — `AppState`, the appearance settings — from the sidebar
    /// it is presented over, as the SwiftUI sidebar's sheets do.
    @ViewBuilder
    static func content(for sheet: NativeSidebarSheet) -> some View {
        switch sheet {
        case .remoteCreate(let request):
            RemoteCreateSheet(
                provider: request.provider.config,
                describe: request.provider.describe,
                repoPrefill: request.repoPrefill,
                repoDefaults: request.repoDefaults,
                parentWorktreeID: request.parentWorktreeID,
                repoID: request.repoID)
        case .scratchInstructions:
            ScratchInstructionsView()
        case .remediation(let run):
            RemoteRemediationTerminalSheet(run: run)
        }
    }
}
