import Foundation
import Testing
@testable import TBDDaemonLib

/// `raiseFileDescriptorLimit()` must lift the soft limit toward 524,288
/// (capped by the hard limit) and never throw.
@Test func testRaiseFileDescriptorLimitRaisesSoftLimit() {
    let result = Daemon.raiseFileDescriptorLimit()

    var current = rlimit()
    #expect(getrlimit(RLIMIT_NOFILE, &current) == 0)

    let target = min(current.rlim_max, rlim_t(524_288))
    #expect(current.rlim_cur >= target,
            "soft limit must be at least min(hard, 524_288) after the call")
    #expect(result.rlim_cur == current.rlim_cur,
            "returned limit must match the live process limit")
}

/// The soft limit must never exceed the hard limit (which a process cannot
/// raise without privilege).
@Test func testRaiseFileDescriptorLimitNeverExceedsHardLimit() {
    let result = Daemon.raiseFileDescriptorLimit()
    #expect(result.rlim_cur <= result.rlim_max)
}
