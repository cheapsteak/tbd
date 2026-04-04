import AppKit

/// Monitors local key events for the conductor toggle hotkey (Opt+.).
/// Only fires when TBD is the active app.
final class ConductorHotkeyMonitor {
    private var monitor: Any?

    /// Install the local event monitor. Call once at app startup.
    /// The `toggle` closure is called on the main thread when the hotkey fires.
    func install(toggle: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Opt+. : modifiers = option, keyCode 47 = period
            if event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               event.keyCode == 47 {
                toggle()
                return nil  // consume the event
            }
            return event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        uninstall()
    }
}
