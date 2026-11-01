import Foundation
import Testing
@testable import TBDApp

// Tier 1: deterministic, in-process state only. The lookup is a stub held on
// a main-actor gate (`PanelCallGate`), so no Launch Services query runs and
// nothing sleeps.

/// One view's Open With lookups (`OpenWithAppsLookup`): at most one in
/// flight, a result dropped once its view has moved to another file or gone,
/// and no hover lookup while one for the same file is still in flight.
@Suite("Open With lookups")
@MainActor
struct OpenWithAppsLookupTests {
    private static let slowPath = "/w/slow.md"
    private static let fastPath = "/w/fast.md"
    private static let slowApps: [OpenWithApp] = [OpenWithApp(url: URL(fileURLWithPath: "/Applications/Slow.app"))]
    private static let fastApps: [OpenWithApp] = [OpenWithApp(url: URL(fileURLWithPath: "/Applications/Fast.app"))]

    /// A lookup whose answer for `slowPath` waits on `gate`, recording each
    /// path it is asked for in `log`.
    private static func makeLookup(gate: PanelCallGate, log: PanelEventLog) -> OpenWithAppsLookup {
        OpenWithAppsLookup { @MainActor path in
            log.record(path)
            if path == Self.slowPath {
                await gate.wait()
                return Self.slowApps
            }
            return Self.fastApps
        }
    }

    @Test("a slow lookup for a file the view has left never overwrites the list for the file it shows now")
    func staleLookupIsDropped() async throws {
        let gate = PanelCallGate()
        let log = PanelEventLog()
        let lookup = Self.makeLookup(gate: gate, log: log)

        lookup.show(path: Self.slowPath)
        await PanelTabsFixture.drainMainActor()
        try #require(gate.isHolding, "precondition: the first file's lookup is in flight")
        lookup.show(path: Self.fastPath)
        await PanelTabsFixture.drainMainActor()
        #expect(lookup.apps == Self.fastApps)

        gate.release()
        await PanelTabsFixture.drainMainActor()

        #expect(lookup.apps == Self.fastApps, "the first file's late answer replaced the list")
        let asked: [String] = [Self.slowPath, Self.fastPath]
        #expect(log.events == asked)
    }

    @Test("a hover while a lookup for the same file is in flight starts none; one after it lands looks again")
    func hoverDuringALookupStartsNone() async throws {
        let gate = PanelCallGate()
        let log = PanelEventLog()
        let lookup = Self.makeLookup(gate: gate, log: log)

        lookup.show(path: Self.slowPath)
        await PanelTabsFixture.drainMainActor()
        try #require(gate.isHolding, "precondition: the lookup is in flight")
        lookup.pointerEntered()
        await PanelTabsFixture.drainMainActor()
        let whileInFlight: [String] = [Self.slowPath]
        #expect(log.events == whileInFlight, "a hover started a second lookup for the same file")

        gate.release()
        await PanelTabsFixture.drainMainActor()
        #expect(lookup.apps == Self.slowApps)

        lookup.pointerEntered()
        await PanelTabsFixture.drainMainActor()
        let afterLanding: [String] = [Self.slowPath, Self.slowPath]
        #expect(log.events == afterLanding, "a hover after the lookup landed looks again")
    }

    @Test("a lookup in flight when its view disappears is dropped")
    func stopDropsTheLookup() async throws {
        let gate = PanelCallGate()
        let log = PanelEventLog()
        let lookup = Self.makeLookup(gate: gate, log: log)

        lookup.show(path: Self.slowPath)
        await PanelTabsFixture.drainMainActor()
        try #require(gate.isHolding, "precondition: the lookup is in flight")
        lookup.stop()
        gate.release()
        await PanelTabsFixture.drainMainActor()

        #expect(lookup.apps.isEmpty, "a lookup cancelled by its view's disappearance wrote its answer")
    }

    @Test("a view with no file empties its list and looks nothing up, even on hover")
    func noFileLooksNothingUp() async {
        let gate = PanelCallGate()
        let log = PanelEventLog()
        let lookup = Self.makeLookup(gate: gate, log: log)
        lookup.show(path: Self.fastPath)
        await PanelTabsFixture.drainMainActor()
        #expect(lookup.apps == Self.fastApps)

        lookup.show(path: nil)
        lookup.pointerEntered()
        await PanelTabsFixture.drainMainActor()

        #expect(lookup.apps.isEmpty)
        let asked: [String] = [Self.fastPath]
        #expect(log.events == asked)
    }
}
