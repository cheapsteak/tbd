import Foundation
import os

/// GraphQL construction and response parsing for GitLab merge requests.
///
/// Every field requested here exists on every GitLab edition and predates any
/// instance likely to be in service. That is load-bearing: GraphQL rejects the
/// whole query for one unknown field, returning `data: null`, which on a
/// batched read turns a single schema mismatch into zero merge requests.
enum GitLabQueries {
    /// Parsing produces the same node type the `gh` layer produces, so the
    /// heal, map and persist logic downstream is forge-agnostic.
    typealias PRNode = PRStatusManager.PRNode

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "pr.gitlab")

    /// The tier-1 selection. `headPipeline { status }` rides along in the same
    /// batch — the fact GitHub needs a separate per-PR check query for.
    static let nodeSelection = """
    iid state draft detailedMergeStatus conflicts
    sourceBranch targetBranch createdAt webUrl
    headPipeline { status }
    """

    /// One batched read of several merge requests by iid.
    ///
    /// iids are Int literals, so they are injection-safe by construction — the
    /// same reason GitHub's `numberedPRQuery` embeds numbers rather than
    /// binding them. `fullPath` is a variable because it is user data.
    static func mergeRequestsByIIDQuery(iids: [Int]) -> String {
        let list = iids.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        query($fullPath: ID!) {
          project(fullPath: $fullPath) {
            onlyAllowMergeIfPipelineSucceeds
            mergeRequests(iids: [\(list)]) {
              nodes { \(nodeSelection) }
            }
          }
        }
        """
    }

    /// Branch matching, server-side and author-blind — so a merge request
    /// opened by anyone, including through the web UI, is still found.
    static func mergeRequestsByBranchQuery(branches: [String]) -> String {
        let list = branches.map(jsonQuoted).joined(separator: ", ")
        return """
        query($fullPath: ID!) {
          project(fullPath: $fullPath) {
            onlyAllowMergeIfPipelineSucceeds
            mergeRequests(sourceBranches: [\(list)], state: opened) {
              nodes { \(nodeSelection) }
            }
          }
        }
        """
    }

    private static func jsonQuoted(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// What one GraphQL response settled.
    ///
    /// The two cases are the whole point of the type. "The project answered and
    /// listed no merge requests" is a fact about the project; "the response did
    /// not carry a project at all" is the forge failing to answer, and letting
    /// the second read as the first turns a rename, or a token that lost
    /// `read_api` on one project, into "no merge request here" for every
    /// worktree on it — silently and permanently.
    enum ParseOutcome {
        /// The response carried a project. `nodes` may legitimately be empty.
        case answered(nodes: [PRNode], pipelineGated: Bool)
        /// The response could not be understood: unparseable JSON, `data: null`,
        /// a null project, or a `mergeRequests` block with no node list. The
        /// caller must record this as undetermined, never as no merge request.
        case unreadable
    }

    /// Never throws — a poll must not be interrupted by a bad response, so the
    /// failure is returned rather than raised.
    static func parseMergeRequests(from data: Data) -> ParseOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.warning("GitLab GraphQL response was not a JSON object")
            return .unreadable
        }
        let errorCodes = (root["errors"] as? [[String: Any]] ?? [])
            .compactMap { ($0["extensions"] as? [String: Any])?["code"] as? String }
        guard let dataObj = root["data"] as? [String: Any],
              let project = dataObj["project"] as? [String: Any],
              let mrs = project["mergeRequests"] as? [String: Any],
              let raw = mrs["nodes"] as? [Any] else {
            // Warning, not debug: this is the shape a project rename or a
            // per-project permission loss takes, and it degrades a whole
            // project's worth of worktrees at once.
            log.warning("GitLab GraphQL response carried no merge request list; errors: \(errorCodes.joined(separator: ","), privacy: .public)")
            return .unreadable
        }
        if !errorCodes.isEmpty {
            // Partial data: the list is present, so it is used, the same way
            // the `gh` by-number arm uses partial stdout.
            log.debug("GitLab GraphQL errors alongside usable data: \(errorCodes.joined(separator: ","), privacy: .public)")
        }
        let gated = project["onlyAllowMergeIfPipelineSucceeds"] as? Bool ?? false
        // Element-wise, because a `[[String: Any]]` cast fails whole: one null
        // element — how GraphQL reports a per-node error — would discard every
        // sibling node. Same shape as the `gh` parser after PR #208.
        let nodes = raw.compactMap { $0 as? [String: Any] }.compactMap(node(from:))
        return .answered(nodes: nodes, pipelineGated: gated)
    }

    static func node(from obj: [String: Any]) -> PRNode? {
        guard let iidString = obj["iid"] as? String, let iid = Int(iidString),
              let state = obj["state"] as? String,
              let url = obj["webUrl"] as? String else { return nil }
        // A null headPipeline is normal on very old merge requests; it means
        // "no CI signal", not "malformed node".
        let pipeline = (obj["headPipeline"] as? [String: Any])?["status"] as? String
        return PRNode(
            number: iid,
            url: url,
            state: state,
            mergeVerdictRaw: obj["detailedMergeStatus"] as? String ?? "",
            reviewVerdictRaw: "",
            headRefName: obj["sourceBranch"] as? String ?? "",
            createdAt: obj["createdAt"] as? String ?? "",
            isDraft: obj["draft"] as? Bool ?? false,
            statusCheckRollupState: pipeline,
            mergeQueuePosition: nil,
            baseRefName: obj["targetBranch"] as? String ?? "",
            forge: .gitlab)
    }

    /// The REST path that asks GitLab to recompute mergeability.
    ///
    /// GitLab computes mergeability asynchronously and does not recompute on
    /// read, so a merge request can report UNCHECKED indefinitely. GraphQL has
    /// no equivalent argument; REST's list endpoint does. Scoped to bound
    /// merge requests only, because it queues background work on someone
    /// else's server. Params live in the path so the request stays a GET —
    /// `glab api` switches to POST as soon as a `-f` field is present.
    static func recheckPath(projectPath: String, iids: [Int]) -> String {
        let encoded = projectPath.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? projectPath
        let params = iids.map { "iids%5B%5D=\($0)" } + ["with_merge_status_recheck=true"]
        return "projects/\(encoded)/merge_requests?" + params.joined(separator: "&")
    }
}
