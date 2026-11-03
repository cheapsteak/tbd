// QLPreviewView / AVPlayerView probe. Bare executable, no bundle.
import AppKit
import AVFoundation
import AVKit
import CoreAudio
import Darwin
import Quartz
import QuickLookUI
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let t0 = DispatchTime.now().uptimeNanoseconds
func ms() -> String { String(format: "%9.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
func log(_ s: String) { print("[\(ms())] \(s)") }

let fifoPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/qlprobe.fifo"

// MARK: - CoreAudio watcher

func getUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
    return st == noErr ? v : nil
}

func defaultOutputDevice() -> AudioObjectID {
    getUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
}

func processObjects() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func pidOf(_ obj: AudioObjectID) -> pid_t {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var p: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &p)
    return p
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    if n > 0 { return (String(cString: buf) as NSString).lastPathComponent }
    return "?"
}

func audioState() -> String {
    let dev = defaultOutputDevice()
    let running = getUInt32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 ? "RUNNING" : "idle" } ?? "err"
    var outs: [String] = []
    for p in processObjects() {
        if getUInt32(p, kAudioProcessPropertyIsRunningOutput) == 1 {
            let pid = pidOf(p)
            outs.append("\(pid):\(procName(pid))")
        }
    }
    return "device=\(running) outputProcs=[\(outs.sorted().joined(separator: ", "))]"
}

var lastAudio = ""
func pollAudio(force: Bool = false) {
    let s = audioState()
    if s != lastAudio || force {
        log("AUDIO \(s)")
        lastAudio = s
    }
}

// MARK: - process watcher (QuickLook-ish helpers)

let procRegex = try! NSRegularExpression(pattern: "quicklook|qlpreview|satellite|extensionkit|preview|thumbnail|ql[A-Z]|mediaextension|avconference|AVKit|viewservice", options: [.caseInsensitive])
var lastProcs: Set<String> = []
func psSnapshot() -> Set<String> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,ppid=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    var out: Set<String> = []
    for line in text.split(separator: "\n") {
        let s = String(line)
        if procRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count == 3 {
                out.insert("\(parts[0]) ppid=\(parts[1]) \((String(parts[2]) as NSString).lastPathComponent)")
            }
        }
    }
    return out
}
let psQueue = DispatchQueue(label: "ps")
func pollProcs(initial: Bool = false) {
    psQueue.async {
        let now = psSnapshot()
        DispatchQueue.main.async {
            if initial {
                log("PROCS baseline (\(now.count)): \(now.sorted().joined(separator: " | "))")
            } else {
                let added = now.subtracting(lastProcs), removed = lastProcs.subtracting(now)
                for a in added.sorted() { log("PROCS + \(a)") }
                for r in removed.sorted() { log("PROCS - \(r)") }
            }
            lastProcs = now
        }
    }
}


func qlInternalState(_ v: QLPreviewView, dumpAll: Bool = false) -> String {
    guard let iv = class_getInstanceVariable(QLPreviewView.self, "_reserved"), let resAny = object_getIvar(v, iv) else { return "no _reserved" }
    let res = resAny as AnyObject
    var count: UInt32 = 0
    guard let cls = object_getClass(res), let list = class_copyIvarList(cls, &count) else { return "no ivars" }
    var out = [String]()
    let base = Unmanaged.passUnretained(res).toOpaque()
    for i in 0..<Int(count) {
        let ivar = list[i]
        let name = ivar_getName(ivar).map { String(cString: $0) } ?? "?"
        let enc = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?"
        let off = ivar_getOffset(ivar)
        var val = ""
        switch enc {
        case "q", "Q": val = "=\(base.advanced(by: off).load(as: Int.self))"
        case "i", "I": val = "=\(base.advanced(by: off).load(as: Int32.self))"
        case "c", "B": val = "=\(base.advanced(by: off).load(as: UInt8.self))"
        default: break
        }
        if dumpAll || name.lowercased().contains("state") || name.lowercased().contains("close") { out.append("\(name)(\(enc))\(val)") }
    }
    free(list)
    return "\(NSStringFromClass(cls)): " + out.joined(separator: " ")
}

// MARK: - App

