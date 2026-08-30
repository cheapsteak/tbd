import AppKit
import Foundation
import TestSupport
import SwiftTerm
import Testing
@testable import TBDApp

/// SwiftTerm 2.0 migration round-trips
/// (docs/specs/2026-08-28-swiftterm-2-locked-terminal-access-design.md).
///
/// Everything here goes through the production `feed()` path — no hand-built
/// terminal state — because the migration moved every buffer read under
/// `withTerminal { ... }` and re-plumbed notifications from the deleted
/// `notify` override onto `Terminal.observeOscEvents`. These tests fail if
/// that wiring is absent: the OSC 8 read returns nothing without the locked
/// `getLine`/`getPayload` walk, the 777 test's continuation never resumes
/// without a stored observation token, and the off-main feed exercises the
/// IO-thread delivery path `directDelivery: true` puts `dataReceived` on.
@MainActor
@Suite("SwiftTerm 2.0 locked terminal access")
struct TerminalLockedAccessTests {

    /// Isolated defaults: AppearanceSettings must never read/write the
    /// developer's real TBDApp.plist (Tests-must-not-touch-~/tbd rule's
    /// UserDefaults twin). Same idiom as DragDropPasteRoutingTests.
    private func withView(_ body: (TBDTerminalView) throws -> Void) rethrows {
        let defaultsSuite = TestDefaultsSuite("LockedAccess")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        try body(view)
    }

    private func makeView() -> TBDTerminalView {
        let defaultsSuite = TestDefaultsSuite("LockedAccess")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        return TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
    }

    /// Window point at the center of grid cell (col, row) for a view with no
    /// window (convert(_:from: nil) is then the identity for a frame at the
    /// origin).
    private func point(col: Int, row: Int, in view: TBDTerminalView) -> CGPoint {
        let cell = view.cellDimensions()
        return CGPoint(
            x: (CGFloat(col) + 0.5) * cell.width,
            y: view.bounds.height - (CGFloat(row) + 0.5) * cell.height)
    }

    // MARK: - OSC 8 round-trip (the #113 dedup guard's locked read)

    @Test("OSC 8 payload fed through feed() is visible to hasOSC8Payload at that cell — and only there")
    func osc8PayloadRoundTrip() {
        withView { view in
            // Anchor text "LINK" carries the payload; " plain" after the
            // closing OSC 8 does not.
            let bytes = "\u{1B}]8;;https://example.com/doc\u{07}LINK\u{1B}]8;;\u{07} plain"
            view.feed(byteArray: [UInt8](bytes.utf8)[...])

            // Cell inside the anchor text.
            #expect(view.hasOSC8Payload(atWindowLocation: point(col: 1, row: 0, in: view)))
            // Cell in the plain trailing text: the guard must NOT stand the
            // monitor down there — this is what makes the test discriminate
            // payload presence rather than pass on any non-nil answer.
            #expect(!view.hasOSC8Payload(atWindowLocation: point(col: 8, row: 0, in: view)))
        }
    }

    /// `extractHyperlinkURL` is the residual non-OSC-8 recognizer (PR #123
    /// pattern) — the other buffer read that moved under the lock. Fed
    /// through the production parse path like everything else.
    @Test("PR #123 fed through feed() resolves to the repo's pull URL via the locked row read")
    func prPatternRoundTrip() {
        withView { view in
            view.remoteURL = "git@github.com:acme/repo.git"
            view.feed(byteArray: [UInt8]("See PR #123 for details".utf8)[...])

            let url = view.extractHyperlinkURL(atWindowLocation: point(col: 2, row: 0, in: view))
            #expect(url == "https://github.com/acme/repo/pull/123")
        }
    }

    // MARK: - OSC 777 → onNotification (the notify-override replacement)

    @Test("OSC 777 notify fed through feed() reaches onNotification with title and body",
          .timeLimit(.minutes(1)))
    func osc777RoutesToOnNotification() async {
        let view = makeView()
        let (title, body): (String, String) = await withCheckedContinuation { continuation in
            view.onNotification = { title, body in
                continuation.resume(returning: (title, body))
            }
            // The not-key-window guard passes: a test view has no window.
            // Body deliberately contains a ';' to pin upstream's parse
            // (body = parts[2...] rejoined).
            view.feed(byteArray: [UInt8]("\u{1B}]777;notify;Build done;3 warnings; 0 errors\u{07}".utf8)[...])
        }
        #expect(title == "Build done")
        #expect(body == "3 warnings; 0 errors")
    }

    /// The payload parse alone (mirrors upstream `oscNotification`): non-notify
    /// 777 payloads must not fire.
    @Test func notifyPayloadParse() {
        #expect(TBDTerminalView.parseNotifyPayload([UInt8]("notify;T;B".utf8))! == ("T", "B"))
        #expect(TBDTerminalView.parseNotifyPayload([UInt8]("notify;T;B;C".utf8))! == ("T", "B;C"))
        #expect(TBDTerminalView.parseNotifyPayload([UInt8]("other;T;B".utf8)) == nil)
        #expect(TBDTerminalView.parseNotifyPayload([UInt8]("notify;T".utf8)) == nil)
    }

