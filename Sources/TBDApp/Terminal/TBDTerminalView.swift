import AppKit
import SwiftTerm

/// Subclass of SwiftTerm's TerminalView that adds natural text editing support.
/// When enabled, macOS-native shortcuts (Cmd+Arrow, Cmd/Opt+Delete) are translated
/// to the escape sequences that shells expect.
class TBDTerminalView: TerminalView {
    var naturalTextEditing: Bool = true
    var onFilePathClicked: ((String) -> Void)?
    var worktreePath: String = ""

    // MARK: - Mouse click pass-through
    // Track mouseDown position to distinguish clicks from drags.
    // Single clicks are forwarded to tmux for pane switching;
    // click-drags are handled locally by SwiftTerm for text selection.
    //
    // Because SwiftTerm's TerminalView declares its mouse overrides as
    // `public` (not `open`), we cannot override them from another module.
    // Instead we install a local event monitor that observes mouseDown /
    // mouseDragged / mouseUp and forwards clicks after SwiftTerm has
    // already processed them.
    private var mouseDownLocation: CGPoint = .zero
    private var didDrag: Bool = false
    private static let dragThreshold: CGFloat = 3.0
    nonisolated(unsafe) private var mouseMonitor: Any?

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            // Only handle events that target this view
            guard let eventWindow = event.window, eventWindow == self.window else { return event }
            let locationInSelf = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInSelf) else { return event }

            switch event.type {
            case .leftMouseDown:
                self.mouseDownLocation = locationInSelf
                self.didDrag = false
            case .leftMouseDragged:
                let dx = locationInSelf.x - self.mouseDownLocation.x
                let dy = locationInSelf.y - self.mouseDownLocation.y
                if sqrt(dx * dx + dy * dy) > Self.dragThreshold {
                    self.didDrag = true
                }
            case .leftMouseUp:
                self.handleClickPassthrough(at: locationInSelf)
            default:
                break
            }
            return event  // always pass the event through
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMouseMonitor()
        } else {
            removeMouseMonitor()
        }
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handleClickPassthrough(at point: CGPoint) {
        // If this was a click (not a drag) and tmux has mouse mode enabled,
        // forward the click to tmux so it can handle pane switching.
        //
        // This won't produce duplicate events: allowMouseReporting is set to
        // false in TerminalPanelView, so SwiftTerm's mouseDown/mouseUp only
        // handle local text selection — they never forward to the pty.
        // We are the sole path that sends mouse events to tmux.
        let term = getTerminal()
        guard !didDrag && term.mouseMode != .off else { return }

        let charWidth = bounds.width / CGFloat(term.cols)
        let lineHeight = bounds.height / CGFloat(term.rows)
        let col = Int(point.x / charWidth)
        let row = Int((bounds.height - point.y) / lineHeight)

        let pressFlags = term.encodeButton(
            button: 0, release: false,
            shift: false, meta: false, control: false
        )
        term.sendEvent(buttonFlags: pressFlags, x: col, y: row)

        let releaseFlags = term.encodeButton(
            button: 0, release: true,
            shift: false, meta: false, control: false
        )
        term.sendEvent(buttonFlags: releaseFlags, x: col, y: row)
    }

    /// Extracts a file path from the terminal buffer at the given window-coordinate point.
    func extractFilePath(atWindowLocation windowPoint: CGPoint) -> String? {
        let localPoint = convert(windowPoint, from: nil)
        let terminal = getTerminal()

        // Derive cell dimensions from the terminal's actual grid size and view bounds
        let charWidth = bounds.width / CGFloat(terminal.cols)
        let lineHeight = bounds.height / CGFloat(terminal.rows)

        let col = Int(localPoint.x / charWidth)
        // Terminal rows are numbered from top, but NSView y is from bottom
        let row = Int((frame.height - localPoint.y) / lineHeight)

        guard row >= 0 && row < terminal.rows && col >= 0 && col < terminal.cols else {
            return nil
        }

        guard let bufferLine = terminal.getLine(row: row) else { return nil }
        let lineText = bufferLine.translateToString()

        guard col < lineText.count else { return nil }

        // Find word boundaries around click position using path-valid characters
        let pathChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~"))
        let chars = Array(lineText.unicodeScalars)
        var start = col
        var end = col

        while start > 0 && pathChars.contains(chars[start - 1]) {
            start -= 1
        }
        while end < chars.count - 1 && pathChars.contains(chars[end + 1]) {
            end += 1
        }

        guard start <= end else { return nil }

        let startIndex = lineText.index(lineText.startIndex, offsetBy: start)
        let endIndex = lineText.index(lineText.startIndex, offsetBy: end + 1)
        var candidate = String(lineText[startIndex..<endIndex])

        // Strip trailing :line:col suffix (e.g., "file.swift:10:5")
        let colonPattern = try? NSRegularExpression(pattern: ":\\d+(:\\d+)?$")
        if let match = colonPattern?.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) {
            candidate = String(candidate[candidate.startIndex..<candidate.index(candidate.startIndex, offsetBy: match.range.location)])
        }

        guard !candidate.isEmpty else { return nil }

        // Resolve relative paths against worktreePath
        let resolvedPath: String
        if candidate.hasPrefix("/") {
            resolvedPath = candidate
        } else {
            resolvedPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(candidate).path
        }

        // Validate file exists
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return nil }

        return resolvedPath
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if naturalTextEditing, event.type == .keyDown, handleNaturalTextEditing(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleNaturalTextEditing(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let hasCmd = flags.contains(.command)
        let hasOpt = flags.contains(.option)
        let hasCtrl = flags.contains(.control)
        let hasShift = flags.contains(.shift)

        guard !hasCtrl, let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return false
        }
        let key = Int(scalar.value)

        if hasCmd && !hasOpt && !hasShift {
            // Use Home/End escape sequences instead of Ctrl-A/Ctrl-E
            // to avoid conflict with tmux prefix key (commonly Ctrl-A)
            if key == NSLeftArrowFunctionKey {
                send([0x1B, 0x5B, 0x48]) // ESC [ H (Home)
                return true
            }
            if key == NSRightArrowFunctionKey {
                send([0x1B, 0x5B, 0x46]) // ESC [ F (End)
                return true
            }
            if scalar.value == 0x7F {
                send([0x15]) // Ctrl-U (delete to line start)
                return true
            }
        }

        if hasOpt && !hasCmd && !hasShift {
            if scalar.value == 0x7F {
                send([0x1B, 0x7F]) // ESC DEL (delete word back)
                return true
            }
            if key == NSDeleteFunctionKey {
                send([0x1B, 0x64]) // ESC d (delete word forward)
                return true
            }
        }

        return false
    }

}
