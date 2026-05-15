import Foundation
import Darwin
import os

// MARK: - Frame type

extension MainThreadSampler {
    /// A single stack frame with symbol information.
    struct Frame: Equatable {
        /// Address of the instruction pointer.
        let address: UInt

        /// Resolved symbol name (may be mangled Swift or C symbol). nil if unresolved.
        let symbol: String?

        /// Last path component of the module name (e.g., "TBDApp"). nil if unresolved.
        let module: String?

        /// Offset from the symbol base address. nil if unresolved.
        let offset: UInt?
    }
}

// MARK: - MainThreadSampler

/// Captures the main thread's port at startup and provides sampling of its call stack
/// from any thread. Used by HangWatchdog to collect stacks when a hang is detected.
///
/// Architecture:
/// 1. `captureMainThread()` is called once on the main thread at app startup.
///    It captures `mach_thread_self()` and stores it in a lock.
/// 2. `sample()` can be called from any thread and returns a formatted list of frames
///    from the main thread's stack. Returns empty if no port was captured.
/// 3. `format()` converts frames to a human-readable multi-line string.
enum MainThreadSampler {
    private static let logger = Logger(subsystem: "com.tbd.app", category: "hang-sampler")

    /// Captured port for the main thread. Stored as a `nonisolated` static to avoid
    /// needing @MainActor everywhere (the lock handles synchronization).
    /// The send right is intentionally held for process lifetime; not deallocated.
    nonisolated(unsafe) private static var mainThreadPort: OSAllocatedUnfairLock<mach_port_t> =
        OSAllocatedUnfairLock(initialState: 0)

    // MARK: - Public API

    /// Capture the main thread port. Must be called on the main thread,
    /// ideally during application startup (from `applicationWillFinishLaunching`).
    /// Safe to call multiple times — subsequent calls are idempotent because
    /// `mach_thread_self()` returns the same value.
    @MainActor
    static func captureMainThread() {
        let port = mach_thread_self()
        mainThreadPort.withLock { $0 = port }
        logger.debug("Captured main thread port")
    }

    /// Sample the main thread's call stack. Safe to call from any thread.
    /// Captures state.__pc (actual stuck instruction) as the first frame, followed by
    /// the frame pointer chain. Returns an empty array if the main thread port was never
    /// captured or on non-arm64 architectures.
    static func sample() -> [Frame] {
        #if arch(arm64)
        let port = mainThreadPort.withLock { $0 }
        guard port != 0 else {
            return []
        }

        // Get the thread's register state.
        // Use the typed arm_thread_state64_t struct directly for correct size and field access.
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)

