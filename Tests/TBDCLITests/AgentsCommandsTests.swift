import ArgumentParser
import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

@Suite("tbd agents background")
struct AgentsCommandsTests {

    @Test(arguments: [
        ("90s", 90), ("10m", 600), ("1h", 3600), ("2h", 7200), ("120m", 7200), ("7200s", 7200), ("1s", 1),
    ])
    func parsesTheThreeUnits(text: String, seconds: Int) {
        #expect(parseBackgroundLease(text) == seconds)
    }

    @Test(arguments: ["", "h", "10", "10x", "0s", "-5m", "1.5h", "3h", "121m", "7201s", "1 h", "m10", "99999999999999999999h"])
    func rejectsWhatIsNotAShortDurationUnderTwoHours(text: String) {
        #expect(parseBackgroundLease(text) == nil)
    }

    @Test func theLongestLeaseMatchesTheDaemonLimit() {
        #expect(parseBackgroundLease("2h") == AgentBackgroundLimits.maximumLeaseSeconds)
    }

    @Test func onRequiresADurationAndRejectsAnUnparsableOne() throws {
        #expect(throws: (any Error).self) {
            _ = try TBDCommand.parseAsRoot(["agents", "background", "on"])
        }
        let parsed = try TBDCommand.parseAsRoot(["agents", "background", "on", "--for", "10m"])
        let on = try #require(parsed as? AgentsBackground.On)
        #expect(on.duration == "10m")
        #expect(parseBackgroundLease(on.duration) == 600)
    }

    @Test func offAndStatusParse() throws {
        #expect(try TBDCommand.parseAsRoot(["agents", "background", "off"]) is AgentsBackground.Off)
        let status = try TBDCommand.parseAsRoot(["agents", "background", "status", "--json"])
        #expect((status as? AgentsBackground.Status)?.json == true)
    }

    @Test func summaryIsOneShortLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let on = AgentsBackgroundResult(
            active: true, leaseEndsAt: now.addingTimeInterval(125), loweredCount: 7)
        #expect(backgroundSummary(on, now: now)
            == "Agent background priority: on for 2m 5s more, 7 processes lowered")
        #expect(backgroundSummary(AgentsBackgroundResult(active: false), now: now)
            == "Agent background priority: off")
    }
}
