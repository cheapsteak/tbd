# tmux Control Mode — Phase 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the daemon the ability to open a `tmux -CC attach` control-mode connection per repo, parse the control protocol stream into typed events, and log them — all behind an opt-in feature gate, with the existing grouped-sessions path completely untouched.

**Architecture:** Six new pure/near-pure components under `Sources/TBDDaemon/Tmux/ControlMode/`: a version parser (`TmuxVersion`), an event vocabulary (`TmuxControlEvent`), an octal payload decoder (`TmuxOutputDecoder`), an incremental line parser (`TmuxControlParser`), a feature/version gate (`ControlModeGate`), and a subprocess owner (`TmuxControlConnection`) that drains tmux stdout on a dedicated `Thread` and emits events through an `AsyncStream`. A `TmuxControlSupervisor` actor wires one connection per tmux server and logs every event. The daemon calls the supervisor right after `TmuxManager.ensureServer()`, but only when `ControlModeGate.shouldEnable` returns true (env opt-in + tmux ≥ 3.2). Phase 1 renders nothing, vends no file descriptors, and sends no keystrokes — it is observation-only.

**Tech Stack:** Swift 5.x, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), `os.Logger`, Foundation `Process`/`Pipe`/`Thread`/`AsyncStream`. Build: `swift build`. Test: `swift test`. Manual end-to-end: `scripts/restart.sh` + `log stream`.

**Reference spec:** `docs/specs/2026-05-17-tmux-control-mode-design.md` (see "Components" table and "Constraints" — minimum tmux 3.2).

**Phase boundary — explicitly NOT in Phase 1:** no pipe creation, no `SCM_RIGHTS` FD vending, no SwiftTerm rendering, no keystroke/resize RPC, no scrollback/α-replay, no flow-control state machine, no crash recovery, no SQLite changes, no app-side code, no Settings UI. Those are Phases 2–7. Phase 1's only observable effect when the gate is OFF is **zero behavior change**.

---

## File Map

**Create (TBDDaemon — production):**
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxVersion.swift` — version struct, `parse(_:)`, async `detect()`
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlEvent.swift` — decoded-event enum
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxOutputDecoder.swift` — octal `\ooo` payload decoder
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift` — incremental line parser
- `Sources/TBDDaemon/Tmux/ControlMode/ControlModeGate.swift` — env + version gate
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift` — subprocess owner + reader thread
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift` — per-server connection registry + logging sink

**Create (TBDDaemon — tests):**
- `Tests/TBDDaemonTests/TmuxVersionTests.swift`
- `Tests/TBDDaemonTests/TmuxOutputDecoderTests.swift`
- `Tests/TBDDaemonTests/TmuxControlParserTests.swift`
- `Tests/TBDDaemonTests/ControlModeGateTests.swift`
- `Tests/TBDDaemonTests/TmuxControlConnectionIntegrationTests.swift`

**Modify (TBDDaemon — exactly one file, located in Task 11):**
- The daemon object that calls `TmuxManager.ensureServer()` — adds a `TmuxControlSupervisor` field, a one-time `TmuxVersion` detection, and a gated `ensureConnection` call.

SwiftPM globs `Sources/` and `Tests/` — no `Package.swift` change is needed for new files.

---

## Task 1: `TmuxVersion` — parse + detect

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/TmuxVersion.swift`
- Test: `Tests/TBDDaemonTests/TmuxVersionTests.swift`

`tmux -V` prints lines like `tmux 3.6a`, `tmux 3.2`, `tmux next-3.4`. Only `major.minor` matters for gating; any letter suffix is kept for logging but ignored in comparisons.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/TmuxVersionTests.swift`:

```swift
import Testing
@testable import TBDDaemon

@Suite("TmuxVersion")
struct TmuxVersionTests {
    @Test("parses a normal release with a letter suffix")
    func parseSuffix() {
        let v = TmuxVersion.parse("tmux 3.6a\n")
        #expect(v == TmuxVersion(major: 3, minor: 6))
        #expect(v?.suffix == "a")
    }

    @Test("parses a version with no suffix")
    func parseNoSuffix() {
        #expect(TmuxVersion.parse("tmux 3.2") == TmuxVersion(major: 3, minor: 2))
    }

    @Test("parses an older two-digit-minor version")
    func parseOld() {
        #expect(TmuxVersion.parse("tmux 2.9a") == TmuxVersion(major: 2, minor: 9))
    }

    @Test("parses a next- prerelease token")
    func parseNext() {
        #expect(TmuxVersion.parse("tmux next-3.4") == TmuxVersion(major: 3, minor: 4))
    }

    @Test("returns nil for unparseable output")
    func parseGarbage() {
        #expect(TmuxVersion.parse("not a version") == nil)
        #expect(TmuxVersion.parse("") == nil)
    }

    @Test("compares by major then minor, ignoring suffix")
    func comparison() {
        #expect(TmuxVersion(major: 3, minor: 2) >= TmuxVersion.controlModeMinimum)
        #expect(TmuxVersion(major: 3, minor: 1) < TmuxVersion.controlModeMinimum)
        #expect(TmuxVersion(major: 2, minor: 9) < TmuxVersion.controlModeMinimum)
        #expect(TmuxVersion(major: 3, minor: 6, suffix: "a") >= TmuxVersion.controlModeMinimum)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TmuxVersionTests`
Expected: compile failure — `cannot find 'TmuxVersion' in scope`.

- [ ] **Step 3: Implement `TmuxVersion`**

Create `Sources/TBDDaemon/Tmux/ControlMode/TmuxVersion.swift`:

