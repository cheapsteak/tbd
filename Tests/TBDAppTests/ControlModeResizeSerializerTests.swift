import Testing

@testable import TBDApp

/// R5-M3: control-mode resize RPCs need latest-wins serialization — the
/// debounce collapses a drag flurry, but each `paneResize` rides its own
/// socket task, so without cross-call ordering a stale in-flight resize can be
/// processed AFTER a newer one and wedge the pane at the stale size.
@Suite("ControlModeResizeSerializer")
struct ControlModeResizeSerializerTests {

    @Test("with nothing in flight, a tick sends immediately (exactly one send)")
    func idleTickSends() {
        var serializer = ControlModeResizeSerializer()
        let send = serializer.sizeToSend(cols: 120, rows: 40)
        #expect(send == ControlModeResizeSerializer.Size(cols: 120, rows: 40))
        // The caller is now the in-flight sender; quiescent completion ends it.
        #expect(serializer.completedInFlight() == nil)
    }

    @Test("a tick while one is in flight stashes; completion sends the stash — two sends, final == latest")
    func inFlightTickStashesThenSends() {
        var serializer = ControlModeResizeSerializer()
        #expect(serializer.sizeToSend(cols: 80, rows: 24)
                == ControlModeResizeSerializer.Size(cols: 80, rows: 24))
        // Newer size arrives while the first RPC is in flight: no second
        // concurrent send — stashed instead.
        #expect(serializer.sizeToSend(cols: 200, rows: 60) == nil)
        // The in-flight call completes → the stash goes out as send #2.
        #expect(serializer.completedInFlight()
                == ControlModeResizeSerializer.Size(cols: 200, rows: 60))
        // Send #2 completes with nothing stashed → quiescent.
        #expect(serializer.completedInFlight() == nil)
    }

    @Test("a newer stash overwrites an older one — the intermediate size is never sent")
    func stashOverwrittenByNewerStash() {
        var serializer = ControlModeResizeSerializer()
        #expect(serializer.sizeToSend(cols: 80, rows: 24) != nil)
        #expect(serializer.sizeToSend(cols: 100, rows: 30) == nil)   // intermediate
        #expect(serializer.sizeToSend(cols: 150, rows: 50) == nil)   // latest wins
        #expect(serializer.completedInFlight()
                == ControlModeResizeSerializer.Size(cols: 150, rows: 50))
        #expect(serializer.completedInFlight() == nil)
    }

    @Test("after a quiescent completion, the next tick sends immediately again")
    func quiescentThenNextTickSends() {
        var serializer = ControlModeResizeSerializer()
        #expect(serializer.sizeToSend(cols: 80, rows: 24) != nil)
        #expect(serializer.completedInFlight() == nil)
        #expect(serializer.sizeToSend(cols: 90, rows: 28)
                == ControlModeResizeSerializer.Size(cols: 90, rows: 28))
    }
}
