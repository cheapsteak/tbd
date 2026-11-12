import Foundation

/// Whether one profile can run a Fable model right now.
///
/// Fable needs usage credits, a meter separate from the 5-hour and weekly
/// windows, so a profile with plenty of window headroom can still be unable to
/// run it. Nothing in the usage snapshot says so; the only signals are a probe
/// (`FableProbeClassifier.classify(resultJSON:now:)`) and the line a session
/// shows when it hits the wall (`classify(screenText:now:)`).
///
/// The state is **fail-closed toward `unknown`**: `available` is only ever
/// produced from a probe that returned a result and said it was not an error,
/// and `out` only from the credits signal itself. Every other outcome (a usage
/// window limit, a network failure, a malformed reply) is `unknown`, which
/// balancing treats as "not known to be out". See
/// `docs/fable-availability.md`.
public struct FableAvailability: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case available
        case out
        case unknown
    }

    public enum Source: String, Codable, Sendable, Equatable {
        /// A headless `claude -p` probe run under the profile.
        case probe
        /// A live session on the profile showed the out-of-credits line.
        case session
    }

    public var state: State
    /// The `api_error` code behind the state (for example
    /// `model_requires_usage_credits`), or a short TBD-chosen tag for a
    /// failure with no code. Never free text from the reply: it is printed.
    public var reason: String?
    public var checkedAt: Date
    public var source: Source

    public init(state: State, reason: String? = nil, checkedAt: Date, source: Source) {
        self.state = state
        self.reason = reason
        self.checkedAt = checkedAt
        self.source = source
    }

    /// How long a reading is trusted before a spawn or a forced check must
    /// probe again.
    public static let outTTL: TimeInterval = 30 * 60
    public static let availableTTL: TimeInterval = 6 * 60 * 60
    public static let unknownTTL: TimeInterval = 10 * 60

    public var ttl: TimeInterval {
        switch state {
        case .out: return Self.outTTL
        case .available: return Self.availableTTL
        case .unknown: return Self.unknownTTL
        }
    }

    public func age(now: Date) -> TimeInterval { now.timeIntervalSince(checkedAt) }

    /// Whether the reading is still within its TTL. A reading stamped in the
    /// future (clock change) is not fresh: it cannot be trusted either way.
    public func isFresh(now: Date) -> Bool {
        let age = age(now: now)
        return age >= 0 && age < ttl
    }

    /// True only for a reading that says out AND is still fresh: the one case
    /// balancing refuses a profile for.
    public func isOut(now: Date) -> Bool { state == .out && isFresh(now: now) }
}

/// Which model ids and aliases ask for Fable.
public enum FableModel {
    /// The model id a probe runs (`claude -p --model`).
    public static let probeModelID = "claude-fable-5-2"

    /// Whether a requested model (an alias such as `fable`, or an exact id
    /// such as `claude-fable-5-2`) is a Fable model. nil and blank are not.
    public static func isFable(_ model: String?) -> Bool {
        guard let model else { return false }
        return model.lowercased().contains("fable")
    }
}

/// Pure classification of what a Fable probe or a session said.
public enum FableProbeClassifier {
    /// The `api_error` code Claude Code reports when an account has no Fable
    /// credits.
    public static let creditsErrorCode = "model_requires_usage_credits"
    private static let creditsPhrase = "out of usage credits"

    /// Classify the one JSON result object `claude -p --output-format json`
    /// prints.
    ///
    /// - `is_error` exactly `false` with a non-empty string `result` and no
    ///   `api_error` → `available`.
    /// - `api_error == model_requires_usage_credits`, or no `api_error` and a
    ///   `result` that says "out of usage credits" → `out`.
    /// - Anything else, including `usage_limit_reached` (a window limit, not a
    ///   credits problem), network and auth errors, and every malformed or
    ///   mistyped reply → `unknown`.
    public static func classify(resultJSON: Data, now: Date) -> FableAvailability {
        func unknown(_ reason: String) -> FableAvailability {
            FableAvailability(state: .unknown, reason: reason, checkedAt: now, source: .probe)
        }
        guard !resultJSON.isEmpty else { return unknown("empty_output") }
        guard let parsed = try? JSONSerialization.jsonObject(with: resultJSON),
              let object = parsed as? [String: Any]
        else { return unknown("unparseable_output") }

        // A JSON number 0/1 bridges to Bool in Foundation; only a real JSON
        // boolean counts.
        guard let flag = object["is_error"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID()
        else { return unknown("missing_is_error") }
        let isError = flag.boolValue

        let apiErrorValue = object["api_error"]
        let apiError: String?
        switch apiErrorValue {
        case nil, is NSNull: apiError = nil
        case let text as String: apiError = text.isEmpty ? nil : text
        default: return unknown("malformed_api_error")
        }
        let result = object["result"] as? String

        if !isError {
            guard apiError == nil, let result,
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return unknown("no_result") }
            return FableAvailability(state: .available, reason: nil, checkedAt: now, source: .probe)
        }

        if let apiError {
            if apiError == creditsErrorCode {
                return FableAvailability(
                    state: .out, reason: creditsErrorCode, checkedAt: now, source: .probe)
            }
            return unknown(sanitizedReason(apiError))
        }
        if let result, result.lowercased().contains(creditsPhrase) {
            return FableAvailability(
                state: .out, reason: creditsErrorCode, checkedAt: now, source: .probe)
        }
        return unknown("error_without_code")
    }

    /// Classify the line a session shows (or its transcript records) when its
    /// account is out of credits: "You're out of usage credits. Run
    /// /usage-credits to keep using Fable 5.2 or /model to switch models."
    /// Returns nil for any other text. The caller applies it only to a session
    /// whose model is Fable.
    public static func classify(screenText: String, now: Date) -> FableAvailability? {
        // Curly and straight apostrophes both appear; the phrase needs neither.
        guard screenText.lowercased().contains(creditsPhrase) else { return nil }
        return FableAvailability(
            state: .out, reason: creditsErrorCode, checkedAt: now, source: .session)
    }

    /// An `api_error` code made printable: short, and only identifier
    /// characters. Anything else collapses to a fixed tag so reply text can
    /// never reach a table or JSON field through `reason`.
    static func sanitizedReason(_ code: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard code.count <= 64,
              code.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return "unrecognized_error" }
        return code
    }
}
