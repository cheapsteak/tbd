import Foundation
import os

/// One phone action, as the record keeps it (spec section 5, "Record"): the
/// paired phone's name, the method, and what it acted on.
///
/// **What a record never carries.** No message text, answer, prompt text,
/// model name or form value. `target` is a session reference
/// (`PhoneSessionRef.targetDescription`), `repo:<uuid>`, `provider:<name>`, or
/// a fixed word for a method with no target. The service builds it from the
/// decoded params, never from a request's text fields.
struct PhoneActionRecord: Equatable, Sendable {
    let deviceName: String
    let action: String
    let target: String
}

extension PhoneActionRecord {
    /// The longest target a record keeps, in Unicode scalars.
    static let targetLimit = 256

    /// `raw` made safe to log: every scalar that could forge or hide part of a
    /// log line becomes `?`, and it is cut to `targetLimit` scalars. A target
    /// can hold names the phone sent, such as a provider's or a remote
    /// session's, and the record logs it as public text.
    ///
    /// The scalars replaced are control characters, format characters
    /// (among them the bidirectional controls, which can reorder what a
    /// reader sees, and zero-width characters), and the line and paragraph
    /// separators U+2028 and U+2029.
    static func loggableTarget(_ raw: String) -> String {
        let question: Unicode.Scalar = "?"
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars.prefix(targetLimit) {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                scalars.append(question)
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// Where phone actions are recorded. The service records each action once,
/// before its handler runs, and never for a request the request memory
/// answered from an earlier run.
protocol PhoneActionRecording: Sendable {
    func record(_ r: PhoneActionRecord)
}

/// The record in production: one `.notice` line per action under
/// `com.tbd.daemon`, category `phone-bridge`. All three fields are public:
/// none of them can hold message content (see `PhoneActionRecord`).
struct LoggerPhoneActionRecorder: PhoneActionRecording {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    init() {}

    func record(_ r: PhoneActionRecord) {
        Self.logger.notice(
            "Phone action: \(r.deviceName, privacy: .public) ran \(r.action, privacy: .public) on \(r.target, privacy: .public)")
    }
}
