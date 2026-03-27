import AppKit
import SwiftTerm

/// Subclass of SwiftTerm's TerminalView that adds natural text editing support.
/// When enabled, macOS-native shortcuts (Cmd+Arrow, Cmd/Opt+Delete) are translated
/// to the escape sequences that shells expect.
class TBDTerminalView: TerminalView {
    var naturalTextEditing: Bool = true
    var onFilePathClicked: ((String) -> Void)?
    var worktreePath: String = ""
    var remoteURL: String?
    var onNotification: ((String, String) -> Void)?

    // MARK: - Cell dimension calculation

    /// Computes cell dimensions from font metrics, matching SwiftTerm's internal calculation.
    /// SwiftTerm uses `cellDimension` (internal) derived from CTFont metrics, not bounds/cols.
    /// Using bounds/cols gives wrong results because of scroller width and rounding.
    private var cachedCellDimensions: (width: CGFloat, height: CGFloat)?

    func cellDimensions() -> (width: CGFloat, height: CGFloat) {
        if let cached = cachedCellDimensions { return cached }
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let glyph = font.glyph(withName: "W")
        let cellWidth = font.advancement(forGlyph: glyph).width
        let cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let dims = (cellWidth, cellHeight)
        cachedCellDimensions = dims
        return dims
    }

    /// Converts a window-coordinate point to terminal grid (col, row).
    func gridPosition(atWindowLocation windowPoint: CGPoint) -> (col: Int, row: Int)? {
        let localPoint = convert(windowPoint, from: nil)
        let terminal = getTerminal()
        let cell = cellDimensions()

        let col = Int(localPoint.x / cell.width)
        let row = Int((bounds.height - localPoint.y) / cell.height)

        guard row >= 0 && row < terminal.rows && col >= 0 && col < terminal.cols else {
            return nil
        }
        return (col, row)
    }

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

        let cell = cellDimensions()
        let col = Int(point.x / cell.width)
        let row = Int((bounds.height - point.y) / cell.height)

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
        guard let pos = gridPosition(atWindowLocation: windowPoint) else { return nil }
        let col = pos.col
        let row = pos.row
        let terminal = getTerminal()

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

        // Validate it's a regular file (not a directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), !isDir.boolValue else { return nil }

        return resolvedPath
    }

    /// Extracts a clickable URL from the terminal buffer at the given window-coordinate point.
    /// Checks for OSC 8 hyperlink payloads first, then falls back to pattern matching
    /// for common link patterns like "PR #123".
    func extractHyperlinkURL(atWindowLocation windowPoint: CGPoint) -> String? {
        guard let pos = gridPosition(atWindowLocation: windowPoint) else { return nil }
        let col = pos.col
        let row = pos.row
        let terminal = getTerminal()

        guard let line = terminal.getLine(row: row) else { return nil }
        guard col < line.count else { return nil }

        // Check for OSC 8 payload first
        if let payload = line[col].getPayload() as? String {
            let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count > 1 {
                let url = String(parts[1])
                if !url.isEmpty { return url }
            }
        }

        // Build visible text from line (translateToString may return empty for status bar lines)
        var visibleText = ""
        for c in 0..<line.count {
            let val = line[c].getCharacter().unicodeScalars.first?.value ?? 0
            visibleText.append(val > 0 ? line[c].getCharacter() : " ")
        }

        // Look for "PR #123" pattern anywhere on the line.
        // Wide/emoji chars (e.g. ▶▶) make positional matching unreliable,
        // so match anywhere on the row rather than checking click position.
        if let match = Self.prPattern.firstMatch(in: visibleText, range: NSRange(visibleText.startIndex..., in: visibleText)),
           let numRange = Range(match.range(at: 1), in: visibleText),
           let repoURL = gitHubBrowserURL() {
            return "\(repoURL)/pull/\(String(visibleText[numRange]))"
        }

        return nil
    }

    private static let prPattern = try! NSRegularExpression(pattern: "PR\\s+#(\\d+)")

    /// Converts the repo's remote URL to a GitHub browser URL.
    private func gitHubBrowserURL() -> String? {
        guard var remote = remoteURL, !remote.isEmpty else { return nil }
        if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }
        if remote.hasPrefix("git@github.com:") {
            remote = "https://github.com/" + remote.dropFirst("git@github.com:".count)
        }
        return remote
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

    func notify(source: Terminal, title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only notify when this terminal is not focused
            guard self.window?.isKeyWindow != true else { return }
            self.onNotification?(title, body)
        }
    }

}
