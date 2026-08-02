import TBDShared

extension RPCRouter {
    func handleCodexUsageFetch() async throws -> RPCResponse {
        try RPCResponse(result: await CodexUsageFetcher().fetch())
    }
}
