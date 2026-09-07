import AppKit
import Testing

/// Parent suite for every suite that turns on macOS's accessibility bridge.
///
/// `AXEnhancedUserInterface` is **process-global**: it is set on
/// `NSApplication.shared`, so one suite flipping it changes what AppKit does for
/// every other suite running at that moment. All test targets compile into one
/// process and Swift Testing runs suites in parallel across all of them, so a
/// suite that sets the flag and walks away leaves it live under everybody else.
///
/// That is not hypothetical. The composer identifier suite first shipped setting
/// the flag and deliberately leaving it on, and
/// `AccessibilityWindowGeometryGuardTests` — which sets an `NSWindow`'s position
/// and size through the same accessibility setters and then reads
/// `window.frame` back — started failing on CI. With enhanced-UI on, AppKit
/// stops applying an accessibility-driven window move synchronously (it is the
/// mode window managers switch off before they move anything, for exactly this
/// reason), so the forwarded value is simply not in the frame yet when the test
/// looks. The guard is not weakened by that and is not what changed: the flag
/// legitimately changes AppKit's behavior, so the flag must not be left on.
///
/// Two rules follow, and both are needed:
///
/// - **Scope the switch.** Turn the bridge on with `withAccessibilityBridge`,
///   never with a bare set. It records the prior value and restores it in a
///   `defer`, so the flag is never live outside a test body.
/// - **Serialize the bodies.** `.serialized` on this parent orders its tests AND
///   its descendant suites relative to one another, which is what keeps one
///   suite's open scope from overlapping another suite's accessibility read.
///   Per-suite `.serialized` alone only orders tests *within* a suite.
///
/// To add a suite that touches the accessibility bridge, or that reads back
/// AppKit behavior the bridge changes, declare it inside an
/// `extension AccessibilityBridgeSerialized { ... }` so it becomes a nested —
/// and therefore serialized — child of this suite.
@Suite(.serialized) enum AccessibilityBridgeSerialized {}

/// The name of the process-global switch, spelled once.
private let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

/// Run `body` with macOS's accessibility bridge on, and put the switch back the
/// way it was found.
///
/// SwiftUI builds no accessibility tree at all until a client has asked for one:
/// with `AXEnhancedUserInterface` clear, a hosting view's accessibility children
/// are empty no matter what the view declares. A GUI driver sets the flag by
/// connecting; a test has to set it itself, which is what makes an offscreen
/// harness measure the same tree a driver will see.
///
/// The flag is restored on every exit path — see `AccessibilityBridgeSerialized`
/// for what leaving it on did.
@MainActor
func withAccessibilityBridge<T>(_ body: () async throws -> T) async rethrows -> T {
    let previous = accessibilityBridgeIsEnabled()
    setAccessibilityBridge(true)
    defer { setAccessibilityBridge(previous) }
    return try await body()
}

/// Whether the bridge is on right now, read back through the same accessibility
/// channel that sets it. Answers `false` when the attribute cannot be read,
/// which is the value a test process starts with and therefore the right one to
/// restore to.
@MainActor
func accessibilityBridgeIsEnabled() -> Bool {
    let app = NSApplication.shared
    let selector = Selector(("accessibilityAttributeValue:"))
    guard app.responds(to: selector),
          let result = app.perform(selector, with: axEnhancedUserInterfaceAttribute),
          let number = result.takeUnretainedValue() as? NSNumber
    else { return false }
    return number.boolValue
}

@MainActor
private func setAccessibilityBridge(_ enabled: Bool) {
    let app = NSApplication.shared
    let selector = Selector(("accessibilitySetValue:forAttribute:"))
    guard app.responds(to: selector) else { return }
    _ = app.perform(
        selector, with: NSNumber(value: enabled), with: axEnhancedUserInterfaceAttribute)
}

extension AccessibilityBridgeSerialized {
    /// The switch itself: on inside the scope, and back to what it was after —
    /// the invariant the geometry guard's failure was the symptom of.
    @MainActor
    @Suite("accessibility bridge switch")
    struct AccessibilityBridgeScopeTests {
        @Test func theBridgeIsOnInsideTheScopeAndRestoredAfterIt() async {
            _ = NSApplication.shared
            let before = accessibilityBridgeIsEnabled()
            await withAccessibilityBridge {
                #expect(accessibilityBridgeIsEnabled(), "the scope did not turn the bridge on")
            }
            #expect(
                accessibilityBridgeIsEnabled() == before,
                "the scope left the process-global bridge switch changed")
        }
    }
}
