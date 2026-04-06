import Foundation

public struct ClaudeUsageResult: Equatable, Sendable {
    public var fiveHourPct: Double       // 0.0 ... 1.0 (utilization from the API)
    public var sevenDayPct: Double
    public var fiveHourResetsAt: Date
    public var sevenDayResetsAt: Date

    public init(
        fiveHourPct: Double,
        sevenDayPct: Double,
        fiveHourResetsAt: Date,
        sevenDayResetsAt: Date
    ) {
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
    }
}

public enum ClaudeUsageStatus: Equatable, Sendable {
    case ok(ClaudeUsageResult)
    case http429
    case http401
    case networkError(String)  // human-readable; MUST NOT contain token bytes
    case decodeError(String)
}

public protocol ClaudeUsageFetcher: Sendable {
    func fetchUsage(token: String) async -> ClaudeUsageStatus
}

public struct LiveClaudeUsageFetcher: ClaudeUsageFetcher {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(token: String) async -> ClaudeUsageStatus {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .networkError("invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            return .networkError(urlError.localizedDescription)
        } catch {
            return .networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .networkError("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            do {
                let payload = try decoder.decode(UsagePayload.self, from: data)
                return .ok(ClaudeUsageResult(
                    fiveHourPct: payload.fiveHour.utilization,
                    sevenDayPct: payload.sevenDay.utilization,
                    fiveHourResetsAt: payload.fiveHour.resetsAt,
                    sevenDayResetsAt: payload.sevenDay.resetsAt
                ))
            } catch {
                return .decodeError(error.localizedDescription)
            }
        case 401:
            return .http401
        case 429:
            return .http429
        default:
            return .networkError("HTTP \(http.statusCode)")
        }
    }

    private struct UsagePayload: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resetsAt: Date
        }
        let fiveHour: Window
        let sevenDay: Window
    }
}
