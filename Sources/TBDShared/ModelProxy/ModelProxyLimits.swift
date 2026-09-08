import Foundation

/// Bounds two sides of the model-proxy feature have to agree on, stated once.
///
/// A limit belongs here when the proxy and the app each reason about it and
/// their answers must match. Anything only one side reads stays where it is
/// read.
public enum ModelProxyLimits {

    /// The longest a legitimate stream can still be in flight.
    ///
    /// Two readers, one number. The proxy sleeps on it: a retired proxy closes
    /// its listener and then waits this long for the streams already running on
    /// it, after which it exits whether they finished or not
    /// (`ControlEndpoints`). The app measures against it: a provisional row
    /// whose stream has produced no line for this long is one nothing is coming
    /// back for, so the row is withdrawn
    /// (`ProvisionalRowComposer.silentStreamRetireAfter`).
    ///
    /// The app's rule is only sound while the two are equal — a shorter window
    /// would withdraw a row whose proxy is still legitimately draining, and a
    /// longer one would leave a row on screen after every proxy that could
    /// still feed it has exited. So they are one constant rather than two
    /// literals that happen to agree.
    public static let drainCap: Duration = .seconds(600)
}
