// ghosttyview --script: drives the real view methods with synthetic NSEvents, one command a line.
//
//   wait S | waittext TEXT [S] | log TEXT | quit
//   type TEXT | key SPEC [SPEC...] | raw TEXT | paste TEXT
//   mouse down|up|drag|move COL ROW [left|right|middle] [shift,opt,ctrl,cmd]
//   wheel ROWS COL ROW | focus in|out
//   marked TEXT | unmark | commit TEXT
//   shot NAME | text NAME | copy | stats-reset | frames LABEL | resize COLS ROWS | resizeloop N MS
//
// TEXT takes \n \r \t \e \\ \xNN. SPEC is like ctrl+c, opt+b, shift+return, up, f5.
import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class Harness {
    private let app: AppController
    private var pane: Pane { app.panes[0] }
    private var window: NSWindow { app.window }
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("ghosttyview.harness.\(getpid())"))

    init(app: AppController) {
        self.app = app
        // Never the user's real clipboard.
        for pane in app.panes {
            pane.mouse.pasteboard = pasteboard
            pane.mouse.confirmUnsafePaste = { text, _, completion in
                log("unsafe paste prompt for \(text.debugDescription): accepted")
                completion(true)
            }
            pane.mouse.openURL = { action in log("open url \(action)") }
        }
    }

    func run(path: String) async {
        guard let script = try? String(contentsOfFile: path, encoding: .utf8) else {
            log("cannot read script \(path)")
            app.finish(2)
            return
        }
        for raw in script.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let rest = parts.count > 1 ? parts[1] : ""
            await execute(parts[0], rest)
        }
        app.finish(0)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private func execute(_ command: String, _ rest: String) async {
        switch command {
        case "wait": await sleep(Double(rest) ?? 0)
        case "log": print("LOG \(rest)")
        case "quit": app.finish(0)
        case "type":
            for character in unescape(rest) {
                sendKey(character: character)
                await sleep(0.01)
            }
        case "key":
            for spec in rest.split(separator: " ") {
                sendKey(spec: String(spec))
                await sleep(0.03)
            }
        case "raw": try? pane.pty?.write(Data(unescape(rest).utf8))
        case "paste":
            pasteboard.clearContents()
            pasteboard.setString(unescape(rest), forType: .string)
            print("PASTE \(pane.mouse.pasteFromPasteboard(in: pane.view))")
        case "mouse": mouse(rest)
        case "wheel": wheel(rest)
        case "focus": pane.view.setFocused(rest == "in")
        case "marked":
            pane.view.setMarkedText(unescape(rest), selectedRange: NSRange(location: 0, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
        case "unmark": pane.view.unmarkText()
        case "commit":
            pane.view.insertText(unescape(rest), replacementRange: NSRange(location: NSNotFound, length: 0))
        case "shot": app.writeShot(to: outPath(rest))
        case "text":
            let text = (try? pane.session.formatted()) ?? "<formatter failed>"
            try? text.write(toFile: outPath(rest), atomically: true, encoding: .utf8)
        case "copy":
            let ok = pane.mouse.copySelection(in: pane.view)
            print("COPIED ok=\(ok) \(String(describing: pasteboard.string(forType: .string)).debugDescription)")
        case "stats-reset": Stats.shared.reset()
        case "frames": print("FRAMES \(rest) presented=\(pane.view.framesRendered)")
        case "waittext": await waitText(rest)
        case "resize":
            let numbers = rest.split(separator: " ").compactMap { Int($0) }
            resize(cols: numbers[0], rows: numbers[1])
        case "resizeloop":
            let numbers = rest.split(separator: " ").compactMap { Int($0) }
            for step in 0..<numbers[0] {
                resize(cols: 60 + (step * 7) % 70, rows: 16 + (step * 3) % 24)
                await sleep(Double(numbers[1]) / 1000)
            }
        default: log("unknown command \(command)")
        }
    }

    private func outPath(_ name: String) -> String { app.args.outDir + "/" + name }

    private func resize(cols: Int, rows: Int) {
        let metrics = app.context.metrics, scale = window.backingScaleFactor
        window.setContentSize(NSSize(width: CGFloat(cols * metrics.width) / scale,
                                     height: CGFloat(rows * metrics.height) / scale))
    }

    private func waitText(_ rest: String) async {
        // waittext some words [seconds]: a trailing number is the timeout.
        var words = rest.split(separator: " ").map(String.init)
        var seconds = 20.0
        if let last = words.last, let value = Double(last), words.count > 1 { seconds = value; words.removeLast() }
        let needle = unescape(words.joined(separator: " "))
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? pane.session.formatted(), text.contains(needle) {
                print("WAITTEXT found \(needle.debugDescription)")
                return
            }
            await sleep(0.1)
        }
        print("WAITTEXT TIMED OUT \(needle.debugDescription)")
    }

    private func unescape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\\", let next = scalars.popFirst() else {
                out.append(scalar)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "e": out.append("\u{1b}")
            case "x":
                let hex = String(String.UnicodeScalarView(scalars.prefix(2)))
                scalars = scalars.dropFirst(2)
                if let value = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(value) { out.append(decoded) }
            default: out.append(next)
            }
        }
        return String(out)
    }

    // MARK: Keys

    private static let letterCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
    private static let named: [String: (code: Int, characters: String)] = [
        "return": (kVK_Return, "\r"), "tab": (kVK_Tab, "\t"), "esc": (kVK_Escape, "\u{1b}"),
        "backspace": (kVK_Delete, "\u{7f}"), "delete": (kVK_ForwardDelete, "\u{F728}"), "space": (kVK_Space, " "),
        "up": (kVK_UpArrow, "\u{F700}"), "down": (kVK_DownArrow, "\u{F701}"),
        "left": (kVK_LeftArrow, "\u{F702}"), "right": (kVK_RightArrow, "\u{F703}"),
        "home": (kVK_Home, "\u{F729}"), "end": (kVK_End, "\u{F72B}"),
        "pgup": (kVK_PageUp, "\u{F72C}"), "pgdn": (kVK_PageDown, "\u{F72D}"),
        "f1": (kVK_F1, "\u{F704}"), "f2": (kVK_F2, "\u{F705}"), "f5": (kVK_F5, "\u{F708}"), "f12": (kVK_F12, "\u{F70F}"),
    ]

    private func sendKey(character: Character) {
        if character == "\n" || character == "\r" { sendKey(spec: "return"); return }
        if character == "\t" { sendKey(spec: "tab"); return }
        if character == "\u{1b}" { sendKey(spec: "esc"); return }
        if let base = Self.shifted[character] {
            press(code: Self.letterCodes[base]!, base: String(base), flags: .shift)
        } else if character.isUppercase, let code = Self.letterCodes[Character(character.lowercased())] {
            press(code: code, base: character.lowercased(), flags: .shift)
        } else if let code = Self.letterCodes[character] {
            press(code: code, base: String(character), flags: [])
        } else {
            // Nothing on a US layout types this; an IME would commit it.
            pane.view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func sendKey(spec: String) {
        var flags: NSEvent.ModifierFlags = []
        var parts = spec.split(separator: "+").map(String.init)
        let key = parts.removeLast()
        for part in parts {
            switch part {
            case "ctrl": flags.insert(.control)
            case "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "cmd": flags.insert(.command)
            default: log("unknown modifier \(part)")
            }
        }
        if let entry = Self.named[key] {
            press(code: entry.code, base: entry.characters, flags: flags)
        } else if let character = key.first, let code = Self.letterCodes[character] {
            press(code: code, base: key, flags: flags)
        } else {
            log("unknown key \(key)")
        }
    }

    /// Makes one event to ask the layout what the chord types, then the real event with that text.
    private func press(code: Int, base: String, flags: NSEvent.ModifierFlags) {
        func event(_ type: NSEvent.EventType, _ characters: String) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: base,
                isARepeat: false, keyCode: UInt16(code))
        }
        guard let probe = event(.keyDown, base) else { return }
        let isFunctionKey = base.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false
        let characters = isFunctionKey ? base : (probe.characters(byApplyingModifiers: flags) ?? base)
        guard let down = event(.keyDown, characters), let up = event(.keyUp, characters) else { return }
        pane.view.keyDown(with: down)
        pane.view.keyUp(with: up)
    }

    // MARK: Mouse

    private func point(col: Int, row: Int) -> NSPoint {
        let geometry = pane.view.gridGeometry
        let scale = pane.view.backingScale
        let origin = geometry.origin(ofColumn: col, row: row)
        let x = (CGFloat(origin.x) + CGFloat(geometry.cellSizePx.x) / 2) / scale
        let y = (CGFloat(origin.y) + CGFloat(geometry.cellSizePx.y) / 2) / scale
        return pane.view.convert(NSPoint(x: x, y: y), to: nil)
    }

    /// Global display coordinates, top-left origin, as CGEvent wants them.
    private func screenPoint(col: Int, row: Int) -> CGPoint {
        let screen = window.convertPoint(toScreen: point(col: col, row: row))
        return CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
    }

    private func mouse(_ rest: String) {
        let fields = rest.split(separator: " ").map(String.init)
        guard fields.count >= 3, let col = Int(fields[1]), let row = Int(fields[2]) else { return }
        let button = fields.count > 3 ? fields[3] : "left"
        var flags: NSEvent.ModifierFlags = []
        if fields.count > 4 {
            for part in fields[4].split(separator: ",") {
                switch part {
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                case "cmd": flags.insert(.command)
                default: break
                }
            }
        }
        let type: NSEvent.EventType
        switch (fields[0], button) {
        case ("down", "left"): type = .leftMouseDown
        case ("up", "left"): type = .leftMouseUp
        case ("drag", "left"): type = .leftMouseDragged
        case ("down", "right"): type = .rightMouseDown
        case ("up", "right"): type = .rightMouseUp
        case ("drag", "right"): type = .rightMouseDragged
        case ("down", _): type = .otherMouseDown
        case ("up", _): type = .otherMouseUp
        case ("drag", _): type = .otherMouseDragged
        default: type = .mouseMoved
        }
        // `NSEvent.mouseEvent` cannot set buttonNumber, so anything but left comes from a CGEvent.
        var made: NSEvent?
        if button == "left" || type == .mouseMoved {
            made = NSEvent.mouseEvent(
                with: type, location: point(col: col, row: row), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0,
                clickCount: fields.count > 5 ? Int(fields[5]) ?? 1 : 1, pressure: 1)
        } else if let cgType = CGEventType(rawValue: UInt32(type.rawValue)) {
            let which: CGMouseButton = button == "right" ? .right : .center
            if let cg = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: screenPoint(col: col, row: row),
                                mouseButton: which) {
                cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                made = NSEvent(cgEvent: cg)
            }
        }
        guard let event = made else { return }
        if fields[0] == "down" { print("BUTTON \(button) -> buttonNumber=\(event.buttonNumber) window=\(event.windowNumber) loc=\(event.locationInWindow)") }
        switch type {
        case .leftMouseDown: pane.view.mouseDown(with: event)
        case .leftMouseUp: pane.view.mouseUp(with: event)
        case .leftMouseDragged: pane.view.mouseDragged(with: event)
        case .rightMouseDown: pane.view.rightMouseDown(with: event)
        case .rightMouseUp: pane.view.rightMouseUp(with: event)
        case .rightMouseDragged: pane.view.rightMouseDragged(with: event)
        case .otherMouseDown: pane.view.otherMouseDown(with: event)
        case .otherMouseUp: pane.view.otherMouseUp(with: event)
        case .otherMouseDragged: pane.view.otherMouseDragged(with: event)
        default: pane.mouse.mouseMoved(with: event)
        }
    }

    private func wheel(_ rest: String) {
        let numbers = rest.split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 3 else { return }
        // Up in wheel lines scrolls towards history, the same sign `scrollingDeltaY` carries.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: Int32(numbers[0]), wheel2: 0, wheel3: 0) else { return }
        cg.location = screenPoint(col: numbers[1], row: numbers[2])
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cg) else { return }
        print("WHEEL deltaY=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) loc=\(event.locationInWindow)")
        pane.view.scrollWheel(with: event)
    }
}
