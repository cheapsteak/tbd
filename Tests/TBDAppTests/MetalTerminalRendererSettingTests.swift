import AppKit
import Foundation
import Metal
import SwiftTerm
import Testing

@testable import TBDApp

/// Storage contract for the experimental Metal renderer flag. Three states,
/// and the one that matters is `nil`: graduation is meant to be a one-line
/// change to `useMetalTerminalRendererDefault` that reaches everyone who never
/// touched the toggle *without* overriding anyone who deliberately turned it
/// off. That only holds if "nobody chose" is distinguishable from an explicit
/// `false`, which a `bool(forKey:)` read would destroy.
@MainActor
@Suite("useMetalTerminalRenderer setting")
struct MetalTerminalRendererSettingTests {
    @Test("ships off — replacing the draw path soaks behind a flag first")
    func defaultsToOff() {
        #expect(AppState.useMetalTerminalRendererDefault == false)
    }

    @Test("an unset key reads the shipped default")
    func unsetReadsShippedDefault() {
        let suiteName = "metal-renderer-unset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: AppState.useMetalTerminalRendererKey) == nil)
        #expect(
            AppState.metalTerminalRendererEnabled(defaults: defaults)
                == AppState.useMetalTerminalRendererDefault)
    }

    @Test("both explicit values round-trip through the read")
    func explicitValuesRoundTrip() {
        let suiteName = "metal-renderer-explicit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppState.useMetalTerminalRendererKey)
        #expect(AppState.metalTerminalRendererEnabled(defaults: defaults))
        defaults.set(false, forKey: AppState.useMetalTerminalRendererKey)
        #expect(!AppState.metalTerminalRendererEnabled(defaults: defaults))
    }

    /// The graduation rehearsal: flip the shipped default to `true` and check
    /// that only the untouched state follows it.
    @Test("an explicit false survives a change to the default constant; nil follows it")
    func explicitFalseSurvivesGraduation() {
        #expect(AppState.metalTerminalRendererEnabled(stored: nil, shippedDefault: true))
        #expect(!AppState.metalTerminalRendererEnabled(stored: false, shippedDefault: true))
        #expect(AppState.metalTerminalRendererEnabled(stored: true, shippedDefault: false))
        #expect(!AppState.metalTerminalRendererEnabled(stored: nil, shippedDefault: false))
    }

    /// `TerminalPanelView.makeNSView` reads `appState.useMetalTerminalRenderer`,
    /// so the gate has to see the AppState's injected defaults rather than
    /// `.standard` — which on this unbundled executable is the developer's real
    /// plist.
    @Test("the AppState instance gate reads its own injected defaults")
    func instanceGateReadsInjectedDefaults() {
        let suiteName = "metal-renderer-appstate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        #expect(state.useMetalTerminalRenderer == AppState.useMetalTerminalRendererDefault)

        defaults.set(true, forKey: AppState.useMetalTerminalRendererKey)
        #expect(state.useMetalTerminalRenderer)

        defaults.set(false, forKey: AppState.useMetalTerminalRendererKey)
        #expect(!state.useMetalTerminalRenderer)
    }
}

/// Both branches of the flag against a live `TBDTerminalView`, plus the hazard
/// the flag introduces: a Metal-backed view renders into a `CAMetalLayer`, and
/// the snapshot path reads the view's *backing store*. A blank snapshot is a
/// silent regression — a blank image still renders as an image — so the
/// non-blank assertion is the only thing standing between the flag and a
/// wordlessly broken sidebar preview.
@MainActor
@Suite("Metal renderer: both branches, and snapshots survive")
struct MetalTerminalRendererViewTests {
    /// Hosts the view in a real off-screen `NSWindow`.
    ///
    /// **Note the ordering differs from production, deliberately.**
    /// `TerminalPanelView.makeNSView` enables Metal on a view that has no
    /// superview and no window yet — SwiftUI attaches it afterwards — which is
    /// the ordering SwiftTerm's own documentation advises against. It works
    /// because `metalBoundWindow` starts nil and `viewDidMoveToWindow` then
    /// rebinds, tearing down the off-window `MTKView`, renderer and glyph atlas
    /// and rebuilding them. So production pays one build-and-discard per
    /// terminal opened, and relies on that rebind path rather than on the
    /// documented ordering.
    ///
    /// This helper windows the view first because that is the *quieter* of the
    /// two paths to test against: it exercises the renderer without also
    /// exercising the rebind. Neither ordering is currently reachable in-process
    /// anyway — see `flagOnEndToEnd` — so this is about not encoding a false
    /// claim in a comment, not about coverage we have.
    private func withView(_ body: (TBDTerminalView) -> Void) {
        // AppearanceSettings must never read or write the developer's real
        // TBDApp.plist (the UserDefaults twin of the ~/tbd fence).
        let suiteName = "TBDAppTests.MetalRenderer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TBDTerminalView(
            frame: frame,
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        defer { view.removeFromSuperview() }
        body(view)
    }

