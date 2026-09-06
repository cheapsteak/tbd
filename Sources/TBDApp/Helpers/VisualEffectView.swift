import SwiftUI

/// AppKit visual-effect bridge so a SwiftUI overlay can pick up a system
/// material (menu, sidebar, etc). Shared by the jump menu panel and the
/// composer's completion overlay — both want the same system-chrome look, one
/// `.behindWindow` (a floating panel), the other `.withinWindow` (an overlay
/// stacked above the transcript's own content, inside the same window).
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
