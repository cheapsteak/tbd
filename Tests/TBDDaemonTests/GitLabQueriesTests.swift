import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("GitLab queries and parsing")
struct GitLabQueriesTests {

    /// The exact GraphQL field set every merge-request query may ask for.
    static let expectedNodeFields =
        "iid state draft detailedMergeStatus sourceBranch targetBranch createdAt webUrl "
        + "headPipeline { status }"

    /// Runs of whitespace collapsed to one space, so a query pin survives
    /// reformatting without loosening which fields it names.
    static func normalized(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func response(_ nodes: String, gated: Bool = true) -> Data {
        Data("""
        {"data":{"project":{"onlyAllowMergeIfPipelineSucceeds":\(gated),
        "mergeRequests":{"nodes":[\(nodes)]}}}}
        """.utf8)
    }

    /// The parsed nodes, or nil when the response was refused as unreadable —
    /// so a test that expects an answer can `#require` it.
    static func answered(_ data: Data) -> (nodes: [GitLabQueries.PRNode], gated: Bool)? {
        guard case .answered(let nodes, let gated) = GitLabQueries.parseMergeRequests(from: data)
        else { return nil }
        return (nodes, gated)
    }

    static func isUnreadable(_ data: Data) -> Bool {
        if case .unreadable = GitLabQueries.parseMergeRequests(from: data) { return true }
        return false
    }

    static let oneNode = """
    {"iid":"412","state":"opened","draft":false,
     "detailedMergeStatus":"NOT_APPROVED",
     "sourceBranch":"feat/x","targetBranch":"main",
     "createdAt":"2026-08-01T10:00:00Z",
     "webUrl":"https://git.acme.example/acme/platform/api/-/merge_requests/412",
     "headPipeline":{"status":"SUCCESS"}}
    """

    @Test("the iid query emits exactly the tier-1 field set, with fullPath as a variable")
    func iidQueryShape() {
        // A whitelist, because the hazard is a field appearing, not a
        // particular field appearing: one unknown field returns data: null for
        // the whole batch, and a test naming today's forbidden fields would
        // pass on tomorrow's. Whitespace is normalized so the pin survives
        // reformatting while the field set itself stays exact.
        let q = Self.normalized(GitLabQueries.mergeRequestsByIIDQuery(iids: [412, 7]))
        #expect(q == """
        query($fullPath: ID!) { project(fullPath: $fullPath) { \
        onlyAllowMergeIfPipelineSucceeds mergeRequests(iids: ["412", "7"]) { \
        nodes { \(Self.expectedNodeFields) } } } }
        """)
    }

    @Test("the branch query JSON-escapes branch names")
    func branchQueryEscapes() {
        let q = GitLabQueries.mergeRequestsByBranchQuery(branches: ["feat/a", "weird\"name"])
        #expect(q.contains(#""feat/a""#))
        #expect(q.contains(#"weird\"name"#))
        #expect(q.contains("state: opened"))
        // The same pinned field set the iid query emits — both interpolate one
        // selection, and that is worth keeping true.
        #expect(Self.normalized(q).contains("nodes { \(Self.expectedNodeFields) }"))
    }

    @Test("parses a node into a PRNode tagged gitlab")
    func parsesNode() throws {
        let (nodes, gated) = try #require(Self.answered(Self.response(Self.oneNode)))
        #expect(gated)
        #expect(nodes.count == 1)
        let n = nodes[0]
        #expect(n.forge == .gitlab)
        #expect(n.number == 412)
        #expect(n.state == "opened")
        #expect(n.mergeVerdictRaw == "NOT_APPROVED")
        #expect(n.headRefName == "feat/x")
        #expect(n.baseRefName == "main")
        #expect(n.statusCheckRollupState == "SUCCESS")
        #expect(n.url.hasSuffix("/-/merge_requests/412"))
    }

    @Test("a null headPipeline yields a nil rollup state rather than dropping the node")
    func nullPipeline() throws {
        let node = Self.oneNode.replacingOccurrences(
            of: #""headPipeline":{"status":"SUCCESS"}"#, with: #""headPipeline":null"#)
        let (nodes, _) = try #require(Self.answered(Self.response(node)))
        #expect(nodes.count == 1)
        #expect(nodes[0].statusCheckRollupState == nil)
    }

    @Test("a null node element costs that node only, not the whole batch")
    func nullNodeElement() throws {
        // Nulling one element is how GraphQL surfaces a per-node error, and a
        // whole-array cast fails on it and discards every sibling — the defect
        // PR #208 fixed on the GitHub side. Siblings on both sides of the null
        // must survive.
        let other = Self.oneNode.replacingOccurrences(
            of: #""iid":"412""#, with: #""iid":"7""#)
        let (nodes, _) = try #require(
            Self.answered(Self.response("\(Self.oneNode), null, \(other)")))
        #expect(nodes.map(\.number) == [412, 7])
    }

    @Test("a non-gating project reports pipelineGated false")
    func nonGatingProject() throws {
        let (_, gated) = try #require(Self.answered(Self.response(Self.oneNode, gated: false)))
        #expect(!gated)
    }

    @Test("an errors-only response is unreadable, never an answered empty project")
    func errorsResponse() {
        // `data: null` is what a rejected query looks like. Reading it as "this
        // project has no merge requests" is what turns one bad token or one
        // renamed project into every worktree on it reporting no merge request.
        let data = Data(#"{"errors":[{"message":"x","extensions":{"code":"undefinedField"}}],"data":null}"#.utf8)
        #expect(Self.isUnreadable(data))
    }

    @Test("a null project is unreadable — the project rename and lost-permission shape")
    func nullProject() {
        #expect(Self.isUnreadable(Data(#"{"data":{"project":null}}"#.utf8)))
    }

    @Test("a mergeRequests block with no node list is unreadable")
    func missingNodeList() {
        let data = Data(#"{"data":{"project":{"onlyAllowMergeIfPipelineSucceeds":true,"mergeRequests":{}}}}"#.utf8)
        #expect(Self.isUnreadable(data))
    }

    @Test("an empty node list is an answer: this project genuinely has no merge requests")
    func emptyNodeList() throws {
        let (nodes, gated) = try #require(Self.answered(Self.response("")))
        #expect(nodes.isEmpty)
        #expect(gated)
    }

    @Test("garbage that is not JSON is unreadable")
    func notJSON() {
        #expect(Self.isUnreadable(Data("not json at all".utf8)))
    }

    @Test("the recheck path percent-encodes the project path and stays a GET")
    func recheckPathShape() {
        let path = GitLabQueries.recheckPath(
            projectPath: "acme/platform/backend/api-gateway", iids: [412, 7])
        #expect(path.hasPrefix("projects/acme%2Fplatform%2Fbackend%2Fapi-gateway/merge_requests?"))
        #expect(path.contains("iids%5B%5D=412"))
        #expect(path.contains("iids%5B%5D=7"))
        #expect(path.contains("with_merge_status_recheck=true"))
    }
}