        let krStatus = withUnsafeMutablePointer(to: &state) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { buf in
                thread_get_state(port, ARM_THREAD_STATE64, buf, &count)
            }
        }

        guard krStatus == KERN_SUCCESS else {
            logger.debug("Failed to get thread state: kern_return=\(krStatus, privacy: .public)")
            return []
        }

        // Extract registers from the thread state struct.
        // The arm_thread_state64_t struct has __pc (program counter), __lr (link register),
        // and __fp (frame pointer, x29) fields.
        let initialFP = UInt(state.__fp)
        let pc = UInt(state.__pc)          // actual stuck instruction
        let lr = UInt(state.__lr)          // return address in caller

        // Seed with both PCs; walkFramePointers will start with lr and the natural
        // frame chain walk may naturally deduplicate the pc-lr pair on the first step.
        var pcs: [UInt] = []
        if pc != 0 {
            pcs.append(pc)
        }
        if lr != 0 && lr != pc {
            pcs.append(lr)
        }

        // Continue with the frame pointer chain walk starting from lr.
        let chainPCs = walkLiveStack(initialFP: initialFP, initialPC: lr)
        pcs.append(contentsOf: chainPCs)

        return pcs.map { symbolize($0) }
        #else
        // Non-arm64 architectures: return empty (TBD only runs on arm64).
        return []
        #endif
    }

    /// Format a list of frames as a human-readable multi-line string suitable for logging.
    static func format(_ frames: [Frame]) -> String {
        let lines = frames.enumerated().map { index, frame in
            let symbolPart: String
            if let symbol = frame.symbol, let module = frame.module {
                let demangled = demangle(symbol) ?? symbol
                symbolPart = "\(module)`\(demangled)"
            } else if let symbol = frame.symbol {
                let demangled = demangle(symbol) ?? symbol
                symbolPart = demangled
            } else {
                symbolPart = String(format: "0x%x", frame.address)
            }

            let offsetPart: String
            if let offset = frame.offset {
                offsetPart = " + \(offset)"
            } else {
                offsetPart = ""
            }

            return String(format: "%2d  0x%016x  %@%@", index, frame.address, symbolPart as NSString, offsetPart as NSString)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    // Cache the swift_demangle function to avoid repeated dlopen/dlsym on every symbol.
    private typealias SwiftDemangleFunc = @convention(c) (
        UnsafePointer<CChar>?, Int,
        UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?,
        UInt32
    ) -> UnsafeMutablePointer<CChar>?

    nonisolated(unsafe) private static var demangleFn: SwiftDemangleFunc?
    private static let demangleLock = OSAllocatedUnfairLock<()>(initialState: ())

    /// Load swift_demangle function (lazily, on first call).
    private static func getDemangleFn() -> SwiftDemangleFunc? {
        demangleLock.withLock {
            // Return cached value if already loaded.
            if demangleFn != nil {
                return demangleFn
            }

            guard let h = dlopen("/usr/lib/swift/libswiftDemangle.dylib", RTLD_LAZY) else {
                return nil
            }
            guard let sym = dlsym(h, "swift_demangle") else {
                return nil
            }
            // Cast the symbol address to the function type.
            // Note: We intentionally do NOT dlclose(h) — keep the handle open for process lifetime.
            let fn = unsafeBitCast(sym, to: SwiftDemangleFunc.self)
            demangleFn = fn
            return fn
        }
    }

    /// Pure frame-pointer walk logic, testable with synthetic memory.
    /// Walks the frame pointer chain starting from initialFP and initialPC,
    /// collecting instruction pointers. The readWord closure provides memory reads.
    /// On ARM64, each frame is [FP, LR] at [fp+0, fp+8].
    /// Returns a list of instruction pointers (one per frame).
    static func walkFramePointers(
        initialFP: UInt,
        initialPC: UInt,
        maxFrames: Int = 200,
        readWord: (UInt) -> UInt?
    ) -> [UInt] {
        var pcs: [UInt] = []
        var fp = initialFP

        // First PC is the initial LR.
        if initialPC != 0 {
            pcs.append(initialPC)
        }

        // Walk the chain with strict sanity checks to prevent reading invalid memory.
        var prevFP: UInt = 0
        while pcs.count < maxFrames && fp != 0 && (fp & 0x7) == 0 {
            // Sanity checks:
            // 1. FP must be strictly increasing (prevent loops)
            // 2. FP must be reasonable distance from previous (prevent huge jumps, skip on first iteration)
            // 3. FP should not be in extreme ranges (kernel space)
            guard fp > prevFP && (prevFP == 0 || (fp - prevFP) < 65536) && fp < (1 << 50) else {
                break
            }

            // Read [FP, LR] from the frame pointer chain.
            // FP at [fp+0], LR at [fp+8] on ARM64.
            guard let nextFP = readWord(fp),
                  let lr = readWord(fp + 8) else {
                break
            }

            if lr != 0 {
                pcs.append(lr)
            }

            prevFP = fp
            fp = nextFP
        }

        return pcs
    }

    /// Production frame-pointer walk using direct memory reads.
    /// Wraps walkFramePointers with a closure that reads from the live process memory.
    private static func walkLiveStack(initialFP: UInt, initialPC: UInt) -> [UInt] {
        walkFramePointers(initialFP: initialFP, initialPC: initialPC, maxFrames: 200) { address in
            readUInt64(from: address)
        }
    }

    /// Read a 64-bit unsigned integer from the given address.
    /// Returns nil to indicate read failure. Note: this may still crash on
    /// invalid addresses without proper signal handlers, which is a limitation
    /// of in-process sampling on macOS without ptrace.
    private static func readUInt64(from address: UInt) -> UInt? {
        guard address != 0 else { return nil }

        let ptr = UnsafeRawPointer(bitPattern: address)
        guard let ptr = ptr else { return nil }

        // Attempt to read. This may crash if the address is unmapped.
        // A full solution would use signal handlers or ptrace, but for now
        // we rely on the sanity checks in walkFramePointers to prevent bad reads.
        let value = ptr.assumingMemoryBound(to: UInt64.self).pointee
        return UInt(value)
    }

    /// Symbolize a single address using dladdr and optionally demangle.
    private static func symbolize(_ address: UInt) -> Frame {
        var info = Dl_info()
        let found = dladdr(UnsafeMutableRawPointer(bitPattern: address), &info)

        guard found != 0, let dli_sname = info.dli_sname else {
            return Frame(address: address, symbol: nil, module: nil, offset: nil)
        }

        let symbol = String(cString: dli_sname)
        let module: String? = info.dli_fname.flatMap { fname in
            let fpath = String(cString: fname)
            return URL(fileURLWithPath: fpath).lastPathComponent
        }

        let offset: UInt? = info.dli_saddr.flatMap { baseAddr in
            let base = UInt(bitPattern: baseAddr)
            return address > base ? address - base : nil
        }

        return Frame(address: address, symbol: symbol, module: module, offset: offset)
    }

    /// Demangle a Swift symbol name. Returns the original name if demangling fails
    /// or if libswiftDemangle is unavailable.
    private static func demangle(_ symbol: String) -> String? {
        guard let fn = getDemangleFn() else { return nil }

        // Call swift_demangle with the C string pointer valid only inside the closure.
        // The demangled result is allocated by the C function and must be freed.
        return symbol.withCString { cStr -> String? in
            guard let result = fn(cStr, symbol.utf8.count, nil, nil, 0) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

#if arch(arm64)
// ARM64 thread state type.
private let ARM_THREAD_STATE64: thread_state_flavor_t = 6
#endif
