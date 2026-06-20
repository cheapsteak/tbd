import SwiftUI

/// Closure injected by a transcript pane so an `AgentCard` can push a subagent
/// thread onto that pane's drill path — replacing the overlay for subagent
/// cards. Takes the Task toolCall id; the pane captures its own path storage.
struct NavigateToThreadKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    var navigateToThread: (@MainActor (String) -> Void)? {
        get { self[NavigateToThreadKey.self] }
        set { self[NavigateToThreadKey.self] = newValue }
    }
}
