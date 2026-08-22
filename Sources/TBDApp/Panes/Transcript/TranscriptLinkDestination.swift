import AppKit
import TBDShared

/// What a clicked transcript link should do, decided as a value rather than
/// performed as a side effect.
///
/// The two render sites choose different destinations, and the choice is the
/// interesting part; returning it lets both be asserted without standing up a
/// pane. The callers below are the only places that touch AppKit or mutate a
/// layout.
enum TranscriptLinkDestination {
    /// The live pane's decision.
    enum Live: Equatable {
        case route(ViewerRouteResult)
        case openInBrowser(URL)
    }

    /// The History pane's decision. There is no layout to route into, and
    /// revealing rather than opening is a safety decision as much as a
    /// navigational one: transcript text is agent-authored, and handing a
    /// resolved path to `NSWorkspace.open` EXECUTES it when it happens to be a
    /// shell script. A URL still opens in the browser — that is what a URL is.
    enum History: Equatable {
        case revealInFinder(String)
        case openInBrowser(URL)
    }

    static func live(
        _ target: TranscriptLinkTarget, layout: LayoutNode, terminalID: UUID
    ) -> Live {
        switch target {
        case .file(let path):
            return .route(routeFileClick(into: layout, terminalID: terminalID, path: path))
        case .web(let url):
            return .openInBrowser(url)
        }
    }

    static func history(_ target: TranscriptLinkTarget) -> History {
        switch target {
        case .file(let path): return .revealInFinder(path)
        case .web(let url): return .openInBrowser(url)
        }
    }

    /// The resolver a pane hands to the compose step: the shared path rules,
    /// bound to this pane's worktree root and memoized per pane.
    ///
    /// `worktreeRoot` is read on EVERY resolve, not snapshotted. The pane's
    /// `TranscriptCardContext` is captured once by
    /// `TableTranscriptView.makeCoordinator` and never reassigned, so a
    /// snapshot taken at first evaluation is the root for the pane's whole
    /// life — and a pane restored with the panel layout evaluates before the
    /// worktree-list RPC lands, where that root is "". Reading it live lets
    /// the late row take effect; `TranscriptLinkResolverCache` drops its memo
    /// when the root changes, so answers computed against the old root are not
    /// handed out under the new one.
    ///
    /// An empty root is still an ordinary answer rather than an error: a
    /// remote or archived worktree has no local path, and relative tokens
    /// simply do not resolve there. Absolute ones do either way.
    @MainActor
    static func makeLinkResolver(
        worktreeRoot: @escaping @MainActor () -> String,
        cache: TranscriptLinkResolverCache
    ) -> TranscriptPathResolver {
        { token in
            let root = worktreeRoot()
            return cache.resolve(token, root: root) {
                ClickedPathResolver.resolve($0, worktreePath: root)
            }
        }
    }
}
