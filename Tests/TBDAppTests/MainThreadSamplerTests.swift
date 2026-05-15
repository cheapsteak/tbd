import Foundation
import Testing
import Darwin

@testable import TBDApp

@Suite("MainThreadSampler")
struct MainThreadSamplerTests {
    // MARK: - Tests

    @Test @MainActor func captureAndSampleDoesNotCrash() {
        // Capture the main thread.
        MainThreadSampler.captureMainThread()

        // Sample should not crash and should return non-empty frames with symbols.
        let frames = MainThreadSampler.sample()
        // `>= 1` is intentional. Runtime stack depth in the test harness varies between
        // dev and CI; the deterministic walker tests below are what catch regressions
        // in the FP-chain walk logic. This test is the integration check that
        // sample() returns non-crashing output with at least the initial PC.
        #expect(frames.count >= 1, "Sample should return at least the initial frame")

        // At least one frame should have a symbol (not all unresolved).
        let hasSymbol = frames.contains { $0.symbol != nil }
        #expect(hasSymbol, "At least one frame should have a resolved symbol")
    }

    @Test @MainActor func sampleCanBeCalledMultipleTimes() {
        // Calling sample multiple times should not crash and return consistent results.
        MainThreadSampler.captureMainThread()

        let frames1 = MainThreadSampler.sample()
        let frames2 = MainThreadSampler.sample()
        let frames3 = MainThreadSampler.sample()

        // `>= 1` is intentional. Runtime stack depth in the test harness varies between
        // dev and CI; the deterministic walker tests below are what catch regressions
        // in the FP-chain walk logic. This test is the integration check that
        // sample() returns non-crashing output with at least the initial PC.
        #expect(frames1.count >= 1, "First sample should return at least the initial frame")
        #expect(frames2.count >= 1, "Second sample should return at least the initial frame")
        #expect(frames3.count >= 1, "Third sample should return at least the initial frame")

        // All samples should contain resolved symbols.
        let allHaveSymbols = [frames1, frames2, frames3].allSatisfy { frames in
            frames.contains { $0.symbol != nil }
        }
        #expect(allHaveSymbols, "All samples should contain at least one resolved symbol")
    }

    // MARK: - Deterministic walker tests (synthetic in-memory stacks)

    @Test func walkerCapturesExpectedDepthFromSyntheticStack() {
        // Build a synthetic frame-pointer chain:
        // Frame 0 at addr 0x1000 → saved FP = 0x2000, saved LR = 0xAAA
        // Frame 1 at addr 0x2000 → saved FP = 0x3000, saved LR = 0xBBB
        // Frame 2 at addr 0x3000 → saved FP = 0,      saved LR = 0xCCC  (sentinel ends walk)
        let memory: [UInt: UInt] = [
            0x1000: 0x2000, 0x1008: 0xAAA,
            0x2000: 0x3000, 0x2008: 0xBBB,
            0x3000: 0x0000, 0x3008: 0xCCC,
        ]
        let pcs = MainThreadSampler.walkFramePointers(
            initialFP: 0x1000,
            initialPC: 0xFFF,   // initial PC always appears as frame[0]
            maxFrames: 10,
            readWord: { memory[$0] }
        )
        // Expect 4 frames: initialPC, plus saved LR of frames 0, 1, 2
        #expect(pcs == [0xFFF, 0xAAA, 0xBBB, 0xCCC])
    }

    @Test func walkerEntersLoopOnFirstIterationWithLargeFP() {
        // Real ARM64 FPs are ~6 GB. The fp - prevFP guard must not fire on the first iteration.
        // This test verifies the specific bug that was previously reported:
        // the loop body never executes if the first FP is large enough to fail (fp - prevFP) < 65536
        // when prevFP starts at 0 — except the guard is `prevFP == 0 || (fp - prevFP) < 65536`,
        // so the first iteration must enter because prevFP == 0.
        let highFP: UInt = 0x16FFFE000   // ~6 GB
        let memory: [UInt: UInt] = [
            highFP: 0, highFP + 8: 0xDEAD,
        ]
        let pcs = MainThreadSampler.walkFramePointers(
            initialFP: highFP,
            initialPC: 0xBEEF,
            maxFrames: 10,
            readWord: { memory[$0] }
        )
        // Should capture initialPC and the saved LR from the first frame.
        #expect(pcs == [0xBEEF, 0xDEAD])
    }

