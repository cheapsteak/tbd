import Foundation
import os

/// Discovery of Claude inference profiles available on AWS Bedrock for the
/// user's current credentials and region. Pure shell-out to the local
/// `aws-cli` — no AWS SDK dependency.
enum BedrockModels {

    /// Richer result from `discover` — callers can distinguish every failure
    /// mode from a successful query.
    enum DiscoveryResult: Equatable {
        /// Initial state — no fetch attempted yet (e.g. fresh sheet with empty region).
        case idle
        /// Fetch in flight.
        case loading
        /// Query succeeded. `models` may be empty (user has access but no Claude
        /// inference profiles in this region).
        case success(models: [String])
        /// aws-cli returned an authentication error (expired SSO, missing
        /// credentials, profile name typo). Surface with the recommended
        /// `aws sso login` command.
        case needsAuth(stderrSnippet: String)
        /// aws-cli binary not on PATH. Surface install hint.
        case awsCliMissing
        /// aws-cli authenticated but the caller lacks permission to call
        /// `bedrock:ListInferenceProfiles` in this region (IAM policy / SCP).
        case accessDenied(detail: String)
        /// Bedrock service is not available in the region (no endpoint, region not supported yet).
        case endpointUnavailable(detail: String)
        /// Subprocess didn't return within the 5-second hard limit.
        case timeout
        /// Anything else (parse error, unknown stderr pattern). Snippet of stderr
        /// included so user can self-diagnose.
        case otherError(stderrSnippet: String)
    }

    /// Discover Claude inference profile IDs for the given region (and
    /// optional aws-cli profile name). Returns a richer `DiscoveryResult`
    /// that distinguishes every failure mode for the UI.
    ///
    /// Hard 5-second timeout. Caller should wire via `.task(id:)` to
    /// re-fire on dependency changes.
    static func discover(region: String, awsProfile: String?) async -> DiscoveryResult {
        let trimmedRegion = region.trimmingCharacters(in: .whitespaces)
        guard !trimmedRegion.isEmpty else { return .success(models: []) }

        let trimmedProfile = awsProfile?.trimmingCharacters(in: .whitespaces)
        let profileArg = (trimmedProfile?.isEmpty ?? true) ? nil : trimmedProfile

        var args: [String] = [
            "aws", "bedrock", "list-inference-profiles",
            "--region", trimmedRegion,
            "--query", "inferenceProfileSummaries[?contains(inferenceProfileName, `Claude`)].inferenceProfileId",
            "--output", "json"
        ]
        if let p = profileArg { args += ["--profile", p] }

        let shellResult = await runShell(args: args, timeoutSeconds: 5)
        switch shellResult {
        case .ok(let stdout):
            return .success(models: parseProfileIDs(stdout))
        case .failed(let stderr):
            return classify(stderr: stderr)
        case .launchFailed:
            return .awsCliMissing
        case .timeout:
            return .timeout
        }
    }

    /// Classify a non-zero-exit stderr into the appropriate result case.
    /// Internal visibility so unit tests can assert on the classification
    /// without invoking the subprocess.
    static func classify(stderr: String) -> DiscoveryResult {
        let lower = stderr.lowercased()

        // env: aws: No such file or directory — happens when /usr/bin/env
        // can't find `aws` on PATH. (The launch itself succeeded — env ran,
        // then failed to exec aws.)
        if lower.contains("env: aws") || lower.contains("aws: command not found") {
            return .awsCliMissing
        }

        if classifyAsAuth(stderr) {
            return .needsAuth(stderrSnippet: String(stderr.prefix(200)))
        }

        if lower.contains("accessdenied") ||
           lower.contains("not authorized to perform") ||
           lower.contains("explicit deny") {
            return .accessDenied(detail: String(stderr.prefix(200)))
        }

        if lower.contains("could not connect to the endpoint") ||
           lower.contains("endpointconnectionerror") ||
           lower.contains("unknownendpoint") ||
           lower.contains("service is not available") {
            return .endpointUnavailable(detail: String(stderr.prefix(200)))
        }

        return .otherError(stderrSnippet: String(stderr.prefix(200)))
    }

    /// Parse the `aws --output json` array-of-strings response. Defensive:
    /// returns empty on any malformed input.
    static func parseProfileIDs(_ jsonString: String) -> [String] {
        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return []
        }
        return Array(Set(array)).sorted()
    }

    /// Return `true` when the stderr output indicates an AWS authentication
    /// failure (expired SSO, missing credentials, profile not found, etc.)
    /// rather than a permissions or availability problem.
    static func classifyAsAuth(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        let needles = [
            "token has expired",
            "unable to locate credentials",
            "could not be found",
            "expiredtoken",
            "invalidgrantexception",
        ]
        if needles.contains(where: { lower.contains($0) }) { return true }
        // SSO session expired comes in variants — match both keywords.
        if lower.contains("sso session") && lower.contains("expired") { return true }
        return false
    }

    // MARK: - Shell helper

    private enum ShellResult {
        case ok(String)
        case failed(String)     // non-zero exit; carries stderr
        case launchFailed       // aws binary missing
        case timeout
    }

    /// Run a command via `/usr/bin/env`, returning stdout on success or a
    /// classified `ShellResult` on any error. Stderr is captured for auth
    /// classification on non-zero exits.
    private static func runShell(args: [String], timeoutSeconds: TimeInterval) async -> ShellResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            // Resume exactly once — guard against the timeout + termination
            // handler both firing.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: ShellResult) {
                let shouldResume = resumed.withLock { wasResumed in
                    if wasResumed { return false }
                    wasResumed = true
                    return true
                }
                if shouldResume { continuation.resume(returning: value) }
            }

            task.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    resumeOnce(.ok(stdout))
                } else {
                    resumeOnce(.failed(stderr))
                }
            }

            do {
                try task.run()
            } catch {
                // /usr/bin/env couldn't find `aws`, or another launch failure.
                resumeOnce(.launchFailed)
                return
            }

            // Timeout watchdog
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if task.isRunning {
                    task.terminate()
                    resumeOnce(.timeout)
                }
            }
        }
    }
}

// MARK: - Convenience

extension BedrockModels.DiscoveryResult {
    /// Returns the discovered model IDs when the result is `.success`; empty
    /// otherwise. Used to populate the ComboBoxField suggestions.
    var models: [String] {
        if case let .success(m) = self { return m }
        return []
    }
}