```swift
import Foundation

/// A parsed tmux version, comparable so callers can gate features on a minimum.
///
/// Only numeric `major.minor` is significant; a trailing letter suffix
/// (`a`, `b`, …) is preserved for logging but ignored in comparisons.
struct TmuxVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let suffix: String

    init(major: Int, minor: Int, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.suffix = suffix
    }

    /// Parse the output of `tmux -V`, e.g. "tmux 3.6a\n". Returns nil when no
    /// `<int>.<int>` token is present.
    static func parse(_ output: String) -> TmuxVersion? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "-" }) {
            guard let dot = token.firstIndex(of: ".") else { continue }
            let majorPart = token[token.startIndex..<dot]
            let afterDot = token[token.index(after: dot)...]
            guard !majorPart.isEmpty, let major = Int(majorPart) else { continue }
            let minorDigits = afterDot.prefix(while: { $0.isNumber })
            guard !minorDigits.isEmpty, let minor = Int(minorDigits) else { continue }
            let suffix = String(afterDot.dropFirst(minorDigits.count))
            return TmuxVersion(major: major, minor: minor, suffix: suffix)
        }
        return nil
    }

    static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        lhs.major != rhs.major ? lhs.major < rhs.major : lhs.minor < rhs.minor
    }

    static func == (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor
    }

    var description: String { "\(major).\(minor)\(suffix)" }

    /// Minimum version for the control-mode feature set (`%pause`/`%continue`,
    /// `%extended-output`, `pause-after`, `window-size manual`). Spec constraint.
    static let controlModeMinimum = TmuxVersion(major: 3, minor: 2)
}

extension TmuxVersion {
    /// Run `tmux -V` once and parse the result. Returns nil on any failure
    /// (tmux not installed, non-zero exit, unparseable output).
    static func detect(tmuxBinary: String = "/usr/bin/env") async -> TmuxVersion? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tmuxBinary)
            process.arguments = ["tmux", "-V"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: TmuxVersion.parse(String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TmuxVersionTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxVersion.swift Tests/TBDDaemonTests/TmuxVersionTests.swift
git commit -m "feat: add tmux version parsing for control-mode gating"
```

---

## Task 2: `TmuxControlEvent` — decoded-event vocabulary

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlEvent.swift`

This is a pure data type — no logic, no tests of its own (every case is exercised by the parser tests in Tasks 4–6). Defining it first lets later tasks compile.

- [ ] **Step 1: Create the enum**

Create `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlEvent.swift`:

```swift
import Foundation

/// A single decoded tmux control-mode notification.
///
/// `tmux -CC attach` emits line-oriented notifications prefixed with `%`.
/// This enum is the parser's output vocabulary. Notifications the parser does
/// not model in detail surface as `.unhandled` rather than being dropped, so
/// logging reveals protocol surface we have not covered yet.
enum TmuxControlEvent: Equatable {
    /// `%output %<pane> <data>` — program output. `bytes` is octal-unescaped.
    case output(paneID: String, bytes: Data)

    /// `%extended-output %<pane> <age> : <data>` — output delivered while the
    /// pane was paused; `ageMillis` is the delay in milliseconds.
    case extendedOutput(paneID: String, ageMillis: Int, bytes: Data)

    /// A completed `%begin`…`%end` command-response block. `lines` are the raw
    /// response lines between the markers.
    case commandSucceeded(number: Int, lines: [String])

    /// A completed `%begin`…`%error` command-response block (command failed).
    case commandFailed(number: Int, lines: [String])

    /// `%window-add @<window>` — a window was created.
    case windowAdd(windowID: String)

    /// `%window-close @<window>` — a window was closed.
    case windowClose(windowID: String)

    /// `%layout-change @<window> <layout> <visible-layout> <flags>`.
    case layoutChange(windowID: String, layout: String)

    /// `%pause %<pane>` — tmux paused output for a pane.
    case pause(paneID: String)

    /// `%continue %<pane>` — tmux resumed output for a pane.
    case `continue`(paneID: String)

    /// `%exit [<reason>]` — the tmux server is detaching this control client.
    case exit(reason: String?)

    /// A `%`-prefixed notification recognized by name but not modeled, or not
    /// recognized at all. Carries the raw line for logging.
    case unhandled(line: String)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlEvent.swift
git commit -m "feat: add tmux control-mode event vocabulary"
```

---

## Task 3: `TmuxOutputDecoder` — octal payload decoder

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/TmuxOutputDecoder.swift`
- Test: `Tests/TBDDaemonTests/TmuxOutputDecoderTests.swift`

Per the tmux control-mode protocol, every byte in a `%output` payload that is not printable ASCII — or that is a backslash — is written as a backslash followed by exactly three octal digits (`\ooo`). All other bytes appear literally. This decoder is the inverse.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/TmuxOutputDecoderTests.swift`:

```swift
import Foundation
import Testing
@testable import TBDDaemon

@Suite("TmuxOutputDecoder")
struct TmuxOutputDecoderTests {
    @Test("passes literal printable text through unchanged")
    func literal() {
        #expect(TmuxOutputDecoder.decode("hello world") == Data("hello world".utf8))
    }

    @Test("decodes an empty payload to empty data")
    func empty() {
        #expect(TmuxOutputDecoder.decode("") == Data())
    }

    @Test("decodes an octal newline escape")
    func newline() {
        // \012 == octal 12 == decimal 10 == '\n'
        #expect(TmuxOutputDecoder.decode("a\\012b") == Data([97, 10, 98]))
    }

