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
        #expect(frames.count >= 2, "Sample should return multiple frames from frame pointer walk (loop executed)")

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

        #expect(frames1.count >= 2, "First sample should return multiple frames from frame pointer walk")
        #expect(frames2.count >= 2, "Second sample should return multiple frames from frame pointer walk")
        #expect(frames3.count >= 2, "Third sample should return multiple frames from frame pointer walk")

        // All samples should contain resolved symbols.
        let allHaveSymbols = [frames1, frames2, frames3].allSatisfy { frames in
            frames.contains { $0.symbol != nil }
        }
        #expect(allHaveSymbols, "All samples should contain at least one resolved symbol")
    }

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
