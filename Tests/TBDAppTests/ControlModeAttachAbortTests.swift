import Foundation
import Testing
@testable import TBDApp

/// Unit tests for the in-flight-attach vs view-teardown decision (review H2).
/// The coordinator wiring itself (Task resumption inside
/// `startControlModeClient`) is UI-lifecycle-driven and not constructible
/// headlessly — these pin the decision table each resumption consults.
@Suite("ControlModeAttachAbort")
struct ControlModeAttachAbortTests {

    @Test("no teardown: no abort at any stage")
    func noTeardownNoAbort() {
        for stage in ControlModeAttachAbort.Stage.allCases {
            #expect(ControlModeAttachAbort.undo(tornDown: false, at: stage) == nil,
                    "stage \(stage) must not abort a healthy attach")
        }
    }

    @Test("teardown while openAttach was in flight: close the raw fd, no reader to remove")
    func teardownDuringOpenAttach() {
        let undo = ControlModeAttachAbort.undo(tornDown: true, at: .openAttachResolved)
        #expect(undo == ControlModeAttachAbort.Undo(closeFD: true, removeReader: false))
    }

    @Test("teardown while the reader registration was in flight: the registry owns the fd")
    func teardownDuringReaderRegistration() {
        let undo = ControlModeAttachAbort.undo(tornDown: true, at: .readerRegistered)
        #expect(undo == ControlModeAttachAbort.Undo(closeFD: false, removeReader: true))
    }

    @Test("teardown while attach.ready was in flight: reader removal, never a double close")
    func teardownDuringAttachReady() {
        let undo = ControlModeAttachAbort.undo(tornDown: true, at: .attachReadyAcked)
        #expect(undo == ControlModeAttachAbort.Undo(closeFD: false, removeReader: true))
    }

    @Test("exactly one fd owner per abort: closeFD and removeReader are mutually exclusive")
    func singleFDOwner() {
        for stage in ControlModeAttachAbort.Stage.allCases {
            let undo = ControlModeAttachAbort.undo(tornDown: true, at: stage)
            #expect(undo != nil, "teardown must abort at every stage")
            if let undo {
                #expect(undo.closeFD != undo.removeReader,
                        "stage \(stage): the fd must have exactly one closer")
            }
        }
    }

    @Test("fallback PTY starts only while the view is alive")
    func fallbackGate() {
        #expect(ControlModeAttachAbort.shouldStartFallback(tornDown: false) == true)
        #expect(ControlModeAttachAbort.shouldStartFallback(tornDown: true) == false)
    }
}
