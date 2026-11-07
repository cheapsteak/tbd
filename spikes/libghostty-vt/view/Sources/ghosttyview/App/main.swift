// ghosttyview: one window, N terminals, each a real PTY drawn by the Metal renderer in ../Render.
// THROWAWAY. See ../../../../README.md.
//
//   ghosttyview [--cmd CMD] [--cols C --rows R] [--panes N]
//               [--shot out.png --shot-after S] [--stats out.json] [--script file] [--out-dir dir]
//               [--font NAME] [--font-file PATH] [--font-size PT] [--option-as-alt never|left|right|both]
//               [--cwd DIR] [--timeout S] [--stats-after S]
import AppKit
import CoreText
import Darwin
import Foundation
import Metal

struct Args {
    var cmd: String?
    var cols = 100
    var rows = 30
    var panes = 1
    var shot: String?
    var shotAfter = 3.0
    var statsPath: String?
    var statsAfter = 0.0
    var script: String?
    var outDir = "."
    var font: String?
    var fontFile: String?
    var fontSize: CGFloat = 13
    var optionAsAlt = OptionAsAlt.never
    var cwd: String?
    var timeout: Double?

    init(_ argv: [String]) {
        var i = 1
        func value() -> String {
            i += 1
            guard i < argv.count else { fatalError("missing value for \(argv[i - 1])") }
            return argv[i]
        }
        while i < argv.count {
            switch argv[i] {
            case "--cmd": cmd = value()
            case "--cols": cols = Int(value())!
            case "--rows": rows = Int(value())!
            case "--panes": panes = Int(value())!
            case "--shot": shot = value()
            case "--shot-after": shotAfter = Double(value())!
            case "--stats": statsPath = value()
            case "--stats-after": statsAfter = Double(value())!
            case "--script": script = value()
            case "--out-dir": outDir = value()
            case "--font": font = value()
            case "--font-file": fontFile = value()
            case "--font-size": fontSize = CGFloat(Double(value())!)
            case "--cwd": cwd = value()
            case "--timeout": timeout = Double(value())!
            case "--option-as-alt":
                switch value() {
                case "left": optionAsAlt = .left
                case "right": optionAsAlt = .right
                case "both": optionAsAlt = .both
                default: optionAsAlt = .never
                }
            default: fatalError("unknown argument \(argv[i])")
            }
            i += 1
        }
    }

    /// Nobody is at the window, so nothing may take focus and the run must end by itself.
    var unattended: Bool { shot != nil || script != nil || statsPath != nil }
}

/// One terminal: view, session, pty and the two input controllers.
@MainActor
final class Pane {
    let view: TerminalMetalView
    let input = TerminalInputController()
    let mouse = MouseController()
    var session: TerminalSession!
    var pty: Pty?
    var exit: ExitStatus?

    init(context: TerminalRenderContext, frame: NSRect) {
        view = TerminalMetalView(renderContext: context, frame: frame)
    }

    func start(args: Args, onTitle: @escaping (String) -> Void) throws {
        let size = view.gridSizeForBounds()
        var options = TerminalSessionOptions(
            cols: size.cols, rows: size.rows,
            cellWidthPx: UInt32(size.cellWidthPx), cellHeightPx: UInt32(size.cellHeightPx))
        options.theme = view.renderContext.theme
        let session = try TerminalSession(options: options)
        self.session = session

        input.optionAsAlt = args.optionAsAlt
        input.mouseHandler = mouse
        input.writeInput = { [weak self] data in try? self?.pty?.write(data) }
        input.isFocusReportingEnabled = { session.mode(1004) }
        mouse.sendBytes = { [weak self] bytes in try? self?.pty?.write(Data(bytes)) }
        session.selectionDoubleClickInterval = NSEvent.doubleClickInterval
        view.inputDelegate = input
        view.onGridResize = { [weak self] size in try? self?.pty?.resize(size) }

        view.show(session)
        mouse.attach(to: view)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let argv = args.cmd.map { ["/bin/zsh", "-c", $0] } ?? [shell, "-l"]
        let spawn = PtySpawn(
            executablePath: argv[0], argv: argv, environment: TerminalEnvironment.make(),
            cwd: args.cwd, size: view.gridSizeForBounds())
        let pty = try Pty(
            spawn: spawn, ioQueue: session.ioQueue,
            onData: { session.write(ptyBytes: $0) },
            onExit: { exit in
                let status = exit.exitCode.map { ExitStatus.exited(code: $0) } ?? .signaled(signal: exit.signal ?? 0)
                session.noteExit(status)
            })
        self.pty = pty
        session.setOnWritePty { [weak pty] data in try? pty?.write(data) }

        Task { @MainActor [weak self] in
            for await event in session.events {
                guard let self else { return }
                switch event {
                case .title(let title):
                    onTitle(title)
                    log("event title \(title.debugDescription)")
                case .clipboardWrite(let text):
                    self.mouse.handle(event)
                    log("event osc-clipboard-write \(text.debugDescription)")
                case .exited(let status):
                    self.exit = status
                    self.view.setCursorSuppressed(true)
                    log("event exited \(status)")
                case .bell:
                    log("event bell")
                case .pwd(let pwd):
                    log("event pwd \(pwd.debugDescription)")
                case .notification(let title, let body):
                    log("event notification \(title.debugDescription) \(body.debugDescription)")
                case .progress(let state, let value):
                    log("event progress \(state) \(value.map(String.init) ?? "nil")")
                case .foreground:
                    break
                }
            }
        }
    }