final class Probe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var container: NSView!
    var ql: QLPreviewView?
    var av: AVPlayerView?
    var avObs: NSKeyValueObservation?
    var lastTick = DispatchTime.now().uptimeNanoseconds

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "QLProbe"
        window.isReleasedWhenClosed = false
        window.delegate = self
        container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(container)
        makeQL()
        window.orderFrontRegardless()
        log("READY pid=\(getpid()) windowNumber=\(window.windowNumber) bundleID=\(Bundle.main.bundleIdentifier ?? "nil") appearance=\(window.effectiveAppearance.name.rawValue)")
        pollAudio(force: true)
        pollProcs(initial: true)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in pollAudio() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in pollProcs() }
        // main-thread stall detector
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let gap = Double(now - self.lastTick) / 1e6
            if gap > 120 { log("STALL main run loop gap \(String(format: "%.0f", gap)) ms") }
            self.lastTick = now
        }
        startFIFO()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func windowWillClose(_ n: Notification) { log("windowWillClose") }

    func makeQL() {
        let v = QLPreviewView(frame: container.bounds, style: .normal)!
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        ql = v
        log("new QLPreviewView autostarts=\(v.autostarts) shouldCloseWithWindow=\(v.shouldCloseWithWindow)")
    }

    func startFIFO() {
        let path = fifoPath
        Thread.detachNewThread {
            let fd = open(path, O_RDWR)
            guard fd >= 0, let f = fdopen(fd, "r") else { log("FIFO open failed \(errno)"); return }
            var line: UnsafeMutablePointer<CChar>? = nil
            var cap = 0
            while getline(&line, &cap, f) > 0 {
                let s = String(cString: line!).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                DispatchQueue.main.async { self.handle(s) }
            }
        }
    }

    func timed(_ label: String, _ body: () -> Void) {
        let a = DispatchTime.now().uptimeNanoseconds
        body()
        let d = Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6
        log("  \(label) took \(String(format: "%.2f", d)) ms on main")
    }

    func load(_ path: String) {
        guard let v = ql else { log("no QL view"); return }
        let url = URL(fileURLWithPath: path)
        let ut = UTType(filenameExtension: url.pathExtension)?.identifier ?? "?"
        timed("previewItem=\(url.lastPathComponent) [\(ut)]") { v.previewItem = url as NSURL }
    }

    func dumpTree(_ v: NSView, _ depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        print("\(pad)\(type(of: v)) frame=\(NSStringFromRect(v.frame)) hidden=\(v.isHidden)")
        for s in v.subviews { dumpTree(s, depth + 1) }
    }

    func handle(_ cmd: String) {
        log("CMD \(cmd)")
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "load": load(arg)
        case "burst":
            // burst <delayms> p1 p2 ...
            let toks = arg.split(separator: " ").map(String.init)
            let delay = Double(toks.first ?? "0") ?? 0
            for (i, p) in toks.dropFirst().enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(i) / 1000) { self.log2("burst[\(i)]"); self.load(p) }
            }
        case "nil": timed("previewItem=nil") { ql?.previewItem = nil }
        case "refresh": timed("refreshPreviewItem") { ql?.refreshPreviewItem() }
        case "close": timed("close()") { ql?.close() }
        case "newview":
            ql?.removeFromSuperview(); ql = nil; makeQL()
        case "autostarts": ql?.autostarts = (arg == "on"); log("  autostarts=\(ql?.autostarts ?? false)")
        case "closewithwindow": ql?.shouldCloseWithWindow = (arg == "on"); log("  shouldCloseWithWindow=\(ql?.shouldCloseWithWindow ?? false)")
        case "detach": timed("QL removeFromSuperview") { ql?.removeFromSuperview() }
        case "attach":
            if let v = ql { v.frame = container.bounds; timed("QL addSubview") { container.addSubview(v) } }
        case "hide": ql?.isHidden = true
        case "show": ql?.isHidden = false
        case "contenthide": container.isHidden = true
        case "contentshow": container.isHidden = false
        case "dark": window.appearance = NSAppearance(named: .darkAqua); log("  appearance=\(window.effectiveAppearance.name.rawValue)")
        case "light": window.appearance = NSAppearance(named: .aqua); log("  appearance=\(window.effectiveAppearance.name.rawValue)")
        case "viewdark": ql?.appearance = NSAppearance(named: .darkAqua)
        case "viewlight": ql?.appearance = NSAppearance(named: .aqua)
        case "closewin": window.close()
        case "openwin": window.orderFrontRegardless()
        case "mini": window.miniaturize(nil)
        case "unmini": window.deminiaturize(nil)
        case "displaystate": log("  displayState=\(String(describing: ql?.displayState))")
        case "tree":
            print("---- window tree")
            dumpTree(window.contentView!, 0)
            print("---- end tree")
        case "state": log("  state: \(ql.map { qlInternalState($0) } ?? "no view")")
        case "ivars": log("  ivars: \(ql.map { qlInternalState($0, dumpAll: true) } ?? "no view")")
        case "freshload":
            if let old = ql { if qlInternalState(old).contains("internalState(i)=1") { old.close() } else { log("  skip close(): view not activated") }; old.removeFromSuperview() }
            ql = nil; makeQL(); load(arg)
        case "audio": pollAudio(force: true)
        case "procs": psQueue.async { let s = psSnapshot(); DispatchQueue.main.async { log("PROCS now: \(s.sorted().joined(separator: " | "))") } }
        // AVPlayerView
        case "avplayer":
            ql?.removeFromSuperview()
            av?.removeFromSuperview()
            let pv = AVPlayerView(frame: container.bounds)
            pv.autoresizingMask = [.width, .height]
            pv.controlsStyle = .inline
            let player = AVPlayer(url: URL(fileURLWithPath: arg))
            timed("AVPlayerView.player=") { pv.player = player }
            avObs = player.observe(\.timeControlStatus, options: [.initial, .new]) { p, _ in
                let s: String
                switch p.timeControlStatus { case .paused: s = "paused"; case .playing: s = "playing"; case .waitingToPlayAtSpecifiedRate: s = "waiting"; @unknown default: s = "?" }
                DispatchQueue.main.async { log("AV timeControlStatus=\(s) rate=\(p.rate)") }
            }
            container.addSubview(pv)
            av = pv
        case "avplay": av?.player?.play()
        case "avpause": av?.player?.pause()
        case "avdetach": av?.removeFromSuperview()
        case "avattach": if let pv = av { pv.frame = container.bounds; container.addSubview(pv) }
        case "avhide": av?.isHidden = true
        case "avshow": av?.isHidden = false
        case "avdrop": av?.removeFromSuperview(); av = nil; avObs = nil
        case "ql":
            av?.removeFromSuperview()
            if let v = ql { v.frame = container.bounds; container.addSubview(v) } else { makeQL() }
        case "quit": log("bye"); NSApp.terminate(nil)
        default: log("unknown command")
        }
    }
    func log2(_ s: String) { log(s) }
}

let napToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "probe stall detector")
let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
