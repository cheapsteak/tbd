// `signals`: which sequences reach the host, and by which route, in each engine.
import Foundation
import GhosttyVt
import SwiftTerm

private func str(_ s: GhosttyString) -> String {
    guard let p = s.ptr, s.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
}

/// The log a Ghostty callback writes into. Reached through OPT_USERDATA.
final class GLog {
    var events: [String] = []
    var pty: [UInt8] = []
    var unknownSequences = 0
}

private func log(_ u: UnsafeMutableRawPointer?) -> GLog { Unmanaged<GLog>.fromOpaque(u!).takeUnretainedValue() }

private func set(_ t: GhosttyTerminal?, _ o: GhosttyTerminalOption, _ f: UnsafeRawPointer?) {
    precondition(ghostty_terminal_set(t, o, f) == GHOSTTY_SUCCESS, "set \(o)")
}

private let writePty: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { _, u, d, n in
    log(u).pty.append(contentsOf: UnsafeBufferPointer(start: d, count: n))
}
private let bell: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> Void = { _, u in log(u).events.append("BELL") }
private let titleChanged: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> Void = { t, u in
    var s = GhosttyString()
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_TITLE, &s)
    log(u).events.append("TITLE_CHANGED(\(str(s)))")
}
private let pwdChanged: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> Void = { t, u in
    var s = GhosttyString()
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_PWD, &s)
    log(u).events.append("PWD_CHANGED(\(str(s)))")
}
private let reset: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> Void = { _, u in log(u).events.append("RESET") }
private let renderHold: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, Bool) -> Void = { _, u, h in log(u).events.append("RENDER_HOLD(\(h))") }
private let enquiry: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> GhosttyString = { _, u in
    log(u).events.append("ENQUIRY"); return GhosttyString()
}
private let xtversion: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> GhosttyString = { _, u in
    log(u).events.append("XTVERSION"); return GhosttyString()
}
private let size: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafeMutablePointer<GhosttySizeReportSize>?) -> Bool = { _, u, o in
    log(u).events.append("SIZE")
    o!.pointee = GhosttySizeReportSize(rows: 24, columns: 80, cell_width: 8, cell_height: 16)
    return true
}
private let colorScheme: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafeMutablePointer<GhosttyColorScheme>?) -> Bool = { _, u, o in
    log(u).events.append("COLOR_SCHEME")
    o!.pointee = GHOSTTY_COLOR_SCHEME_DARK
    return true
}
private let deviceAttributes: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafeMutablePointer<GhosttyDeviceAttributes>?) -> Bool = { _, u, o in
    log(u).events.append("DEVICE_ATTRIBUTES")
    o!.pointee.primary.conformance_level = 62
    o!.pointee.primary.num_features = 0
    o!.pointee.secondary.device_type = 1
    o!.pointee.secondary.firmware_version = 10
    return true
}
private let clipWrite: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyClipboardWrite>?) -> Void = { _, u, w in
    let p = w!.pointee
    var parts: [String] = []
    for i in 0..<p.contents_len { parts.append("\(str(p.contents[i].mime))=\(str(p.contents[i].data))") }
    log(u).events.append("CLIPBOARD_WRITE(loc \(p.location.rawValue), \(parts.joined(separator: ",")))")
}
private let clipRead: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyClipboardRead>?) -> Void = { _, u, r in
    log(u).events.append("CLIPBOARD_READ(loc \(r!.pointee.location.rawValue))")
}
private let notification: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyTerminalDesktopNotification>?) -> Void = { _, u, n in
    log(u).events.append("DESKTOP_NOTIFICATION(\(str(n!.pointee.title))|\(str(n!.pointee.body)))")
}
private let progress: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyTerminalProgressReport>?) -> Void = { _, u, r in
    log(u).events.append("PROGRESS_REPORT(state \(r!.pointee.state.rawValue), \(r!.pointee.progress))")
}
private let programStatus: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyTerminalProgramStatus>?) -> Void = { _, u, r in
    let p = r!.pointee
    log(u).events.append("PROGRAM_STATUS(state \(p.state.rawValue), kind \(p.kind.rawValue), id \(str(p.id)), title \(str(p.title)), message \(str(p.message)))")
}
private let unknown: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyTerminalUnknownSequence>?) -> Void = { _, u, _ in
    log(u).unknownSequences += 1
}
private let semantic: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyTerminalSemanticPrompt>?) -> Void = { _, u, _ in
    log(u).events.append("SEMANTIC_PROMPT")
}
private let resizeWindow: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<GhosttyTerminalResizeWindow>?) -> Void = { _, u, _ in
    log(u).events.append("RESIZE_WINDOW")
}

