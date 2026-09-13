import Testing
import AppKit
@testable import TBDApp

@Suite("Scroll monitor wheel reports")
struct ScrollWheelReportsTests {
    private typealias Coordinator = TerminalPanelRepresentable.Coordinator

    @Test("mouse reporting off: the event is not claimed")
    func mouseOffNotClaimed() {
        let wheel = Coordinator.wheelReports(deltaY: 3, mouseReporting: false)
        #expect(wheel.claim == false)
        #expect(wheel.count == 0)
    }

    @Test("zero delta with mouse reporting on is claimed with no reports")
    func zeroDeltaClaimedAndDropped() {
        let wheel = Coordinator.wheelReports(deltaY: 0, mouseReporting: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 0)
    }

    @Test("a fractional line still sends one report")
    func fractionalLineSendsOne() {
        let wheel = Coordinator.wheelReports(deltaY: 0.8, mouseReporting: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 1)
    }

    @Test("whole lines truncate to the line count")
    func wholeLinesTruncate() {
        let wheel = Coordinator.wheelReports(deltaY: 2.4, mouseReporting: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 2)
    }

    @Test("a negative fractional delta still sends one report")
    func negativeFractionalSendsOne() {
        let wheel = Coordinator.wheelReports(deltaY: -0.5, mouseReporting: true)
        #expect(wheel.claim == true)
        #expect(wheel.count == 1)
    }
}
