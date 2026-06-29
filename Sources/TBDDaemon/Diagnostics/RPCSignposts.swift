import os

/// Signpost regions emitted by the daemon's RPC server.
///
/// Use Instruments (or `xctrace`) with the "com.tbd.daemon" / "perf-rpc"
/// signpost subsystem to inspect these intervals.
///
/// Regions:
/// - `rpc.handle` — one interval per non-subscribe RPC, spanning the call to
///   `RPCRouter.handleRaw`. The interval's message carries the RPC method name,
///   so a storm of overlapping `pr.list` calls shows up as a pile of
///   concurrent `rpc.handle` intervals tagged `pr.list`.
enum RPCSignposts {
    static let signposter = OSSignposter(subsystem: "com.tbd.daemon", category: "perf-rpc")
}