    @Test func walkerStopsAtMaxFrames() {
        // Build a chain longer than maxFrames to verify the limit is enforced.
        var memory: [UInt: UInt] = [:]
        var fp: UInt = 0x1000
        memory[0x1000] = 0x2000
        memory[0x1008] = 0xAAA
        for i in 1..<10 {
            let nextFP = 0x1000 + UInt(i + 1) * 0x1000
            memory[fp + 0x1000] = nextFP
            memory[fp + 0x1008] = 0x0100 + UInt(i)
            fp = nextFP
        }
        // Terminate the chain
        memory[fp] = 0

        let pcs = MainThreadSampler.walkFramePointers(
            initialFP: 0x1000,
            initialPC: 0xFFF,
            maxFrames: 3,   // Limit to 3 frames
            readWord: { memory[$0] }
        )
        // Should have exactly 3 frames: initialPC + 2 from the chain
        #expect(pcs.count == 3)
        #expect(pcs[0] == 0xFFF)
    }

    @Test func walkerStopsOnUnalignedFP() {
        // FP must be 8-byte aligned. Test that unaligned FP terminates the walk.
        let memory: [UInt: UInt] = [
            0x1001: 0x2000, 0x1009: 0xAAA,   // Unaligned addresses
        ]
        let pcs = MainThreadSampler.walkFramePointers(
            initialFP: 0x1001,   // Unaligned FP
            initialPC: 0xFFF,
            maxFrames: 10,
            readWord: { memory[$0] }
        )
        // Loop should never enter because (fp & 0x7) != 0
        #expect(pcs == [0xFFF])
    }

    @Test func walkerStopsOnDecreasingFP() {
        // Frame pointers must be strictly increasing. Test that a decreasing FP stops the walk.
        // Build a chain: Frame 0 at 0x2000 → FP=0x1000 (decreasing), LR=0xAAA
        // The loop enters on the first iteration with fp=0x2000, reads frame 0,
        // appends its LR (0xAAA), then on the next iteration detects fp < prevFP and stops.
        let memory: [UInt: UInt] = [
            0x2000: 0x1000,   // Next FP is less than current FP
            0x2008: 0xAAA,
        ]
        let pcs = MainThreadSampler.walkFramePointers(
            initialFP: 0x2000,
            initialPC: 0xFFF,
            maxFrames: 10,
            readWord: { memory[$0] }
        )
        // Loop enters with fp=0x2000, reads frame 0, appends 0xAAA. Then on the next
        // iteration, fp becomes 0x1000 which is < prevFP (0x2000), so we break.
        #expect(pcs == [0xFFF, 0xAAA])
    }

    // MARK: - Symbol and formatting tests

    @Test func formatFramesYieldsMultilineString() {
        // Test that format() produces a readable multi-line output.
        // The demangling infrastructure is tested indirectly by the sample() tests.
        let frames = [
            MainThreadSampler.Frame(
                address: 0x100001234,
                symbol: "main",
                module: "TBDApp",
                offset: 10
            ),
            MainThreadSampler.Frame(
                address: 0x100005678,
                symbol: "_ZN4test3fooEv",  // C++ mangled symbol (unlikely to demangle)
                module: "TBDApp",
                offset: 100
            ),
            MainThreadSampler.Frame(
                address: 0x100009abc,
                symbol: nil,  // Unresolved symbol
                module: nil,
                offset: nil
            ),
        ]

        let formatted = MainThreadSampler.format(frames)
        #expect(formatted.contains("main"), "Unmangled symbol should appear as-is")
        #expect(formatted.contains("\n"), "Output should be multi-line")
        #expect(formatted.contains("1234"), "First address digits should appear in hex")
        #expect(formatted.contains("5678"), "Second address digits should appear in hex")
        #expect(formatted.contains("9abc"), "Unresolved address digits should appear in hex")
    }

    @Test func frameStructEquality() {
        let f1 = MainThreadSampler.Frame(
            address: 0x100001234,
            symbol: "foo",
            module: "TBDApp",
            offset: 10
        )
        let f2 = MainThreadSampler.Frame(
            address: 0x100001234,
            symbol: "foo",
            module: "TBDApp",
            offset: 10
        )
        let f3 = MainThreadSampler.Frame(
            address: 0x100001235,
            symbol: "foo",
            module: "TBDApp",
            offset: 10
        )

        #expect(f1 == f2)
        #expect(f1 != f3)
    }
}
