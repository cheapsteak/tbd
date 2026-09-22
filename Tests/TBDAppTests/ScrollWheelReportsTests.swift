import Testing
import AppKit
@testable import TBDApp

@Suite("Scroll monitor wheel reports")
struct ScrollWheelReportsTests {
    private typealias Coordinator = TerminalPanelRepresentable.Coordinator

    /// Regression for the composer-draft-wiping bug (#840): before mouse
    /// reporting is on, a wheel event over the ALTERNATE screen used to be
    /// handed back to AppKit unclaimed, where SwiftTerm's fallback turned it
    /// into Up/Down arrow keys — keystrokes that land on whatever is
    /// attached, wiping an in-progress draft. It must now be claimed (so it
    /// never reaches that fallback) and dropped (there is no reporting
    /// session to forward it to). `claim == false` here would reopen #840.
    @Test("mouse reporting off, alternate screen: claimed and dropped, never handed to the arrow-key fallback")
    func mouseOffAlternateClaimedAndDropped() {
        let wheel = Coordinator.wheelReports(deltaY: 3, mouseReporting: false, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 0)
    }

    /// Regression for the opposite failure: an ordinary shell prompt sits on
    /// the NORMAL screen without mouse reporting, and relies on SwiftTerm's
    /// own local scrollback to handle wheel motion. Claiming here would
    /// silently kill scrollback for every plain shell tab. `claim == true`
    /// here would reintroduce that regression.
    @Test("mouse reporting off, normal screen: not claimed, so native scrollback keeps working")
    func mouseOffNormalPassesThrough() {
        let wheel = Coordinator.wheelReports(deltaY: 3, mouseReporting: false, alternateScreen: false)
        #expect(wheel.claim == false)
        #expect(wheel.count == 0)
    }

    @Test("zero delta with mouse reporting on is claimed with no reports")
    func zeroDeltaClaimedAndDropped() {
        let wheel = Coordinator.wheelReports(deltaY: 0, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 0)
    }

    @Test("a fractional line still sends one report")
    func fractionalLineSendsOne() {
        let wheel = Coordinator.wheelReports(deltaY: 0.8, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 1)
    }

    @Test("whole lines truncate to the line count")
    func wholeLinesTruncate() {
        let wheel = Coordinator.wheelReports(deltaY: 2.4, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 2)
    }

    @Test("a negative fractional delta still sends one report")
    func negativeFractionalSendsOne() {
        let wheel = Coordinator.wheelReports(deltaY: -0.5, mouseReporting: true, alternateScreen: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 1)
    }

    /// Mouse reporting wins regardless of buffer: a normal-screen program
    /// that has turned mouse reporting on (rare, but xterm-legal) still gets
    /// its reports, exactly as an alternate-screen one does.
    @Test("mouse reporting on, normal screen: still claimed and forwarded")
    func mouseOnNormalStillForwards() {
        let wheel = Coordinator.wheelReports(deltaY: 1.0, mouseReporting: true, alternateScreen: false)
        #expect(wheel.claim == true)
        #expect(wheel.count == 1)
    }
}
