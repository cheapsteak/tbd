import AppKit
import ObjectiveC.runtime
import os

private let accessibilityGeometryLogger = Logger(
    subsystem: "com.tbd.app",
    category: "accessibility-geometry"
)

private typealias AccessibilityGeometrySetter = @convention(c) (
    AnyObject,
    Selector,
    AnyObject
) -> Void

/// Prevents malformed geometry from external Accessibility clients from
/// reaching AppKit's `NSWindow` frame setter, which raises an uncaught
/// `NSInternalInconsistencyException` for NaN or infinite coordinates.
@MainActor
enum AccessibilityWindowGeometryGuard {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        installSetter(
            selectorName: "accessibilitySetPositionAttribute:",
            geometryName: "position"
        ) { value in
            let point = value.pointValue
            return point.x.isFinite && point.y.isFinite
        }
        installSetter(
            selectorName: "accessibilitySetSizeAttribute:",
            geometryName: "size"
        ) { value in
            let size = value.sizeValue
            return size.width.isFinite && size.height.isFinite
        }
    }

    private static func installSetter(
        selectorName: String,
        geometryName: String,
        isValid: @escaping (NSValue) -> Bool
    ) {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
            accessibilityGeometryLogger.fault(
                "Could not install Accessibility geometry guard; missing selector \(selectorName, privacy: .public)"
            )
            return
        }

        let originalImplementation = method_getImplementation(method)
        let originalSetter = unsafeBitCast(
            originalImplementation,
            to: AccessibilityGeometrySetter.self
        )
        let replacement: @convention(block) (AnyObject, AnyObject) -> Void = { window, rawValue in
            guard let value = rawValue as? NSValue, !isValid(value) else {
                originalSetter(window, selector, rawValue)
                return
            }

            accessibilityGeometryLogger.fault(
                "Rejected non-finite Accessibility window \(geometryName, privacy: .public) value=\(value.description, privacy: .public) class=\(String(describing: type(of: window)), privacy: .public)"
            )
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
