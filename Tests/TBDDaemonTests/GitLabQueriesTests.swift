import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("GitLab queries and parsing")
struct GitLabQueriesTests {

    static func response(_ nodes: String, gated: Bool = true) -> Data {
        Data("""
        {"data":{"project":{"onlyAllowMergeIfPipelineSucceeds":\(gated),
        "mergeRequests":{"nodes":[\(nodes)]}}}}
        """.utf8)
    }

    static let oneNode = """
    {"iid":"412","state":"opened","draft":false,
     "detailedMergeStatus":"NOT_APPROVED","conflicts":false,
     "sourceBranch":"feat/x","targetBranch":"main",
     "createdAt":"2026-08-01T10:00:00Z",
     "webUrl":"https://git.acme.example/acme/platform/api/-/merge_requests/412",
     "headPipeline":{"status":"SUCCESS"}}
    """

    @Test("the iid query embeds validated integers and takes fullPath as a variable")
    func iidQueryShape() {
        let q = GitLabQueries.mergeRequestsByIIDQuery(iids: [412, 7])
        #expect(q.contains(#"iids: ["412", "7"]"#))
        #expect(q.contains("$fullPath: ID!"))
        #expect(q.contains("onlyAllowMergeIfPipelineSucceeds"))
        #expect(q.contains("headPipeline { status }"))
        // No paid-tier field may appear: one unknown field returns data: null
        // for the whole batch.
        #expect(!q.contains("mergeTrainCar"))
        #expect(!q.contains("approvalsRequired"))
        #expect(!q.contains("externalStatusChecks"))
    }

    @Test("the branch query JSON-escapes branch names")
    func branchQueryEscapes() {
        let q = GitLabQueries.mergeRequestsByBranchQuery(branches: ["feat/a", "weird\"name"])
        #expect(q.contains(#""feat/a""#))
        #expect(q.contains(#"weird\"name"#))
        #expect(q.contains("state: opened"))
    }

    @Test("parses a node into a PRNode tagged gitlab")
    func parsesNode() {
        let (nodes, gated) = GitLabQueries.parseMergeRequests(from: Self.response(Self.oneNode))
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
    func nullPipeline() {
        let node = Self.oneNode.replacingOccurrences(
            of: #""headPipeline":{"status":"SUCCESS"}"#, with: #""headPipeline":null"#)
        let (nodes, _) = GitLabQueries.parseMergeRequests(from: Self.response(node))
        #expect(nodes.count == 1)
        #expect(nodes[0].statusCheckRollupState == nil)
    }

    @Test("a non-gating project reports pipelineGated false")
    func nonGatingProject() {
        let (_, gated) = GitLabQueries.parseMergeRequests(
            from: Self.response(Self.oneNode, gated: false))
        #expect(!gated)
    }

    @Test("an errors-only response yields no nodes and does not throw")
    func errorsResponse() {
        let data = Data(#"{"errors":[{"message":"x","extensions":{"code":"undefinedField"}}],"data":null}"#.utf8)
        let (nodes, gated) = GitLabQueries.parseMergeRequests(from: data)
        #expect(nodes.isEmpty)
        #expect(!gated)
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
