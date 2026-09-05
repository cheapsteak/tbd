import Foundation

/// A fresh scratch root for a fixture that needs a directory of its own,
/// minted under the per-run root `scripts/test.sh` reclaims.
///
/// **Why the run root and not `/tmp`.** These fixtures are torn down in
/// process, and in-process teardown is exactly what a killed or crashed test
/// process cannot run: several fixtures in flight at once all lose their
/// teardown together, and a root under `/tmp` then survives forever with
/// nobody to remove it. The wrapper already has the kill-proof half — its
/// `trap cleanup EXIT` does `rm -rf` on the run's scratch dir even when the
/// wrapper is TERMed — and `TBD_TEST_SCRATCH_ROOT` names that dir so a fixture
/// can put its root inside it and inherit the guarantee.
///
/// **Why not under `TBD_HOME`.** The callers here bind a rendezvous socket at
/// `<root>/holders/<36-char uuid>.sock`, against a `sun_path` cap of
/// `HolderRendezvous.sunPathLimit` bytes. The fenced `TBD_HOME` is
/// `<run root>/sanctioned/tbd`, and nesting there spends the budget:
/// `/tmp/tbd-test-home.XXXXXXXX/sanctioned/tbd/<prefix>-xxxxxxxx/holders/<uuid>.sock`
/// is 106 to 108 bytes across the four prefixes in use — 106 for `tbdh`, 107
/// for `tbdh6` and `tbdh7`, 108 for `tbdg10` — and fails the bind at every one
/// of them. Directly under the run root the same path is 91 to 93 bytes,
/// leaving headroom. So the root is short on purpose, and it is short *and* fenced
/// only because the wrapper names the run root separately.
///
/// **The `/tmp` fallback** covers a run that is not fenced at all — SwiftPM
/// invoked directly rather than through `scripts/test.sh`. That is the
/// pre-existing behavior, leak included; the fence is what fixes it, not this
/// default. An empty `TBD_TEST_SCRATCH_ROOT` is no more a fence than a missing
/// one and takes the same fallback: read literally it would mint the root in
/// the root of the volume.
///
/// The environment is an injection seam rather than a `setenv`: test targets
/// compile into one process and Swift Testing runs their suites in parallel,
/// so a process-wide mutation races every concurrent suite.
///
/// - Parameters:
///   - prefix: Names the fixture in the directory listing. Kept short — every
///     byte of it comes out of the `sun_path` budget above.
///   - environment: Where `TBD_TEST_SCRATCH_ROOT` is read from.
/// - Returns: A path that does not exist yet; the caller creates it.
public func fencedScratchRoot(
    prefix: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    let fenced = environment["TBD_TEST_SCRATCH_ROOT"] ?? ""
    let root = fenced.isEmpty ? "/tmp" : fenced
    return "\(root)/\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
}
