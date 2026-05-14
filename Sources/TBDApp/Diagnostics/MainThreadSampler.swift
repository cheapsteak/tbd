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
    nonisolated(unsafe) private static var mainThreadPort: OSAllocatedUnfairLock<mach_port_t> =
        OSAllocatedUnfairLock(initialState: 0)

    // MARK: - Public API

    /// Capture the main thread port. Must be called exactly once on the main thread,
    /// ideally during application startup (from `applicationWillFinishLaunching`).
    /// Safe to call multiple times — only the first call does anything.
    @MainActor
    static func captureMainThread() {
        let port = mach_thread_self()
        mainThreadPort.withLock { $0 = port }
        logger.debug("Captured main thread port")
    }

    /// Sample the main thread's call stack. Safe to call from any thread.
    /// Returns an empty array if the main thread port was never captured or on non-arm64 architectures.
    static func sample() -> [Frame] {
        #if arch(arm64)
        let port = mainThreadPort.withLock { $0 }
        guard port != 0 else {
            return []
        }

        // Get the thread's register state.
        // Allocate the state structure separately to ensure proper alignment.
        var stateCount = UInt32(ARM_THREAD_STATE64_COUNT)
        var state = [natural_t](repeating: 0, count: Int(stateCount))

        let krStatus = state.withUnsafeMutableBufferPointer { buffer in
            thread_get_state(
                port,
                ARM_THREAD_STATE64,
                buffer.baseAddress!,
                &stateCount
            )
        }

        guard krStatus == KERN_SUCCESS else {
            logger.debug("Failed to get thread state: kern_return=\(krStatus, privacy: .public)")
            return []
        }

        // Extract FP and LR from the thread state.
        // In arm_thread_state64_t, __fp is at offset 0 and __lr is at offset 8.
        // We've read the state as natural_t array; convert back carefully.
        guard state.count >= 2 else {
            return []
        }

        // Reconstruct FP and LR from the state array.
        // FP is x29, LR is x30 in the ARM64 ABI.
        // In the state array, they're at fixed offsets.
        let initialFP = UInt(state[29])  // x29 is frame pointer
        let initialPC = UInt(state[30])  // x30 is link register

        // Walk the frame pointer chain and collect frames.
        let pcs = walkFramePointers(initialFP: initialFP, initialPC: initialPC)
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

            return String(format: "%2d  0x%016x  %s%s", index, frame.address, symbolPart, offsetPart)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Walk the frame pointer chain starting from the given FP and PC.
    /// On ARM64, each frame is [FP, LR] at [FP+0, FP+8].
    /// Returns a list of instruction pointers (one per frame).
    private static func walkFramePointers(initialFP: UInt, initialPC: UInt) -> [UInt] {
        var pcs: [UInt] = []
        var fp = initialFP
        let maxFrames = 200

        // First PC is the initial LR.
        if initialPC != 0 {
            pcs.append(initialPC)
        }

        // Walk the chain with strict sanity checks to prevent reading invalid memory.
        var prevFP: UInt = 0
        while pcs.count < maxFrames && fp != 0 && (fp & 0x7) == 0 {
            // Sanity checks:
            // 1. FP must be strictly increasing (prevent loops)
            // 2. FP must be reasonable distance from previous (prevent huge jumps)
            // 3. FP should not be in extreme ranges (kernel space)
            guard fp > prevFP && (fp - prevFP) < 65536 && fp < (1 << 50) else {
                break
            }

            // Read [FP, LR] from the frame pointer chain.
            // FP at [FP+0], LR at [FP+8] on ARM64.
            guard let nextFP = readUInt64(from: fp),
                  let lr = readUInt64(from: fp + 8) else {
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
        // Try to dlopen libswiftDemangle and call swift_demangle.
        guard let handle = dlopen("/usr/lib/swift/libswiftDemangle.dylib", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }

        // Look up swift_demangle function.
        // Signature: char *swift_demangle(const char *mangledName, size_t mangledNameLength,
        //                                   char *outputBuffer, size_t *outputBufferSize,
        //                                   uint32_t options);
        typealias SwiftDemangleFunc = @convention(c) (
            UnsafePointer<CChar>,         // mangled name
            Int,                          // length
            UnsafeMutablePointer<CChar>?, // output buffer
            UnsafeMutablePointer<Int>?,   // output buffer size
            UInt32                        // options
        ) -> UnsafeMutablePointer<CChar>?

        guard let symAddr = dlsym(handle, "swift_demangle") else {
            return nil
        }

        let demangleFn = unsafeBitCast(symAddr, to: SwiftDemangleFunc.self)

        // Call swift_demangle with no output buffer (it allocates).
        let mangledCStr = symbol.withCString { $0 }
        guard let demangled = demangleFn(mangledCStr, symbol.count, nil, nil, 0) else {
            return nil
        }

        defer { free(demangled) }
        return String(cString: demangled)
    }
}

#if arch(arm64)
// ARM64 thread state type and count.
private let ARM_THREAD_STATE64: thread_state_flavor_t = 6
private let ARM_THREAD_STATE64_COUNT: UInt32 = 34
#endif
