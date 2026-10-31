/// Whether a Claude usage bucket is model-scoped rather than a plan-wide
/// limit. `ClaudeUsagePayloadParser` drops such buckets as it parses, and its
/// type comment says why; the usage snapshot store strips them from the rows
/// it loads.
enum ClaudeUsageBucketScope {
    /// The API's per-model-family weekly bucket kind. Dropped by
    /// `parseBuckets` — see the type comment.
    static let weeklyScopedKind = "weekly_scoped"

    /// True for a bucket that is not a plan-wide limit: the `weekly_scoped`
    /// kind, or any bucket the API scoped to a single model.
    static func isModelScoped(kind: String, modelDisplayName: String?) -> Bool {
        kind == weeklyScopedKind || modelDisplayName != nil
    }
}