private func wire(_ g: GTerm, _ l: GLog) {
    let t = g.t
    set(t, GHOSTTY_TERMINAL_OPT_USERDATA, UnsafeRawPointer(Unmanaged.passUnretained(l).toOpaque()))
    set(t, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_ENQUIRY, unsafeBitCast(enquiry, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(deviceAttributes, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdChanged, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipWrite, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, unsafeBitCast(clipRead, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notification, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, unsafeBitCast(progress, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(programStatus, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, unsafeBitCast(unknown, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(semantic, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_RESET, unsafeBitCast(reset, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(renderHold, to: UnsafeRawPointer.self))
    set(t, GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW, unsafeBitCast(resizeWindow, to: UnsafeRawPointer.self))
}

func runSignals(arguments: [String]) {
    let e = "\u{1b}", st = "\u{1b}\\", bel = "\u{07}"
    let cases: [(String, String)] = [
        ("OSC 7501 probe", "\(e)]7501;?\(st)"),
        ("OSC 7501 working", "\(e)]7501;state=working:app=claude-code\(bel)"),
        ("OSC 7501 blocked full", "\(e)]7501;state=blocked:kind=permission:app=claude-code:id=one:progress=40:title=QWxsb3c=\(st)"),
        ("OSC 7501 idle", "\(e)]7501;state=idle:app=claude-code\(bel)"),
        ("OSC 7501 clear", "\(e)]7501;state=clear\(st)"),
        ("OSC 0 title", "\(e)]0;both\(bel)"),
        ("OSC 2 title", "\(e)]2;t2\(bel)"),
        ("OSC 1 icon", "\(e)]1;icon\(bel)"),
        ("OSC 7 pwd", "\(e)]7;file://host/tmp/acme\(st)"),
        ("OSC 8 hyperlink", "\(e)]8;id=a;https://example.com/x\(st)L\(e)]8;;\(st)"),
        ("OSC 52 write", "\(e)]52;c;aGVsbG8=\(st)"),
        ("OSC 52 read", "\(e)]52;c;?\(st)"),
        ("OSC 777 notify", "\(e)]777;notify;Title;Body\(st)"),
        ("OSC 9 notify", "\(e)]9;plain body\(st)"),
        ("OSC 9;4 progress", "\(e)]9;4;1;40\(st)"),
        ("OSC 133 prompt", "\(e)]133;A\(st)"),
        ("OSC 1337 CurrentDir", "\(e)]1337;CurrentDir=/tmp\(bel)"),
        ("OSC 6 document", "\(e)]6;file:///tmp/doc\(bel)"),
        ("OSC 4 set color", "\(e)]4;1;rgb:11/22/33\(bel)"),
        ("OSC 10 query fg", "\(e)]10;?\(bel)"),
        ("OSC 11 query bg", "\(e)]11;?\(bel)"),
        ("BEL", bel),
        ("ENQ", "\u{05}"),
        ("DECRQM 2004", "\(e)[?2004$p"),
        ("DECRQM 1049", "\(e)[?1049$p"),
        ("DECRQM 2026", "\(e)[?2026$p"),
        ("DECRQM 2027", "\(e)[?2027$p"),
        ("DECRQM ANSI 4", "\(e)[4$p"),
        ("DA1", "\(e)[c"),
        ("DA2", "\(e)[>c"),
        ("DA3", "\(e)[=c"),
        ("DSR 5", "\(e)[5n"),
        ("DSR 6 CPR", "\(e)[6n"),
        ("DEC DSR ?6", "\(e)[?6n"),
        ("XTVERSION", "\(e)[>q"),
        ("size 14t pixels", "\(e)[14t"),
        ("size 16t cell", "\(e)[16t"),
        ("size 18t chars", "\(e)[18t"),
        ("resize 8t", "\(e)[8;30;90t"),
        ("title push 22t", "\(e)[22;0t"),
        ("title report 21t", "\(e)[21t"),
        ("kitty push", "\(e)[>1u"),
        ("kitty query", "\(e)[>1u\(e)[?u"),
        ("color scheme ?996n", "\(e)[?996n"),
        ("DECSCUSR", "\(e)[5 q"),
        ("sync begin", "\(e)[?2026h"),
        ("sync end", "\(e)[?2026h\(e)[?2026l"),
        ("mouse on", "\(e)[?1000h"),
        ("cursor hide", "\(e)[?25l"),
        ("RIS", "\(e)c"),
    ]
    print(padR("sequence", 28) + padR("SwiftTerm", 64) + "libghostty-vt")
    var rows: [[String: Any]] = []
    for (name, seq) in cases {
        let bytes = Array(seq.utf8)
        let s = STerm(cols: 80, rows: 24, scrollback: 100)
        var osc: [String] = []
        s.t.observeOscEvents { ev in osc.append("observeOsc(\(ev.code))") }
        s.t.registerOscHandler(code: 7501) { data in
            osc.append("oscHandler(7501,\(String(decoding: data, as: UTF8.self)))")
        }
        s.del.events.removeAll()   // Terminal init reports the mouse mode once
        s.feed(bytes)
        let sReply = escaped(s.del.replies)
        let sOut = (osc + s.del.events + (sReply.isEmpty ? [] : ["reply: " + sReply])).joined(separator: " ")

        let g = GTerm(cols: 80, rows: 24, scrollback: 100)
        let l = GLog()
        wire(g, l)
        g.feed(bytes)
        var parts = l.events
        let reply = escaped(l.pty)
        if !reply.isEmpty { parts.append("reply: " + reply) }
        if l.unknownSequences > 0 { parts.append("UNKNOWN_SEQUENCE x\(l.unknownSequences)") }
        let gOut = parts.joined(separator: " ")
        print(padR(name, 28) + padR(sOut.isEmpty ? "(nothing)" : sOut, 64) + (gOut.isEmpty ? "(nothing)" : gOut))
        rows.append(["sequence": name, "bytes": escaped(bytes), "swiftTerm": sOut, "ghostty": gOut])
        _ = withExtendedLifetime(l) {}
    }
    // Option getters that have no callback.
    let g = GTerm(cols: 80, rows: 24, scrollback: 100)
    g.feed(Array("\(e)[?1002h\(e)[?1006h".utf8))
    var tracking = false
    ghostty_terminal_get(g.t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
    print("\nDATA_MOUSE_TRACKING after ?1002h: \(tracking)")

    // OSC 10/11 with colours configured, and OSC 52 read answered through the reply hook.
    let c = GTerm(cols: 80, rows: 24, scrollback: 100)
    let cl = GLog()
    wire(c, cl)
    var fgColor = GhosttyColorRgb(r: 0x11, g: 0x22, b: 0x33), bgColor = GhosttyColorRgb(r: 0x44, g: 0x55, b: 0x66)
    ghostty_terminal_set(c.t, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fgColor)
    ghostty_terminal_set(c.t, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bgColor)
    c.feed(Array("\(e)]10;?\(bel)\(e)]11;?\(bel)".utf8))
    let colorReply = escaped(cl.pty)
    print("OSC 10/11 with colours set through OPT_COLOR_*: \(colorReply)")

    // Mouse tracking is one value in SwiftTerm and several mode bits in libghostty-vt.
    // A motion report with no button only comes out under any-motion tracking (1003).
    func reportsMotion(_ t: GTerm) -> Bool {
        var enc: GhosttyMouseEncoder?, ev: GhosttyMouseEvent?
        ghostty_mouse_encoder_new(nil, &enc)
        ghostty_mouse_event_new(nil, &ev)
        defer { ghostty_mouse_event_free(ev); ghostty_mouse_encoder_free(enc) }
        ghostty_mouse_encoder_set_from_terminal(enc, t.t)
        var sz = GhosttyMouseEncoderSize()
        sz.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        sz.screen_width = 800; sz.screen_height = 480; sz.cell_width = 10; sz.cell_height = 20
        ghostty_mouse_encoder_set(enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz)
        ghostty_mouse_event_set_action(ev, GHOSTTY_MOUSE_ACTION_MOTION)
        ghostty_mouse_event_clear_button(ev)
        ghostty_mouse_event_set_position(ev, GhosttyMousePosition(x: 15, y: 15))
        var buf = [CChar](repeating: 0, count: 64), written = 0
        ghostty_mouse_encoder_encode(enc, ev, &buf, 64, &written)
        return written > 0
    }
    let down = GTerm(cols: 80, rows: 24, scrollback: 100)
    down.feed(Array("\(e)[?1003h\(e)[?1000h".utf8))
    let replay = GTerm(cols: 80, rows: 24, scrollback: 100)
    replay.feed(down.vt(extras: GX_HANDOVER, unwrap: true, trim: false))
    let downMotion = reportsMotion(down), replayMotion = reportsMotion(replay)
    print("after ?1003h ?1000h a bare motion reports: source \(downMotion), formatter replay \(replayMotion)")
    let sModes = STerm(cols: 80, rows: 24, scrollback: 10).snap(history: false).modes
    let gModes = GTerm(cols: 80, rows: 24, scrollback: 10).snap(history: false).modes
    let unanswered = comparedModes.filter { sModes[$0.name] == nil }.map { "\($0.name)(\($0.n))" }
    let gUnanswered = comparedModes.filter { gModes[$0.name] == nil }.map { "\($0.name)(\($0.n))" }
    print("modes SwiftTerm leaves unanswered in DECRQM: \(unanswered.joined(separator: " "))")
    print("modes libghostty-vt leaves unanswered: \(gUnanswered.joined(separator: " "))")
    writeJSON("signals.json", ["rows": rows, "mouseTrackingGetter": tracking, "oscColorReply": colorReply,
                               "downgradeMotion": ["source": downMotion, "formatterReplay": replayMotion]])
}