    /// The pane's current screen, read back from a texture the renderer drew.
    func texture() throws -> MTLTexture {
        let renderer = view.renderContext.renderer
        let size = view.metalLayer?.drawableSize ?? CGSize(width: 1, height: 1)
        guard let texture = renderer.makeOffscreenTexture(width: Int(size.width), height: Int(size.height)) else {
            throw RenderError(result: -1, operation: "makeOffscreenTexture")
        }
        view.surface.markNeedsDisplay()
        let outcome = try renderer.render(surface: view.surface, to: texture)
        outcome.commandBuffer?.waitUntilCompleted()
        view.frameDriver.requestFrame()
        return texture
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Lays the panes out in a grid and re-lays them out when the window resizes.
final class PaneGrid: NSView {
    var columns = 1
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutPanes() }
    func layoutPanes() {
        let count = subviews.count
        guard count > 0 else { return }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let width = floor(bounds.width / CGFloat(columns)), height = floor(bounds.height / CGFloat(rows))
        for (index, view) in subviews.enumerated() {
            view.frame = NSRect(x: CGFloat(index % columns) * width, y: CGFloat(index / columns) * height,
                                width: width - (columns > 1 ? 2 : 0), height: height - (rows > 1 ? 2 : 0))
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let args: Args
    var window: NSWindow!
    var grid: PaneGrid!
    var panes: [Pane] = []
    var context: TerminalRenderContext!
    var scriptPasteboard: NSPasteboard?

    init(args: Args) { self.args = args }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try launch() } catch {
            log("launch failed: \(error)")
            exit(1)
        }
    }

    private func launch() throws {
        if let path = args.fontFile {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &error) {
                log("font registration failed: \(String(describing: error?.takeRetainedValue()))")
            }
        }
        var theme = Theme()
        theme.fontMono.terminal = args.fontSize
        if let font = args.font { theme.fontMono.family = font }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        context = try TerminalRenderContext(theme: theme, scale: screen.backingScaleFactor)

        let scale = screen.backingScaleFactor
        let metrics = context.metrics
        let columns = Int(ceil(Double(args.panes).squareRoot()))
        let rows = Int(ceil(Double(args.panes) / Double(columns)))
        var content = NSSize(
            width: CGFloat(args.cols * metrics.width * columns) / scale,
            height: CGFloat(args.rows * metrics.height * rows) / scale)
        // A wall of panes is bounded by the screen, so each pane shrinks instead of overflowing.
        let visible = screen.visibleFrame.size
        content.width = min(content.width, visible.width - 40)
        content.height = min(content.height, visible.height - 60)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ghosttyview"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        grid = PaneGrid(frame: NSRect(origin: .zero, size: content))
        grid.columns = columns
        grid.autoresizesSubviews = true
        grid.autoresizingMask = [.width, .height]
        window.contentView = grid
        for _ in 0..<args.panes {
            let pane = Pane(context: context, frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            panes.append(pane)
            grid.addSubview(pane.view)
        }
        grid.layoutPanes()

        if args.unattended {
            window.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(panes[0].view)
        let single = args.panes == 1
        for pane in panes {
            try pane.start(args: args) { [weak self] title in
                if single { self?.window.title = title }
            }
        }
        if args.unattended { panes[0].view.setFocused(true) }

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Stats.shared.sampleFootprint()
        }
        if args.statsAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + args.statsAfter) { Stats.shared.reset() }
        }
        armTimeout()

