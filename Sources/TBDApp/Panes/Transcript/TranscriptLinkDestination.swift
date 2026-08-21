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
    /// `worktreePath` is a VALUE snapshot, frozen for the life of the pane's
    /// table: `TableTranscriptView.makeCoordinator` captures the whole
    /// `TranscriptCardContext` once, and `updateNSView` never hands the
    /// coordinator a fresher one. It is safe because the only pane that builds
    /// this resolver, `PanePlaceholder`, is constructed with the worktree it
    /// renders, so the row is already present on the first evaluation — an
    /// empty root there means the worktree is remote, which is permanent
    /// rather than transient. A root that started empty and filled in later
    /// would NOT recover: every relative token would resolve to nil against
    /// the empty root and the miss would be memoized in a cache nothing
    /// invalidates, leaving relative paths plain text for the pane's life.
    @MainActor
    static func makeLinkResolver(
        worktreePath: String,
        cache: TranscriptLinkResolverCache
    ) -> TranscriptPathResolver {
        { token in
            cache.resolve(token) { ClickedPathResolver.resolve($0, worktreePath: worktreePath) }
        }
    }
}
