import Foundation
import Network
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileHealthProbe")

enum ModelProfileHealthProbe {
    /// TCP-connect probe of baseURL's host:port.
    /// - reachable=true if the TCP handshake completes within `timeout`.
    /// - reachable=false on resolution failure, connection refused, or timeout.
    /// Does NOT issue an HTTP request — bare GET would 404 against
    /// api.anthropic.com and most Anthropic-compatible proxies, producing
    /// false-positive warnings. TCP connect is the cheapest no-false-positive
    /// reachability signal.
    static func probe(baseURL: String, timeout: TimeInterval = 3.0) async -> ModelProfileHealthCheckResult {
        guard let url = URL(string: baseURL),
              let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return ModelProfileHealthCheckResult(reachable: false, statusCode: nil, detail: "Invalid URL")
        }

        let port: UInt16
        if let p = url.port, p > 0, p <= 65535 {
            port = UInt16(p)
        } else {
            port = scheme == "https" ? 443 : 80
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return ModelProfileHealthCheckResult(reachable: false, statusCode: nil, detail: "Invalid URL")
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.tbd.daemon.healthprobe")

        let result: ModelProfileHealthCheckResult = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            let resumeOnce: @Sendable (ModelProfileHealthCheckResult) -> Void = { value in
                let shouldResume = resumed.withLock { state -> Bool in
                    if state { return false }
                    state = true
                    return true
                }
                if shouldResume {
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(ModelProfileHealthCheckResult(reachable: true, statusCode: nil, detail: nil))
                case .failed(let error):
                    resumeOnce(ModelProfileHealthCheckResult(reachable: false, statusCode: nil, detail: friendlyDetail(for: error)))
                case .cancelled:
                    // Cancellation flows through resumeOnce; nothing to do here.
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(ModelProfileHealthCheckResult(reachable: false, statusCode: nil, detail: "Timeout"))
            }
        }

        logger.debug("probe \(baseURL, privacy: .public) -> reachable=\(result.reachable, privacy: .public) detail=\(result.detail ?? "nil", privacy: .public)")
        return result
    }
}

private func friendlyDetail(for error: NWError) -> String {
    switch error {
    case .posix(let code):
        switch code {
        case .ECONNREFUSED: return "Connection refused"
        case .EHOSTUNREACH: return "Host unreachable"
        case .ENETUNREACH: return "Network unreachable"
        case .ETIMEDOUT: return "Timeout"
        default: return "Connection failed (\(code.rawValue))"
        }
    case .dns:
        return "Could not resolve host"
    default:
        return error.localizedDescription
    }
}