    // MARK: - Off-main feed (the IO-thread delivery path)

    @Test("feed() from a background queue parses without loss — the directDelivery dataReceived path",
          .timeLimit(.minutes(1)))
    func offMainFeedLandsInBuffer() async {
        let view = makeView()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                view.feed(byteArray: [UInt8]("MARKER-7f3a9\r\n".utf8)[...])
                continuation.resume()
            }
        }
        let text = String(data: view.getBufferAsData(), encoding: .utf8) ?? ""
        #expect(text.contains("MARKER-7f3a9"))
    }

    // MARK: - installColors invalidation pin (the deleted updateFullScreen workaround)

    /// Pins the upstream premise the migration deleted a workaround on:
    /// `applyScheme()` used to call `getTerminal().updateFullScreen()` after
    /// `installColors(_:)` to force a repaint of already-drawn cells, and the
    /// migration removed it because SwiftTerm 2.0's `installColors` runs
    /// `colorsChangedLocked()`, which itself ends in `terminal.updateFullScreen()`
    /// (Apple/AppleTerminalView.swift). Nothing else in the diff exercised that
    /// premise, so this test does: quiesce the terminal's pending-update range,
    /// call the production `installColors(_:)` — the exact call the deleted
    /// workaround followed; `applyScheme()` itself is private and only reachable
    /// through an async Combine sink — and assert the full screen is dirty again
    /// with no manual `updateFullScreen()` anywhere in the test.
    ///
    /// Discrimination: the `#require(quiesced == nil)` arm IS the
    /// no-invalidation baseline — it proves the observable reads nil right up
    /// until `installColors` runs, so if upstream stops invalidating, the final
    /// `#require` fails on a nil range rather than passing on residue from the
    /// feed. (Verified by mutation: with the `installColors` line removed, the
    /// test fails there.)
    @Test("installColors alone re-dirties the full screen — no manual updateFullScreen needed")
    func installColorsInvalidatesFullScreen() throws {
        try withView { view in
            // Real content through the production parse path, so the update
            // range we clear below was genuinely populated first.
            view.feed(byteArray: [UInt8]("some already-rendered text\r\n".utf8)[...])

            // Quiesce: consume the feed's dirty range the way a UI toolkit
            // does after drawing. Copy-out only, per the lock discipline.
            view.withTerminal { $0.clearUpdateRange() }
            let quiesced = view.withTerminal { $0.getUpdateRange() }
            try #require(
                quiesced == nil,
                "baseline broken: update range non-nil after clearUpdateRange — the final assertion could not attribute dirtiness to installColors")

            view.installColors(Self.pinPalette)

            // Read the range and the row count under one lock acquisition.
            let observed = view.withTerminal { terminal -> (startY: Int, endY: Int, rows: Int)? in
                guard let range = terminal.getUpdateRange() else { return nil }
                return (range.startY, range.endY, terminal.rows)
            }
            let range = try #require(
                observed,
                "installColors dirtied nothing: upstream no longer invalidates on palette install — applyScheme needs its explicit updateFullScreen back")
            #expect(range.startY == 0 && range.endY == range.rows,
                    "installColors dirtied rows \(range.startY)..\(range.endY) of \(range.rows) — a partial range, not the full screen updateFullScreen() sets")
        }
    }

    /// 16 entries, as `installPalette` requires — with fewer it silently does
    /// nothing and the test above would fail on a nil range for the wrong reason.
    private static let pinPalette: [SwiftTerm.Color] = {
        (0..<16).map { i in
            SwiftTerm.Color(
                red: UInt16(i) * 4369, green: UInt16(15 - i) * 4369, blue: 32768)
        }
    }()

    // MARK: - Holder teardown

    @Test("holder: set → withView sees the view; clear → withView returns nil")
    func holderTeardown() {
        withView { view in
            let holder = TerminalViewHolder()
            #expect(holder.withView { _ in true } == nil)
            holder.set(view)
            #expect(holder.withView { $0 === view } == true)
            holder.clear()
            #expect(holder.withView { _ in true } == nil)
        }
    }

    @Test("holder: concurrent withView racing clear neither crashes nor resurrects the view",
          .timeLimit(.minutes(1)))
    func holderConcurrentClearIsSafe() async {
        let view = makeView()
        let holder = TerminalViewHolder()
        holder.set(view)
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            for _ in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<2_000 {
                        holder.withView { _ in () }
                    }
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                holder.clear()
                group.leave()
            }
            group.notify(queue: .main) { continuation.resume() }
        }
        #expect(holder.withView { _ in true } == nil)
    }
}