    /// Writes enough text that a correct capture cannot be a single flat
    /// color, whichever renderer produced it.
    private func feedSampleText(_ view: TBDTerminalView) {
        let line = String(repeating: "MW#@8", count: 40)
        view.feed(text: "\(line)\r\n\(line)\r\n\(line)\r\n")
        view.layoutSubtreeIfNeeded()
    }

    /// Whether a capture contains more than one distinct pixel. A blank
    /// snapshot — the Metal failure mode — is uniformly the background color,
    /// so "not all pixels equal" is the discriminating property, and it does
    /// not depend on which renderer drew the glyphs.
    private func hasVaryingPixels(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return false }
        let first = rep.colorAt(x: 0, y: 0)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if rep.colorAt(x: x, y: y) != first { return true }
            }
        }
        return false
    }

    /// The outcome of asking for the GPU path, with the reason kept when it
    /// could not be had.
    private enum MetalOutcome {
        case active
        case unavailable(Error)
    }

    /// Turns Metal on, keeping the thrown `MetalError` instead of swallowing it.
    ///
    /// `applyMetalRendererPreference` deliberately swallows it — that is the
    /// production contract, degrade and carry on. But a test that only sees
    /// `false` cannot tell "this machine has no GPU" from "the shader library
    /// did not resolve", and those want opposite responses.
    private func enableMetal(_ view: TBDTerminalView) -> MetalOutcome {
        do {
            try view.setUseMetal(true)
            return .active
        } catch {
            return .unavailable(error)
        }
    }

    /// Where SwiftTerm probes for `Shaders.metal`, for the failure
    /// text. Knowing *which* paths were searched is the difference between
    /// "this machine has no GPU" and "the resource bundle was not staged next
    /// to the binary" — the second is a packaging bug, not a hardware fact.
    private static func shaderBundleCandidates() -> String {
        let name = "SwiftTerm_SwiftTerm.bundle"
        let probes: [(String, URL?)] = [
            ("Bundle.main.resourceURL", Bundle.main.resourceURL?.appendingPathComponent(name)),
            ("Bundle.main.bundleURL", Bundle.main.bundleURL.appendingPathComponent(name)),
            ("Bundle(for: TBDTerminalView.self).resourceURL",
             Bundle(for: TBDTerminalView.self).resourceURL),
        ]
        return probes.map { label, url in
            guard let url else { return "\(label)=<nil>" }
            let exists = FileManager.default.fileExists(atPath: url.path)
            return "\(label)=\(url.path) [\(exists ? "present" : "absent")]"
        }.joined(separator: ", ")
    }

    /// Carries a diagnosis onto the PRIMARY failure line. `#expect(_:_:)` and
    /// `Issue.record(String)` both demote the text to a trailing `↳` that CI
    /// summaries drop — Tests/CLAUDE.md assertion-hygiene rule 4.
    private struct MetalDiagnosis: Error, CustomStringConvertible {
        let what: String
        let underlying: String
        /// Captured at the call site: `description` is nonisolated, and the
        /// probe that builds this reads main-actor state.
        let bundles: String
        var description: String {
            "\(what): \(underlying); shader-bundle candidates were \(bundles)"
        }
    }

    @Test("flag off: no setUseMetal call, the view stays on CoreGraphics")
    func flagOffLeavesCoreGraphics() {
        withView { view in
            let active = view.applyMetalRendererPreference(enabled: false)
            #expect(!active)
            #expect(!view.isUsingMetalRenderer)
        }
    }

    @Test("flag off: snapshots keep working, unchanged")
    func flagOffSnapshotIsNonBlank() {
        withView { view in
            view.applyMetalRendererPreference(enabled: false)
            feedSampleText(view)
            let shot = view.captureScreenshot()
            #expect(shot != nil)
            #expect(shot.map(hasVaryingPixels) == true)
        }
    }

    /// The capture-time renderer decision, both ways. This is the branch the
    /// end-to-end test below cannot reach in-process, and it is discriminating
    /// on its own: drop the Metal case and the terminal's snapshots go blank
    /// with nothing else going red.
    @Test("a Metal-backed view must not be captured through its backing store")
    func capturePreparationCoversBothRenderers() {
        #expect(
            TBDTerminalView.capturePreparation(isUsingMetalRenderer: true)
                == .dropToCoreGraphicsThenRestore)
        #expect(
            TBDTerminalView.capturePreparation(isUsingMetalRenderer: false)
                == .captureDirectly)
    }

    /// Metal is requested only once the view has a window.
    ///
    /// Enabling it earlier "works" — upstream rebinds on `viewDidMoveToWindow` —
    /// but the rebind builds a second `MTKView`, renderer, glyph atlas and
    /// pipeline set and throws the first away, synchronously, including a
    /// runtime shader compile that nothing caches. Nothing goes red when that
    /// regresses; the terminals just cost twice as much to open, which would
    /// quietly corrupt the very A/B this flag exists to serve.
    @Test("a Metal request waits for the view to have a window")
    func metalActivationWaitsForWindow() {
        #expect(TBDTerminalView.metalActivation(hasWindow: true) == .now)
        #expect(TBDTerminalView.metalActivation(hasWindow: false) == .deferUntilWindowed)
    }

    /// The whole flag-on path, end to end — Metal active, a non-blank capture,
    /// and the view still on Metal afterwards.
    ///
    /// **It does not run here, and the `else` branch is why that is visible
    /// rather than silent.** SwiftTerm resolves `Shaders.metal` against
    /// `Bundle.main`, which in a test run is the toolchain's xctest helper, not
    /// the build directory holding `SwiftTerm_SwiftTerm.bundle` — so
    /// `setUseMetal(true)` throws `shaderSourceMissing` and the GPU path is
    /// unreachable in-process. Rather than skip quietly, the test pins *that
    /// diagnosis*: any other failure reason reds it, and the day the resource
    /// resolves (a SwiftPM layout change, an upstream fix, a packaged runner)
    /// the real assertions start running with no edit here.
    ///
    /// The live-app half of this is not optional — see the PR description.
    @Test("flag on: Metal active, capture non-blank, renderer restored")
    func flagOnEndToEnd() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil, "no Metal device on this machine")
        withView { view in
            switch enableMetal(view) {
            case .active:
                #expect(view.isUsingMetalRenderer)
                // The production wrapper agrees with the raw call: a re-request
                // is a no-op and still reports the GPU path as on.
                #expect(view.applyMetalRendererPreference(enabled: true))

                feedSampleText(view)
                let shot = view.captureScreenshot()
                #expect(shot != nil)
                // A blank result here means the CoreGraphics round trip
                // failed, NOT that the Metal drawable was unavailable: the
                // capture deliberately disables Metal and draws through
                // CoreGraphics, so it never reads a drawable. The
                // `drawMetalFrameNow()` on the way back is the only part that
                // wants one, and it cannot affect the bitmap already captured.
                #expect(
                    shot.map(hasVaryingPixels) == true,
                    "Metal-backed capture came back blank — the CoreGraphics round trip in captureScreenshot() is not holding")
                #expect(
                    view.isUsingMetalRenderer,
                    "the capture must not strand the view on CoreGraphics")

            case .unavailable(let error):
                // Pin the ONE case this is allowed to be unreachable for, by
                // matching the case and not its prose. `MetalError`'s
                // description strings share wording across five of its eleven
                // cases — "shader source" alone also admits
                // `shaderCompilationFailed`, and "Metal library" admits
                // `shaderFunctionMissing` and `shaderLibraryLoadFailed`. A
                // substring allowlist would therefore let a genuinely broken
                // shader or a missing entry point pass as "expected" on the day
                // the resource resolves in-process — which is precisely the day
                // this test is supposed to start doing its job.
                guard case MetalError.shaderSourceMissing = error else {
                    Issue.record(
                        MetalDiagnosis(
                            what: "setUseMetal(true) failed for a reason other than the known "
                                + "test-process shader-resolution gap",
                            underlying: String(describing: error),
                            bundles: Self.shaderBundleCandidates()))
                    return
                }
                // Even unreachable, the capture path must still be sound on the
                // CoreGraphics side it fell back to.
                feedSampleText(view)
                #expect(view.captureScreenshot().map(hasVaryingPixels) == true)
                #expect(!view.isUsingMetalRenderer)
            }
        }
    }
}
