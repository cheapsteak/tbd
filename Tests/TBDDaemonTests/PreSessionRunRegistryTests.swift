import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("Pre-session run registry")
struct PreSessionRunRegistryTests {

    @Test("begin claims an id exactly once")
    func beginIsExclusive() async {
        let registry = PreSessionRunRegistry()
        let id = UUID()

        #expect(await registry.begin(id) == true)
        #expect(await registry.begin(id) == false)
        #expect(await registry.isRunning(id) == true)
    }

    @Test("end releases the claim so a later run can begin")
    func endReleases() async {
        let registry = PreSessionRunRegistry()
        let id = UUID()

        _ = await registry.begin(id)
        await registry.end(id)

        #expect(await registry.isRunning(id) == false)
        #expect(await registry.begin(id) == true)
    }

    @Test("claims are per worktree id")
    func claimsAreIndependent() async {
        let registry = PreSessionRunRegistry()
        let a = UUID()
        let b = UUID()

        #expect(await registry.begin(a) == true)
        #expect(await registry.begin(b) == true)
        #expect(await registry.isRunning(a) == true)
        #expect(await registry.isRunning(b) == true)
    }
}
