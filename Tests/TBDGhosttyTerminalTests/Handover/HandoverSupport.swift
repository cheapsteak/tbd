// The two engines as the handover suites drive them. The SwiftTerm side follows the libghostty
// proof of concept's `STerm` (spikes/libghostty-vt/check/Sources/vtcheck/STerm.swift on branch
// spike/libghostty-vt-poc), which drives SwiftTerm the way the daemon's emulator does.
import Foundation
import SwiftTerm
import TBDGhosttyTerminal
import TBDTerminalSerialization

/// The scrollback both stores keep and both handovers carry: `HolderReader.scrollbackLines` and
/// `HolderHandback.handbackScrollbackLines`.
let handoverScrollback = 5_000

/// Catches what a SwiftTerm emulator sends back, so a DECRQM answer can be read inside the feed
/// that asked for it.
final class HandoverReplyCollector: TerminalDelegate, ModeReplyReader {
    var bytes: [UInt8] = []
    weak var terminal: SwiftTerm.Terminal?

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }

    /// `CSI ? Pd ; Ps $ y`: 1 set, 2 reset, 0 or nil unknown. The caller holds `terminalLock`.
    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        guard let terminal else { return nil }
        let saved = bytes
        defer { bytes = saved }
        bytes.removeAll()
        let prefix = decPrivate ? "?" : ""
        terminal.feed(text: "\u{1b}[\(prefix)\(mode)$p")
        let reply = String(bytes: bytes, encoding: .utf8) ?? ""
        guard let head = reply.range(of: "\u{1b}[\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y") else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}

/// A SwiftTerm emulator with every feed and every read inside `terminalLock`, as the daemon's.
final class HandoverSwiftTerm {
    let collector = HandoverReplyCollector()
    let terminal: SwiftTerm.Terminal

    init(cols: Int, rows: Int, scrollback: Int = handoverScrollback) {
        terminal = SwiftTerm.Terminal(
            delegate: collector, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        collector.terminal = terminal
    }

    func feed(_ bytes: [UInt8]) {
        terminal.terminalLock.withLock { terminal.feed(buffer: bytes[...]) }
    }

    func locked<T>(_ body: (SwiftTerm.Terminal) -> T) -> T {
        terminal.terminalLock.withLock { body(terminal) }
    }

    /// TBD's handover writer, called the way the daemon calls it before an attach.
    func writerBytes(maxScrollbackLines: Int = handoverScrollback) -> [UInt8] {
        locked { terminal in
            [UInt8](TerminalSnapshotWriter.snapshot(
                of: terminal, reply: collector, maxScrollbackLines: maxScrollbackLines))
        }
    }

    /// A DEC private or ANSI mode, read with DECRQM. nil when the emulator gives no answer.
    func mode(_ mode: Int, decPrivate: Bool = true) -> Bool? {
        locked { _ in
            switch collector.requestMode(mode, decPrivate: decPrivate) {
            case 1: return true
            case 2: return false
            default: return nil
            }
        }
    }
}

extension HandoverState {
    /// A SwiftTerm emulator that has read this state's bytes.
    func swiftTerm() -> HandoverSwiftTerm {
        let terminal = HandoverSwiftTerm(cols: cols, rows: rows)
        terminal.feed(bytes)
        return terminal
    }

    /// A libghostty terminal that has read this state's bytes.
    func ghostty() throws -> GhosttyTerminal {
        let terminal = try GhosttyTerminal(
            cols: cols, rows: rows, scrollbackLines: handoverScrollback, callbacks: GhosttyTerminalCallbacks())
        terminal.feed(bytes[...])
        return terminal
    }
}

/// The first line two line lists disagree on, for a failure message.
func handoverFirstDifference(_ expected: [String], _ actual: [String]) -> String {
    for index in 0..<max(expected.count, actual.count) {
        let left = index < expected.count ? expected[index] : "<none>"
        let right = index < actual.count ? actual[index] : "<none>"
        if left != right {
            return "line \(index) of \(expected.count) vs \(actual.count): \(left.debugDescription) vs \(right.debugDescription)"
        }
    }
    return "no line differs"
}