        if let script = args.script {
            let harness = Harness(app: self)
            Task { await harness.run(path: script) }
        } else if let shot = args.shot {
            DispatchQueue.main.asyncAfter(deadline: .now() + args.shotAfter) { [self] in
                self.writeShot(to: shot)
                self.finish(0)
            }
        } else if args.statsPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + args.shotAfter) { [self] in self.finish(0) }
        }
    }

    /// Off the main thread, so a wedged run loop cannot stop it.
    private func armTimeout() {
        var seconds = args.timeout
        if seconds == nil, args.script != nil { seconds = 180 }
        if seconds == nil, args.unattended { seconds = args.shotAfter + 30 }
        guard let seconds else { return }
        let pids = panes.compactMap { $0.pty?.pid }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            log("TIMEOUT after \(seconds) s")
            for pid in pids { kill(-pid, SIGHUP); kill(pid, SIGHUP) }
            exit(124)
        }
    }

    func writeShot(to path: String) {
        do {
            let image = try compositeImage()
            guard let data = GlyphRasterizer.pngData(from: image) else {
                log("png encoding failed")
                return
            }
            FileManager.default.createFile(atPath: path, contents: data)
            log("shot \(path) \(image.width)x\(image.height)")
        } catch {
            log("shot failed: \(error)")
        }
    }

    private func compositeImage() throws -> CGImage {
        let textures = try panes.map { try $0.texture() }
        if textures.count == 1, let image = TerminalRenderer.makeCGImage(from: textures[0]) { return image }
        let scale = window.backingScaleFactor
        let width = Int(grid.bounds.width * scale), height = Int(grid.bounds.height * scale)
        guard let cg = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw RenderError(result: -1, operation: "CGContext") }
        cg.setFillColor(gray: 0.3, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (pane, texture) in zip(panes, textures) {
            guard let image = TerminalRenderer.makeCGImage(from: texture) else { continue }
            let frame = pane.view.frame
            cg.draw(image, in: CGRect(
                x: frame.minX * scale, y: CGFloat(height) - frame.maxY * scale,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        guard let image = cg.makeImage() else { throw RenderError(result: -1, operation: "makeImage") }
        return image
    }

    func finish(_ code: Int32) {
        if let path = args.statsPath {
            let bytes = context.renderer.glyphCache.grayscale.size * context.renderer.glyphCache.grayscale.size
            Stats.shared.write(to: path, panes: panes.count, extra: [
                "cellPx": [context.metrics.width, context.metrics.height],
                "grid": [panes[0].view.currentGridSize.cols, panes[0].view.currentGridSize.rows],
                "grayscaleAtlasSide": context.renderer.glyphCache.grayscale.size,
                "grayscaleAtlasBytes": bytes,
                "frameRingBytesAllPanes": panes.reduce(0) { $0 + ($1.view.surface.frameRing?.byteCount ?? 0) },
            ])
        }
        for pane in panes { if let pid = pane.pty?.pid { kill(-pid, SIGHUP); kill(pid, SIGHUP) } }
        exit(code)
    }

    @objc func copyAction(_ sender: Any?) { focusedPane.map { _ = $0.mouse.copySelection(in: $0.view) } }
    @objc func pasteAction(_ sender: Any?) { focusedPane.map { _ = $0.mouse.pasteFromPasteboard(in: $0.view) } }
    private var focusedPane: Pane? { panes.first { $0.view === window.firstResponder } }
}

func makeMenu(target: AppController) -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit ghosttyview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem(); main.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    let copy = editMenu.addItem(withTitle: "Copy", action: #selector(AppController.copyAction(_:)), keyEquivalent: "c")
    let paste = editMenu.addItem(withTitle: "Paste", action: #selector(AppController.pasteAction(_:)), keyEquivalent: "v")
    copy.target = target; paste.target = target
    editItem.submenu = editMenu
    return main
}

let parsed = Args(CommandLine.arguments)
let app = NSApplication.shared
// No bundle: this has to happen before a window is shown or the app never gets a Dock presence.
app.setActivationPolicy(.regular)
let controller = MainActor.assumeIsolated { AppController(args: parsed) }
app.delegate = controller
app.mainMenu = MainActor.assumeIsolated { makeMenu(target: controller) }
app.run()
