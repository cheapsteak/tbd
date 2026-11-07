// ghosttyview: frame and memory numbers for --stats. Frame timing is on the main thread only.
import Darwin
import Foundation

/// Touched only from the main thread; the renderer is not annotated, so this is not either.
final class Stats {
    static let shared = Stats()

    private var buildUs: [UInt32] = []
    private var encodeUs: [UInt32] = []
    private var waitUs: [UInt32] = []
    private var busyNs: UInt64 = 0
    private var ticks = 0
    private var dropped = 0
    private var nilDrawables = 0
    private var lastTick: [ObjectIdentifier: CFTimeInterval] = [:]
    private var peakFootprint: UInt64 = 0
    private let started = DispatchTime.now().uptimeNanoseconds
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    /// Forget everything so far, so start-up does not count towards a steady-state number.
    func reset() {
        buildUs.removeAll(); encodeUs.removeAll(); waitUs.removeAll()
        busyNs = 0; ticks = 0; dropped = 0; nilDrawables = 0
        lastTick.removeAll()
        windowStart = DispatchTime.now().uptimeNanoseconds
    }

    func noteFrame(buildNs: UInt64, encodeNs: UInt64, waitNs: UInt64) {
        buildUs.append(UInt32(clamping: buildNs / 1000))
        encodeUs.append(UInt32(clamping: encodeNs / 1000))
        waitUs.append(UInt32(clamping: waitNs / 1000))
        busyNs += buildNs + encodeNs + waitNs
    }

    func noteNilDrawable() { nilDrawables += 1 }

    /// A dropped frame: while a link is running, a gap over 1.5 periods counts the periods it
    /// missed. A gap over 10 periods is the link having been parked, so it counts for nothing.
    func noteTick(view: ObjectIdentifier, time: CFTimeInterval, duration: CFTimeInterval, running: Bool) {
        ticks += 1
        defer { lastTick[view] = time }
        guard running, duration > 0, let last = lastTick[view] else { return }
        let periods = (time - last) / duration
        if periods > 1.5, periods < 10 { dropped += Int(periods.rounded()) - 1 }
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func sampleFootprint() { peakFootprint = max(peakFootprint, Stats.physFootprint()) }

    private func summary(_ values: [UInt32]) -> [String: Double] {
        guard !values.isEmpty else { return ["median": 0, "p99": 0, "max": 0] }
        let sorted = values.sorted()
        func ms(_ us: UInt32) -> Double { (Double(us) / 10).rounded() / 100 }
        return ["median": ms(sorted[sorted.count / 2]),
                "p99": ms(sorted[min(sorted.count - 1, sorted.count * 99 / 100)]),
                "max": ms(sorted[sorted.count - 1])]
    }

    func write(to path: String, panes: Int, extra: [String: Any]) {
        sampleFootprint()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - windowStart) / 1e9
        var json: [String: Any] = [
            "panes": panes,
            "seconds": (seconds * 100).rounded() / 100,
            "frames": buildUs.count,
            "framesPerSecond": seconds > 0 ? (Double(buildUs.count) / seconds).rounded() : 0,
            "linkTicks": ticks,
            "frameBuildMs": summary(buildUs),
            "encodeMs": summary(encodeUs),
            "waitMs": summary(waitUs),
            "mainThreadRenderBusyPercent": seconds > 0 ? (Double(busyNs) / 1e9 / seconds * 1000).rounded() / 10 : 0,
            "droppedFrames": dropped,
            "nilDrawables": nilDrawables,
            "physFootprintMB": (Double(Stats.physFootprint()) / 1_048_576 * 10).rounded() / 10,
            "physFootprintPeakMB": (Double(peakFootprint) / 1_048_576 * 10).rounded() / 10,
        ]
        json.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
