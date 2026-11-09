import Foundation

extension Process {
    /// Starts the process, and drops `terminationHandler` if the launch throws.
    ///
    /// Foundation keeps a process's `terminationHandler` alive until the child
    /// it launched has exited. A process that never launches (`run()` throws, or
    /// the caller gives up before calling it) has no exit to release it, so the
    /// handler and everything it captured stay alive for the life of the
    /// program. A handler that captured a `Pipe` therefore keeps both of its
    /// descriptors open, four per call when it captured stdout and stderr, until
    /// the daemon runs out of descriptors. Clearing the handler on the failure
    /// path releases it, and the pipes close when they deallocate.
    ///
    /// Use this wherever the handler captures a pipe or anything else worth
    /// freeing. A caller that can stop before it launches must also assign the
    /// handler only on the path that does launch.
    public func runDisarmingHandlerOnFailure() throws {
        do {
            try run()
        } catch {
            terminationHandler = nil
            throw error
        }
    }
}