    @Test("decodes an escaped backslash")
    func backslash() {
        // \134 == octal 134 == decimal 92 == '\'
        #expect(TmuxOutputDecoder.decode("\\134") == Data([92]))
    }

    @Test("decodes an ESC control byte")
    func escByte() {
        // \033 == octal 33 == decimal 27 == ESC
        #expect(TmuxOutputDecoder.decode("\\033[31m") == Data([27, 91, 51, 49, 109]))
    }

    @Test("decodes multibyte UTF-8 escaped octet-by-octet")
    func utf8() {
        // 日 == UTF-8 E6 97 A5 == octal \346\227\245
        #expect(TmuxOutputDecoder.decode("\\346\\227\\245") == Data("日".utf8))
    }

    @Test("passes a malformed escape through literally")
    func malformed() {
        // backslash not followed by 3 octal digits — keep the bytes, do not drop
        #expect(TmuxOutputDecoder.decode("\\12") == Data("\\12".utf8))
        #expect(TmuxOutputDecoder.decode("\\99x") == Data("\\99x".utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TmuxOutputDecoderTests`
Expected: compile failure — `cannot find 'TmuxOutputDecoder' in scope`.

- [ ] **Step 3: Implement the decoder**

Create `Sources/TBDDaemon/Tmux/ControlMode/TmuxOutputDecoder.swift`:

```swift
import Foundation

/// Decodes the octal-escaped payload of a tmux `%output` / `%extended-output`
/// notification back into raw bytes.
enum TmuxOutputDecoder {
    /// Decode an escaped payload string into raw bytes.
    ///
    /// A backslash not followed by three octal digits is passed through
    /// literally — control-mode payloads should never contain one, but
    /// silently dropping bytes would be worse than emitting a stray backslash.
    static func decode(_ escaped: String) -> Data {
        var out = Data()
        let bytes = Array(escaped.utf8)
        let backslash = UInt8(ascii: "\\")
        var i = 0
        while i < bytes.count {
            guard bytes[i] == backslash, i + 3 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard let d0 = octalValue(bytes[i + 1]),
                  let d1 = octalValue(bytes[i + 2]),
                  let d2 = octalValue(bytes[i + 3]) else {
                out.append(bytes[i])  // not a valid escape; emit the backslash
                i += 1
                continue
            }
            out.append(UInt8((d0 * 64 + d1 * 8 + d2) & 0xFF))
            i += 4
        }
        return out
    }

    private static func octalValue(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TmuxOutputDecoderTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxOutputDecoder.swift Tests/TBDDaemonTests/TmuxOutputDecoderTests.swift
git commit -m "feat: add tmux control-mode octal output decoder"
```

---

## Task 4: `TmuxControlParser` — framing + simple notifications

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift`
- Test: `Tests/TBDDaemonTests/TmuxControlParserTests.swift`

The parser is line-buffered: feed it raw stdout bytes, it returns whatever complete events the new bytes produced, buffering a partial trailing line. This task implements line framing and the simple no-payload notifications. `%output`, `%extended-output`, and `%begin` blocks are added in Tasks 5–6 — until then they fall through to `.unhandled`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/TmuxControlParserTests.swift`:

```swift
import Foundation
import Testing
@testable import TBDDaemon

@Suite("TmuxControlParser — notifications")
struct TmuxControlParserNotificationTests {
    private func feed(_ string: String) -> [TmuxControlEvent] {
        TmuxControlParser().feed(Data(string.utf8))
    }

    @Test("parses %window-add")
    func windowAdd() {
        #expect(feed("%window-add @5\n") == [.windowAdd(windowID: "@5")])
    }

    @Test("parses %window-close")
    func windowClose() {
        #expect(feed("%window-close @7\n") == [.windowClose(windowID: "@7")])
    }

    @Test("parses %pause and %continue")
    func pauseContinue() {
        #expect(feed("%pause %3\n") == [.pause(paneID: "%3")])
        #expect(feed("%continue %3\n") == [.continue(paneID: "%3")])
    }

    @Test("parses %exit with and without a reason")
    func exit() {
        #expect(feed("%exit\n") == [.exit(reason: nil)])
        #expect(feed("%exit server exited\n") == [.exit(reason: "server exited")])
    }

    @Test("parses %layout-change keeping the layout string")
    func layoutChange() {
        let events = feed("%layout-change @1 bf2c,80x24,0,0 bf2c,80x24,0,0 1\n")
        #expect(events == [.layoutChange(windowID: "@1", layout: "bf2c,80x24,0,0")])
    }

    @Test("surfaces an unrecognized notification as .unhandled")
    func unknown() {
        #expect(feed("%sessions-changed\n") == [.unhandled(line: "%sessions-changed")])
    }

    @Test("buffers a partial line until its newline arrives")
    func partialLine() {
        let parser = TmuxControlParser()
        #expect(parser.feed(Data("%pause ".utf8)).isEmpty)
        #expect(parser.feed(Data("%3\n".utf8)) == [.pause(paneID: "%3")])
    }

    @Test("parses two notifications delivered in one chunk")
    func twoInOneChunk() {
        #expect(feed("%window-add @1\n%window-close @1\n") ==
                [.windowAdd(windowID: "@1"), .windowClose(windowID: "@1")])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TmuxControlParserNotificationTests`
Expected: compile failure — `cannot find 'TmuxControlParser' in scope`.

- [ ] **Step 3: Implement the parser (framing + simple notifications)**

Create `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift`:

```swift
import Foundation

/// Incremental, line-oriented parser for the tmux control-mode protocol.
///
/// Feed raw bytes from a `tmux -CC attach` stdout stream via `feed(_:)`; it
/// returns the complete events those bytes produced. A partial trailing line
/// is buffered until its terminating newline arrives.
///
/// Not thread-safe: `feed(_:)` must be called from a single thread (the
/// connection's dedicated reader thread).
final class TmuxControlParser {
    private var lineBuffer = Data()

    /// When inside a `%begin`…`%end`/`%error` block, the in-progress block.
    private var openBlock: (number: Int, lines: [String])?

    /// Feed raw stdout bytes; returns events completed by this chunk.
    func feed(_ data: Data) -> [TmuxControlEvent] {
        lineBuffer.append(data)
        var events: [TmuxControlEvent] = []
        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            var slice = Data(lineBuffer[lineBuffer.startIndex..<newlineIndex])
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            if let event = parseLine(String(decoding: slice, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    private func parseLine(_ line: String) -> TmuxControlEvent? {
        // Inside a command block, every line is response text until %end/%error.
        if openBlock != nil {
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                return closeBlock(line)
            }
            openBlock?.lines.append(line)
            return nil
        }

        guard line.hasPrefix("%") else {
            return line.isEmpty ? nil : .unhandled(line: line)
        }

        let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch fields[0] {
        case "%output":
            return .unhandled(line: line)            // implemented in Task 5
        case "%extended-output":
            return .unhandled(line: line)            // implemented in Task 5
        case "%begin":
            return .unhandled(line: line)            // implemented in Task 6
        case "%window-add":
            return fields.count >= 2 ? .windowAdd(windowID: fields[1]) : .unhandled(line: line)
        case "%window-close", "%unlinked-window-close":
            return fields.count >= 2 ? .windowClose(windowID: fields[1]) : .unhandled(line: line)
        case "%layout-change":
            return fields.count >= 3
                ? .layoutChange(windowID: fields[1], layout: fields[2])
                : .unhandled(line: line)
        case "%pause":
            return fields.count >= 2 ? .pause(paneID: fields[1]) : .unhandled(line: line)
        case "%continue":
            return fields.count >= 2 ? .continue(paneID: fields[1]) : .unhandled(line: line)
        case "%exit":
            let reason = fields.count >= 2 ? fields[1...].joined(separator: " ") : nil
            return .exit(reason: reason)
        default:
            return .unhandled(line: line)
        }
    }

    private func closeBlock(_ line: String) -> TmuxControlEvent {
        let block = openBlock!
        openBlock = nil
        return line.hasPrefix("%end ")
            ? .commandSucceeded(number: block.number, lines: block.lines)
            : .commandFailed(number: block.number, lines: block.lines)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TmuxControlParserNotificationTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift Tests/TBDDaemonTests/TmuxControlParserTests.swift
git commit -m "feat: add tmux control-mode line parser with notification framing"
```

---

## Task 5: `TmuxControlParser` — `%output` and `%extended-output`

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift`
- Modify: `Tests/TBDDaemonTests/TmuxControlParserTests.swift`

`%output %<pane> <data>` carries octal-escaped data that may contain literal spaces — so the payload is everything after the **second** space, not a space-split field. `%extended-output %<pane> <age> : <data>` puts the data after the first ` : ` delimiter.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TBDDaemonTests/TmuxControlParserTests.swift`:

```swift
@Suite("TmuxControlParser — output")
struct TmuxControlParserOutputTests {
    private func feed(_ string: String) -> [TmuxControlEvent] {
        TmuxControlParser().feed(Data(string.utf8))
    }

    @Test("parses %output with literal text")
    func plainOutput() {
        #expect(feed("%output %3 hello\n") == [.output(paneID: "%3", bytes: Data("hello".utf8))])
    }

    @Test("parses %output with an octal escape")
    func escapedOutput() {
        #expect(feed("%output %3 a\\012b\n") == [.output(paneID: "%3", bytes: Data([97, 10, 98]))])
    }

    @Test("parses %output whose payload contains literal spaces")
    func spacedOutput() {
        #expect(feed("%output %3 a b c\n") == [.output(paneID: "%3", bytes: Data("a b c".utf8))])
    }

    @Test("parses %output with an empty payload")
    func emptyOutput() {
        #expect(feed("%output %3 \n") == [.output(paneID: "%3", bytes: Data())])
    }

    @Test("parses %extended-output with age and payload")
    func extendedOutput() {
        let events = feed("%extended-output %3 150 : hello\n")
        #expect(events == [.extendedOutput(paneID: "%3", ageMillis: 150, bytes: Data("hello".utf8))])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TmuxControlParserOutputTests`
Expected: FAIL — events come back as `.unhandled` instead of `.output`/`.extendedOutput`.

- [ ] **Step 3: Implement the output cases**

In `TmuxControlParser.swift`, replace the two placeholder cases in the `switch`:

```swift
        case "%output":
            return .unhandled(line: line)            // implemented in Task 5
        case "%extended-output":
            return .unhandled(line: line)            // implemented in Task 5
```

with:

```swift
        case "%output":
            return parseOutput(fields: fields, line: line)
        case "%extended-output":
            return parseExtendedOutput(fields: fields, line: line)
```

Then add these methods to the class (e.g. just below `parseLine`):

```swift
    private func parseOutput(fields: [String], line: String) -> TmuxControlEvent {
        guard fields.count >= 2 else { return .unhandled(line: line) }
        let payload = payloadAfterSpaces(2, in: line)
        return .output(paneID: fields[1], bytes: TmuxOutputDecoder.decode(payload))
    }

    private func parseExtendedOutput(fields: [String], line: String) -> TmuxControlEvent {
        guard fields.count >= 4, let age = Int(fields[2]),
              let colon = line.range(of: " : ") else { return .unhandled(line: line) }
        let payload = String(line[colon.upperBound...])
        return .extendedOutput(paneID: fields[1], ageMillis: age,
                               bytes: TmuxOutputDecoder.decode(payload))
    }

    /// Returns the remainder of `line` after the first `count` space-separated
    /// tokens (and the space following the last of them). Used for `%output`,
    /// whose payload may contain literal spaces and must not be field-split.
    private func payloadAfterSpaces(_ count: Int, in line: String) -> String {
        var seen = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == " " {
                seen += 1
                if seen == count { return String(line[line.index(after: idx)...]) }
            }
            idx = line.index(after: idx)
        }
        return ""
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TmuxControlParser"`
Expected: PASS — both the notification suite (8) and the output suite (5).

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift Tests/TBDDaemonTests/TmuxControlParserTests.swift
git commit -m "feat: parse tmux %output and %extended-output notifications"
```

---

## Task 6: `TmuxControlParser` — `%begin`/`%end`/`%error` blocks

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift`
- Modify: `Tests/TBDDaemonTests/TmuxControlParserTests.swift`

A command sent to the control client produces a `%begin <ts> <number> <flags>` line, then zero or more raw response lines, then `%end <ts> <number> <flags>` (success) or `%error <ts> <number> <flags>` (failure). `closeBlock` already exists from Task 4; this task only needs `%begin` to open a block. (Assumption, verified in Task 10's integration test: tmux does not interleave async `%output` lines inside a `%begin`…`%end` block.)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TBDDaemonTests/TmuxControlParserTests.swift`:

```swift
@Suite("TmuxControlParser — command blocks")
struct TmuxControlParserBlockTests {
    private func feed(_ string: String) -> [TmuxControlEvent] {
        TmuxControlParser().feed(Data(string.utf8))
    }

    @Test("collects a successful command block's lines")
    func successBlock() {
        let events = feed("%begin 123 7 0\nline one\nline two\n%end 123 7 0\n")
        #expect(events == [.commandSucceeded(number: 7, lines: ["line one", "line two"])])
    }

    @Test("reports a failed command block")
    func errorBlock() {
        let events = feed("%begin 1 2 0\nbad command\n%error 1 2 0\n")
        #expect(events == [.commandFailed(number: 2, lines: ["bad command"])])
    }

    @Test("handles an empty command block")
    func emptyBlock() {
        #expect(feed("%begin 1 3 0\n%end 1 3 0\n") == [.commandSucceeded(number: 3, lines: [])])
    }

    @Test("emits a notification that follows a block")
    func blockThenNotification() {
        let events = feed("%begin 1 4 0\nx\n%end 1 4 0\n%window-add @9\n")
        #expect(events == [.commandSucceeded(number: 4, lines: ["x"]),
                           .windowAdd(windowID: "@9")])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TmuxControlParserBlockTests`
Expected: FAIL — `%begin` returns `.unhandled` and its body lines leak out as `.unhandled` events.

- [ ] **Step 3: Implement `%begin` block opening**

In `TmuxControlParser.swift`, replace the placeholder case:

```swift
        case "%begin":
            return .unhandled(line: line)            // implemented in Task 6
```

with:

```swift
        case "%begin":
            openBlock = (number: fields.count >= 3 ? (Int(fields[2]) ?? -1) : -1, lines: [])
            return nil
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TmuxControlParser"`
Expected: PASS — all three suites (notifications 8, output 5, blocks 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlParser.swift Tests/TBDDaemonTests/TmuxControlParserTests.swift
git commit -m "feat: parse tmux %begin/%end/%error command blocks"
```

---

## Task 7: `ControlModeGate` — env + version gate

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/ControlModeGate.swift`
- Test: `Tests/TBDDaemonTests/ControlModeGateTests.swift`

Phase 1 keeps control mode entirely opt-in: it runs only when `TBD_TMUX_CONTROL_MODE` is truthy **and** tmux is ≥ 3.2. Otherwise the daemon's grouped-sessions path is unaffected.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/ControlModeGateTests.swift`:

```swift
import Testing
@testable import TBDDaemon

@Suite("ControlModeGate")
struct ControlModeGateTests {
    @Test("optedIn recognizes truthy values")
    func optedInTruthy() {
        #expect(ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "1"]))
        #expect(ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "true"]))
        #expect(ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "YES"]))
    }

    @Test("optedIn rejects falsy or absent values")
    func optedInFalsy() {
        #expect(!ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "0"]))
        #expect(!ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": ""]))
        #expect(!ControlModeGate.optedIn(environment: [:]))
    }

    @Test("shouldEnable requires opt-in AND a sufficient tmux version")
    func shouldEnable() {
        let on = ["TBD_TMUX_CONTROL_MODE": "1"]
        #expect(ControlModeGate.shouldEnable(environment: on,
                                             tmuxVersion: TmuxVersion(major: 3, minor: 2)))
        #expect(ControlModeGate.shouldEnable(environment: on,
                                             tmuxVersion: TmuxVersion(major: 3, minor: 6)))
        #expect(!ControlModeGate.shouldEnable(environment: on,
                                              tmuxVersion: TmuxVersion(major: 3, minor: 1)))
        #expect(!ControlModeGate.shouldEnable(environment: on, tmuxVersion: nil))
        #expect(!ControlModeGate.shouldEnable(environment: [:],
                                              tmuxVersion: TmuxVersion(major: 3, minor: 6)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ControlModeGateTests`
Expected: compile failure — `cannot find 'ControlModeGate' in scope`.

- [ ] **Step 3: Implement the gate**

Create `Sources/TBDDaemon/Tmux/ControlMode/ControlModeGate.swift`:

```swift
import Foundation

/// Decides whether the tmux control-mode path is active.
///
/// Phase 1 keeps control mode opt-in: it runs only when the
/// `TBD_TMUX_CONTROL_MODE` environment variable is truthy AND the local tmux
/// supports the control-mode feature set. Otherwise the daemon's existing
/// grouped-sessions path is unaffected.
enum ControlModeGate {
    static let environmentKey = "TBD_TMUX_CONTROL_MODE"

    /// Whether the env var opts in. Accepts `1`, `true`, `yes` (case-insensitive).
    static func optedIn(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[environmentKey]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// Final decision: opted in AND tmux ≥ the control-mode minimum.
    /// `tmuxVersion` is nil when version detection failed.
    static func shouldEnable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tmuxVersion: TmuxVersion?
    ) -> Bool {
        guard optedIn(environment: environment), let version = tmuxVersion else { return false }
        return version >= TmuxVersion.controlModeMinimum
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ControlModeGateTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/ControlModeGate.swift Tests/TBDDaemonTests/ControlModeGateTests.swift
git commit -m "feat: add tmux control-mode feature gate"
```

---

## Task 8: `TmuxControlConnection` — subprocess owner

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift`

Owns one `tmux -CC attach` subprocess. Its stdout is drained on a dedicated `Thread` (not a Swift actor task) so a `%output` burst cannot starve the cooperative thread pool — this was a v1 control-mode blocker (spec, "What v1 blockers this resolves"). Events flow through an `AsyncStream`. No unit test here — exercised end-to-end by the integration test in Task 10. Verify only that it builds.

- [ ] **Step 1: Create the connection**

Create `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift`:

```swift
import Foundation
import os

/// Owns a single `tmux -CC attach` control-mode connection to one tmux server.
///
/// stdout is drained on a dedicated `Thread` so a burst of `%output` cannot
/// starve the cooperative thread pool. Decoded events are delivered through
/// `events`, an `AsyncStream` the caller iterates. `start()` then `stop()` is
/// the expected lifecycle; both are safe to call once.
final class TmuxControlConnection {
    let serverName: String
    private let tmuxBinary: String
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    private let process = Process()
    private let parser = TmuxControlParser()
    private let stdinLock = NSLock()
    private var stdinHandle: FileHandle?

    /// Stream of decoded protocol events. Finishes when the connection stops
    /// or the tmux process exits.
    let events: AsyncStream<TmuxControlEvent>
    private let eventContinuation: AsyncStream<TmuxControlEvent>.Continuation

    init(serverName: String, tmuxBinary: String = "/usr/bin/env") {
        self.serverName = serverName
        self.tmuxBinary = tmuxBinary
        var continuation: AsyncStream<TmuxControlEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// Spawn `tmux -CC attach` and begin draining its output. Throws if the
    /// process fails to launch.
    func start() throws {
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        process.arguments = ["tmux", "-L", serverName, "-CC", "attach", "-t", "main"]
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = FileHandle.nullDevice
        stdinHandle = stdinPipe.fileHandleForWriting

        let server = serverName
        process.terminationHandler = { [weak self] proc in
            self?.logger.info(
                "tmux -CC connection for \(server, privacy: .public) exited, status \(proc.terminationStatus)")
            self?.eventContinuation.finish()
        }

        try process.run()
        logger.info("started tmux -CC connection for server \(server, privacy: .public)")

        let readHandle = stdoutPipe.fileHandleForReading
        let thread = Thread { [weak self] in self?.readLoop(readHandle) }
        thread.name = "tmux-control-\(serverName)"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Stop the connection: close stdin, terminate tmux, finish the stream.
    func stop() {
        stdinLock.lock()
        try? stdinHandle?.close()
        stdinHandle = nil
        stdinLock.unlock()
        if process.isRunning { process.terminate() }
        eventContinuation.finish()
    }

    /// Write a raw tmux command line to the control client's stdin.
    /// Phase 1 has no production callers; exercising the path here keeps later
    /// phases (resize, send-keys) on a working writer.
    func sendCommand(_ command: String) {
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard let handle = stdinHandle else { return }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func readLoop(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            for event in parser.feed(chunk) {
                eventContinuation.yield(event)
            }
        }
        eventContinuation.finish()
    }
}
```

> **Implementer note:** the executable defaults to `/usr/bin/env` with `tmux` as the first argument, which resolves `tmux` on `PATH`. If `TmuxManager.runTmux` (`Sources/TBDDaemon/Tmux/TmuxManager.swift:387`) resolves the tmux binary differently (e.g. an absolute path), match that here for consistency by passing the same value to `tmuxBinary`.

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift
git commit -m "feat: add tmux -CC control connection with threaded reader"
```

---

## Task 9: `TmuxControlSupervisor` — per-server registry + logging sink

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift`

Tracks at most one connection per tmux server and drains its events into the log. Phase 1's control-mode path is observation-only — the supervisor exists to prove the connection + parser stack end-to-end inside the live daemon. No unit test (exercised by Task 10); verify it builds.

- [ ] **Step 1: Create the supervisor**

Create `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift`:

```swift
import Foundation
import os

/// Tracks at most one `TmuxControlConnection` per tmux server and drains its
/// events into the log. Phase 1's control-mode path is observation-only:
/// nothing is rendered and no FDs are vended.
actor TmuxControlSupervisor {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private var connections: [String: TmuxControlConnection] = [:]

    /// Idempotently ensure a control connection exists for `serverName`.
    /// A no-op if one is already running.
    func ensureConnection(serverName: String) {
        guard connections[serverName] == nil else { return }
        let connection = TmuxControlConnection(serverName: serverName)
        do {
            try connection.start()
        } catch {
            logger.error("failed to start tmux -CC connection for \(serverName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        connections[serverName] = connection
        Task { [weak self] in
            await self?.drain(serverName: serverName, connection: connection)
        }
    }

    /// Stop every connection. Call on daemon shutdown.
    func stopAll() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
    }

    private func drain(serverName: String, connection: TmuxControlConnection) async {
        for await event in connection.events {
            log(event, serverName: serverName)
        }
        connections[serverName] = nil
        logger.info("tmux -CC event stream ended for \(serverName, privacy: .public)")
    }

    private func log(_ event: TmuxControlEvent, serverName: String) {
        let tag = "[\(serverName)]"
        switch event {
        case .output(let pane, let bytes):
            logger.debug("\(tag, privacy: .public) %output \(pane, privacy: .public) \(bytes.count) bytes")
        case .extendedOutput(let pane, let age, let bytes):
            logger.debug("\(tag, privacy: .public) %extended-output \(pane, privacy: .public) age=\(age)ms \(bytes.count) bytes")
        case .commandSucceeded(let number, let lines):
            logger.debug("\(tag, privacy: .public) %end #\(number) \(lines.count) lines")
        case .commandFailed(let number, let lines):
            logger.error("\(tag, privacy: .public) %error #\(number) \(lines.count) lines")
        case .windowAdd(let window):
            logger.info("\(tag, privacy: .public) %window-add \(window, privacy: .public)")
        case .windowClose(let window):
            logger.info("\(tag, privacy: .public) %window-close \(window, privacy: .public)")
        case .layoutChange(let window, _):
            logger.info("\(tag, privacy: .public) %layout-change \(window, privacy: .public)")
        case .pause(let pane):
            logger.info("\(tag, privacy: .public) %pause \(pane, privacy: .public)")
        case .continue(let pane):
            logger.info("\(tag, privacy: .public) %continue \(pane, privacy: .public)")
        case .exit(let reason):
            logger.info("\(tag, privacy: .public) %exit \(reason ?? "", privacy: .public)")
        case .unhandled(let line):
            logger.debug("\(tag, privacy: .public) unhandled: \(line, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift
git commit -m "feat: add tmux control-mode supervisor with logging sink"
```

---

## Task 10: End-to-end integration test against a live tmux server

**Files:**
- Create: `Tests/TBDDaemonTests/TmuxControlConnectionIntegrationTests.swift`

Spawns a real tmux server on a unique `-L` socket name, opens a `TmuxControlConnection`, drives the server, and asserts that real `%window-add` and `%output` events arrive. Skips gracefully if tmux is missing or older than 3.2. The unique `-L` name keeps this off the live `tbd-*` servers; no TBD paths or DB are touched (CLAUDE.md: "Tests must not touch ~/tbd").

- [ ] **Step 1: Write the integration test**

Create `Tests/TBDDaemonTests/TmuxControlConnectionIntegrationTests.swift`:

```swift
import Foundation
import Testing
@testable import TBDDaemon

@Suite("TmuxControlConnection integration")
struct TmuxControlConnectionIntegrationTests {

    /// Run a one-shot tmux command synchronously; returns true on exit code 0.
    @discardableResult
    private func tmux(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @Test("observes window and output events from a live tmux server")
    func observesLiveEvents() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-test-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let connection = TmuxControlConnection(serverName: server)
        try connection.start()
        defer { connection.stop() }

        let collected = EventBox()
        let collector = Task {
            for await event in connection.events { await collected.append(event) }
        }

        // Let the control client attach, then drive observable events.
        try await Task.sleep(for: .milliseconds(400))
        tmux(["-L", server, "new-window"])
        tmux(["-L", server, "send-keys", "echo tbd-marker", "Enter"])
        try await Task.sleep(for: .milliseconds(800))

        connection.stop()
        collector.cancel()

        let events = await collected.events
        #expect(events.contains { if case .windowAdd = $0 { return true } else { return false } },
                "expected a %window-add event")
        #expect(events.contains { if case .output = $0 { return true } else { return false } },
                "expected at least one %output event")
    }
}

/// Minimal actor inbox so the collector task and the test can share events
/// without a data race.
private actor EventBox {
    private(set) var events: [TmuxControlEvent] = []
    func append(_ event: TmuxControlEvent) { events.append(event) }
}
```

- [ ] **Step 2: Run the integration test**

Run: `swift test --filter TmuxControlConnectionIntegrationTests`
Expected: PASS (1 test) on any machine with tmux ≥ 3.2; a silent early-return pass if tmux is absent.

If it fails: stream the raw protocol to see actual wire formats —
`tmux -L diag new-session -d -s main && tmux -L diag -CC attach -t main` in one terminal, drive it from another, then `tmux -L diag kill-server`. Compare observed lines against the formats parsed in Tasks 4–6 and adjust the parser if tmux 3.6a differs from the documented protocol.

- [ ] **Step 3: Commit**

```bash
git add Tests/TBDDaemonTests/TmuxControlConnectionIntegrationTests.swift
git commit -m "test: add live tmux control-mode connection integration test"
```

---

## Task 11: Wire the supervisor into daemon startup

**Files:**
- Modify: the daemon object that owns `TmuxManager` and calls `ensureServer()` (located in Step 1)

This is the only task that touches existing code. It adds a `TmuxControlSupervisor`, detects the tmux version once at startup, and — only when `ControlModeGate.shouldEnable` is true — opens a control connection after each `ensureServer()`. When the gate is off (the default), this adds nothing to the daemon's behavior.

- [ ] **Step 1: Locate the `ensureServer()` call site**

Run: `grep -rn "ensureServer" Sources/TBDDaemon --include=*.swift`

Identify the file and type that calls `TmuxManager.ensureServer()`. That type is the daemon-side object that should own the supervisor. Note its path and the surrounding context (is it an `actor`, a `class`? where is its initializer? where does `ensureServer()` get called from — an RPC handler, a startup routine?).

- [ ] **Step 2: Add the supervisor field and version cache**

In that type, add two stored properties:

```swift
    private let controlModeSupervisor = TmuxControlSupervisor()
    private var detectedTmuxVersion: TmuxVersion?
```

If the type runs a startup routine, detect the version once there:

```swift
        detectedTmuxVersion = await TmuxVersion.detect()
```

If there is no obvious one-time startup hook, detect lazily on first use instead — add a helper on the same type:

```swift
    private func tmuxVersion() async -> TmuxVersion? {
        if let version = detectedTmuxVersion { return version }
        let version = await TmuxVersion.detect()
        detectedTmuxVersion = version
        return version
    }
```

- [ ] **Step 3: Open a control connection after `ensureServer()`**

Immediately after the existing `ensureServer()` call succeeds, add:

```swift
        let serverName = TmuxManager.serverName(forRepoPath: repoPath)
        if ControlModeGate.shouldEnable(tmuxVersion: await tmuxVersion()) {
            await controlModeSupervisor.ensureConnection(serverName: serverName)
        }
```

Use whatever local already identifies the repo path / server name at that call site — `TmuxManager.serverName(forRepoPath:)` (`TmuxManager.swift:38`) is the canonical derivation, and `ensureConnection` is idempotent so calling it on every `ensureServer()` is safe. If the call site is not `async`, hop into a `Task { ... }` around this block.

- [ ] **Step 4: Stop connections on daemon shutdown (if a shutdown hook exists)**

If the type has a shutdown/teardown method, add `await controlModeSupervisor.stopAll()` to it. If there is no shutdown hook, skip this step — connections are terminated by process exit anyway.

- [ ] **Step 5: Build and run the full test suite**

Run: `swift build && swift test`
Expected: builds clean; all tests pass (existing suite + the five new files).

- [ ] **Step 6: Lint**

Run: `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
Expected: 0 violations. (The new files use `os.Logger`, never `print()`.)

- [ ] **Step 7: Manual end-to-end verification**

```bash
sudo log config --subsystem com.tbd.daemon --mode "level:debug,persist:debug"   # once per machine
scripts/restart.sh
```

Confirm exactly one `TBDDaemon` + one `TBDApp` from this worktree:
`ps aux | grep -E "\.build/debug/TBD" | grep -v grep`

Then, with the gate **off** (default), open a worktree and confirm normal terminal behavior is unchanged.

Then restart with the gate **on** and watch the log:
```bash
TBD_TMUX_CONTROL_MODE=1 scripts/restart.sh
log stream --level debug --predicate 'subsystem == "com.tbd.daemon" AND category == "tmuxControlMode"'
```
Open a worktree — you should see `started tmux -CC connection…`, then `%window-add`, `%output`, and `%end` lines. The terminal still renders through the unchanged grouped-sessions path; control mode is observing in parallel.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: open a tmux control-mode connection per repo behind a gate"
```

---

## Self-Review

**Spec coverage (against `docs/specs/2026-05-17-tmux-control-mode-design.md`):**
- "Protocol parser … Frames `%output`, `%extended-output`, `%begin/%end`, `%window-add`, `%window-close`, `%layout-change`, `%pause`, `%continue`, `%exit`. Real `Thread`, not actor. Handles octal-escape decoding" → Tasks 2–6 (events + parser + decoder), Task 8 (dedicated `Thread` reader). ✅
- "Minimum tmux version: 3.2 … Daemon startup checks the version; if below 3.2, fall back to grouped-sessions" → Tasks 1 + 7 (`TmuxVersion.detect` + `ControlModeGate`), Task 11 (startup check, gate-off = no change). ✅
- Owns "the single `tmux -CC attach` connection per repo" → Tasks 8–9, 11 (one connection per server name, supervisor is per-server). ✅
- Out-of-scope items (FD vending, rendering, flow control, crash recovery, input, SQLite) → correctly absent; deferred to Phases 2–7 per the phase boundary note. ✅

**Placeholder scan:** the `.unhandled` returns in Task 4's `%output`/`%extended-output`/`%begin` cases are intentional incremental TDD stubs, replaced with real implementations in Tasks 5–6 (each with a failing test first). No "TODO"/"fill in later" remain.

**Type consistency:** `TmuxControlEvent` case names and associated-value labels (`paneID`, `windowID`, `bytes`, `ageMillis`, `number`, `lines`, `layout`, `reason`, `line`) are identical across the enum definition (Task 2), every parser test (Tasks 4–6), and the supervisor's `log` switch (Task 9). `TmuxVersion.controlModeMinimum`, `ControlModeGate.shouldEnable`, `TmuxControlConnection.events`, and `TmuxControlSupervisor.ensureConnection` are referenced with consistent signatures throughout.

**Known assumption flagged for Task 10 to verify against tmux 3.6a:** tmux does not interleave async `%output` lines inside a `%begin`…`%end` block (the parser treats every in-block line as response text). If the integration test shows otherwise, the parser needs a guard in `parseLine`'s in-block branch.
