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

        // Sample should not crash.
        let frames = MainThreadSampler.sample()
        #expect(frames.count >= 0)
    }

    @Test @MainActor func sampleCanBeCalledMultipleTimes() {
        // Calling sample multiple times should not crash.
        MainThreadSampler.captureMainThread()

        let frames1 = MainThreadSampler.sample()
        let frames2 = MainThreadSampler.sample()

        #expect(frames1.count >= 0)
        #expect(frames2.count >= 0)
    }

    @Test func formatFramesYieldsMultilineString() {
        // Test that format() produces a readable multi-line output.
        let frames = [
            MainThreadSampler.Frame(
                address: 0x100001234,
                symbol: "main",
                module: "TBDApp",
                offset: 10
            ),
            MainThreadSampler.Frame(
                address: 0x100005678,
                symbol: "foo",
                module: "TBDApp",
                offset: 100
            ),
        ]

        let formatted = MainThreadSampler.format(frames)
        #expect(formatted.contains("main"))
        #expect(formatted.contains("foo"))
        #expect(formatted.contains("\n"))  // Multi-line
        // Should not contain mangled names or hex only
        #expect(!formatted.contains("_ZN"))
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
