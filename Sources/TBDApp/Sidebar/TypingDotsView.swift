import AppKit
import SwiftUI

/// Layer-backed dancing-dots ("typing…") indicator. The pulse is driven by
/// `CAKeyframeAnimation`s committed once to the render server, so it costs no
/// per-frame main-thread or SwiftUI work — unlike the `ProgressView` spinner
/// it replaces (#266). Animations are paused while the window is occluded.
final class TypingDotsNSView: NSView {
    private static let dotDiameter: CGFloat = 4
    private static let dotSpacing: CGFloat = 3
    private static let pulseKey = "typingPulse"
    private let dotLayers: [CALayer]
    // nonisolated(unsafe): Swift 6 deinit is nonisolated; NSView deinit
    // always runs on the main thread in practice, so this is safe.
    nonisolated(unsafe) private var occlusionObserver: (any NSObjectProtocol)?

    init(dotColor: NSColor) {
        self.dotLayers = (0..<3).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        for (index, dot) in dotLayers.enumerated() {
            dot.backgroundColor = dotColor.cgColor
            dot.cornerRadius = Self.dotDiameter / 2
            dot.frame = CGRect(
                x: CGFloat(index) * (Self.dotDiameter + Self.dotSpacing),
                y: 0,
                width: Self.dotDiameter,
                height: Self.dotDiameter
            )
            dot.opacity = 0.3

            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1.0, 0.3]
            pulse.keyTimes = [0, 0.5, 1]
            pulse.duration = 1.2
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            dot.add(pulse, forKey: Self.pulseKey)

            layer?.addSublayer(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let count = dotLayers.count
        guard count > 0 else { return }
        let contentWidth = CGFloat(count) * Self.dotDiameter
            + CGFloat(count - 1) * Self.dotSpacing
        let startX = ((bounds.width - contentWidth) / 2).rounded()
        let dotY = ((bounds.height - Self.dotDiameter) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dotLayers.enumerated() {
            dot.frame = CGRect(
                x: startX + CGFloat(index) * (Self.dotDiameter + Self.dotSpacing),
                y: dotY,
                width: Self.dotDiameter,
                height: Self.dotDiameter
            )
        }
        CATransaction.commit()
    }

    override var intrinsicContentSize: NSSize {
        let width = CGFloat(dotLayers.count) * Self.dotDiameter
            + CGFloat(dotLayers.count - 1) * Self.dotSpacing
        return NSSize(width: width, height: Self.dotDiameter)
    }

    func updateColor(_ color: NSColor) {
        for dot in dotLayers { dot.backgroundColor = color.cgColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else {
            setPaused(true)
            return
        }
        setPaused(!window.occlusionState.contains(.visible))
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees this runs on the main thread.
            // Avoid capturing note (non-Sendable NSWindow object); read
            // self.window directly inside the main-actor-isolated closure.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setPaused(!(self.window?.occlusionState.contains(.visible) ?? false))
            }
        }
    }

    deinit {
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Freeze/thaw the render-server animation without removing it: a paused
    /// layer does zero render-server work.
    private func setPaused(_ paused: Bool) {
        guard let layer else { return }
        if paused {
            guard layer.speed != 0 else { return }
            let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
        } else {
            guard layer.speed == 0 else { return }
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            layer.beginTime = timeSincePause
        }
    }
}

/// SwiftUI wrapper for `TypingDotsNSView`.
struct TypingDotsView: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> TypingDotsNSView {
        TypingDotsNSView(dotColor: NSColor(color))
    }

    func updateNSView(_ nsView: TypingDotsNSView, context: Context) {
        nsView.updateColor(NSColor(color))
    }
}
