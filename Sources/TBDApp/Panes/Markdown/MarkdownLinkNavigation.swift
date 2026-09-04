import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// The containment rule every markdown surface applies before it turns an href
/// into a path on disk.
///
/// Symlinks are resolved on BOTH sides. Resolving only the candidate breaks
/// every repo that lives under a symlinked path; resolving neither lets a
/// symlink inside the repo point anywhere on disk. The trailing separator on
/// the root is what stops `/repo-secrets` passing as "inside `/repo`".
enum MarkdownWorktreeContainment {

    /// The form the rule compares against. Hoisted so a caller judging many
    /// candidates against one root pays for the `realpath` once.
    static func resolvedRoot(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Both sides already symlink-resolved.
    static func containsResolved(_ path: String, inResolvedRoot root: String) -> Bool {
        path.hasPrefix(root + "/")
    }

    /// Convenience for a caller holding raw URLs.
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        containsResolved(
            candidate.standardizedFileURL.resolvingSymlinksInPath().path,
            inResolvedRoot: resolvedRoot(root)
        )
    }
}

/// The consuming half of `MarkdownNavigationPolicy.openInPane`.
///
/// `MarkdownWebViewConfiguration.policy` is pure and knows no worktree, so the
/// most it can say about a `file:` URL is "this is a markdown file". Whether
/// that file is one this pane may render is a question only the pane can
/// answer, because only the pane knows its worktree root — so containment is
/// judged here, against the same symlink-resolved rule `MarkdownLinkResolver`
/// applies when it rewrites the href in the first place.
///
/// Both halves are load-bearing. The resolver's check is what makes an
/// in-repo link work at all; this one is what keeps anything else from
/// arriving — a hand-written `file:` destination, a future markdown source
/// that reaches the webview by some other path, a policy relaxation nobody
/// re-examined. Neither is a substitute for the other.
enum MarkdownLinkNavigation {

    /// The path the pane should select, or nil to drop the click.
    ///
    /// The returned path is the UNRESOLVED one, so the pane's selection and
    /// its header match what the sidebar shows; containment and the file
    /// checks are judged against the symlink-resolved target.
    static func target(
        for url: URL,
        worktreeRoot: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard url.isFileURL, !worktreeRoot.isEmpty else { return nil }
        let candidate = url.standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        let root = MarkdownWorktreeContainment.resolvedRoot(URL(fileURLWithPath: worktreeRoot))
        guard MarkdownWorktreeContainment.containsResolved(resolved.path, inResolvedRoot: root)
        else {
            logger.debug(
                "refused in-pane navigation outside worktree root: \(url.path, privacy: .public)")
            return nil
        }
        // A regular file, not just an existing one: a directory named
        // `notes.md` is not a document, and neither is a device node. Same
        // check `MarkdownImageInliner` makes on the image side.
        guard fileManager.fileExists(atPath: resolved.path),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }
        return candidate.path
    }
}
