import Foundation

/// Every path the model proxy and its tee own. All derive from
/// `TBDConstants.configDir(environment:)`, so `TBD_HOME` — and therefore the
/// test fence — moves them together, and a test gets its own proxy with no
/// injection seam added for the purpose.
extension TBDConstants {
    /// Rendezvous directory for the proxy: `~/tbd/proxy`. Honors TBD_HOME.
    ///
    /// Holds `proxy.lock`, `proxy.pid`, `proxy.log`, and `routes/`.
    public static func modelProxyDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDir(environment: environment).appendingPathComponent("proxy")
    }

    /// One file per live route: `~/tbd/proxy/routes`. Honors TBD_HOME.
    public static func modelProxyRoutesDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        modelProxyDir(environment: environment).appendingPathComponent("routes")
    }

    /// The `flock` the daemon takes before any bind, so two daemons on one TBD
    /// home cannot both mint a proxy: `~/tbd/proxy/proxy.lock`.
    public static func modelProxyLockPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        modelProxyDir(environment: environment).appendingPathComponent("proxy.lock").path
    }

    /// `~/tbd/proxy/proxy.pid`.
    public static func modelProxyPIDPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        modelProxyDir(environment: environment).appendingPathComponent("proxy.pid").path
    }

    /// `~/tbd/proxy/proxy.log`.
    public static func modelProxyLogPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        modelProxyDir(environment: environment).appendingPathComponent("proxy.log").path
    }

    /// The route file for one token: `~/tbd/proxy/routes/<token>.json`.
    ///
    /// The token composes a path, so a caller holding a token that came off the
    /// wire must pass `ModelProxyRoute.isValidToken` first; this helper does no
    /// validation of its own.
    public static func modelProxyRoutePath(
        token: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        modelProxyRoutesDir(environment: environment)
            .appendingPathComponent(modelProxyRouteFileName(token: token)).path
    }

    /// The bare file name a route gets under `routes/`.
    ///
    /// Split out from the path helper because the proxy holds its routes
    /// directory as an injected `URL` rather than deriving it from
    /// `TBD_HOME` — it must compose the same name against a different parent,
    /// and a second spelling of `<token>.json` is a route file the daemon
    /// writes and the proxy never unlinks.
    public static func modelProxyRouteFileName(token: String) -> String {
        "\(token).json"
    }

    /// One JSONL stream file per terminal: `~/tbd/streams`. Honors TBD_HOME.
    ///
    /// A sibling of the proxy directory rather than a child of it: the proxy
    /// writes these files but the app reads them, and they outlive any one
    /// proxy image.
    public static func streamsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDir(environment: environment).appendingPathComponent("streams")
    }

    /// A terminal's stream file: `~/tbd/streams/<terminal-id>.jsonl`, mode 0600.
    public static func streamFilePath(
        terminalID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        streamsDir(environment: environment)
            .appendingPathComponent(streamFileName(terminalID: terminalID)).path
    }

    /// The bare file name a terminal's stream file gets under `streams/`.
    ///
    /// Same reason as `modelProxyRouteFileName`: the proxy composes it against
    /// an injected streams directory, and the tee that writes the file and the
    /// route retirement that unlinks it must agree on one spelling.
    public static func streamFileName(terminalID: UUID) -> String {
        "\(terminalID.uuidString).jsonl"
    }
}
