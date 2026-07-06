import Foundation
import TBDShared
import os

// MARK: - Gate Decision Types

/// The result of evaluating a PR against the merge gate.
public enum GateDecision: Sendable, Equatable {
    /// PR would be merged with this clearance ID.
    case wouldMerge(clearanceID: String)
    /// PR is held for the given reason.
    case hold(HoldReason)
    /// PR escalates for human review with the given reason.
    case escalate(EscalateReason)
}

/// Reasons why a PR is held (never auto-mergeable without override).
public enum HoldReason: Sendable, Equatable {
    /// High-impact domain: change touches a foundational area (per policy impact map).
    case highImpactDomain(domain: String)
    /// Inadequate test coverage: runtime changes without corresponding tests.
    case inadequateTestCoverage
    /// Explicit test-hold placed by human.
    case testHold
    /// Authoring worktree still active and working.
    case authoringWorktreeActive
    /// PR modifies its own CI/workflow (floor integrity guard).
    case selfModifyingChecks
}

/// Reasons why a PR escalates to human review.
public enum EscalateReason: Sendable, Equatable {
    /// SAFETY_FLOOR failure: not approved, checks failing, draft, etc.
    case safetyFloorFailed(detail: String)
    /// GitHub API error or missing data.
    case dataReadFailure(detail: String)
    /// PR size exceeds compiled ceiling.
    case sizeExceedsCeiling(lines: Int, ceiling: Int)
    /// No clearance path authorized this PR.
    case noClearancePath
    /// Clearance was voided (SHA mismatch, PR state changed, etc).
    case clearanceVoided(reason: String)
    /// Unknown or unexpected state.
    case unknownState(detail: String)
}

// MARK: - Merge Gate Input & Policy

/// Input data required to evaluate a PR against the merge gate.
public struct GateInput: Sendable, Equatable {
    /// PR number.
    public let prNumber: Int
    /// Repository name or URL.
    public let repo: String
    /// Head SHA of the PR.
    public let headSHA: String
    /// PR state (open, draft, etc).
    public let isDraft: Bool
    /// Whether the PR has a valid claude-review APPROVED on this SHA.
    public let hasApprovedReview: Bool
    /// Whether required checks are clean.
    public let checksClean: Bool
    /// List of files changed in the PR.
    public let files: [String]?
    /// Number of commits in the PR.
    public let commits: Int?
    /// UUID of the worktree that authored this PR, if known.
    public let authorWorktreeID: UUID?
    /// SHA that was approved by claude-review.
    public let approvedSHA: String?
    /// Whether the PR touches workflow/CI definition files.
    public let touchesCI: Bool

    public init(
        prNumber: Int,
        repo: String,
        headSHA: String,
        isDraft: Bool,
        hasApprovedReview: Bool,
        checksClean: Bool,
        files: [String]? = nil,
        commits: Int? = nil,
        authorWorktreeID: UUID? = nil,
        approvedSHA: String? = nil,
        touchesCI: Bool = false
    ) {
        self.prNumber = prNumber
        self.repo = repo
        self.headSHA = headSHA
        self.isDraft = isDraft
        self.hasApprovedReview = hasApprovedReview
        self.checksClean = checksClean
        self.files = files
        self.commits = commits
        self.authorWorktreeID = authorWorktreeID
        self.approvedSHA = approvedSHA
        self.touchesCI = touchesCI
    }
}

/// Nightwatch merge policy: governs what auto-merges and under what conditions.
public struct NightwatchPolicy: Sendable, Equatable {
    /// Hard compiled maximum on lines changed for any auto-merge. Editable
    /// policy (`.nightwatch/policy.json`) may only tighten BELOW this; a
    /// larger value in a policy file is clamped here, so a policy edit can
    /// never widen the merge set past the compiled floor (design §7.1).
    public static let hardSizeCeiling = 50

    /// Impact map: glob patterns identifying high-impact, foundational domains.
    /// A change matching any pattern is held regardless of approval/checks.
    public let impactMapGlobs: [String]
    /// Effective size ceiling (lines changed) for any auto-merge. Always
    /// `<= hardSizeCeiling` — enforced in init, not trusted from input.
    public let compiledSizeCeiling: Int
    /// Explicit list of PR numbers/names currently under test-hold.
    public let testHoldList: [Int]
    /// Whether to auto-re-clear rebases (advanced feature; Phase 2+).
    public let allowRebaseReclearance: Bool

    public init(
        impactMapGlobs: [String] = [],
        compiledSizeCeiling: Int = NightwatchPolicy.hardSizeCeiling,
        testHoldList: [Int] = [],
        allowRebaseReclearance: Bool = false
    ) {
        self.impactMapGlobs = impactMapGlobs
        self.compiledSizeCeiling = min(compiledSizeCeiling, Self.hardSizeCeiling)
        self.testHoldList = testHoldList
        self.allowRebaseReclearance = allowRebaseReclearance
    }

    /// Conservative defaults when policy file is missing or unparseable.
    public static let conservativeDefaults = NightwatchPolicy(
        impactMapGlobs: ["**/.nightwatch/**", "**/.claude/**", "**/scripts/**"],
        compiledSizeCeiling: 50,
        testHoldList: [],
        allowRebaseReclearance: false
    )

    /// Load policy from `<repo>/.nightwatch/policy.json`.
    /// Returns conservativeDefaults if file is absent or unparseable (with one warning logged if malformed).
    public static func load(repoPath: String) -> NightwatchPolicy {
        let policyPath = (repoPath as NSString).appendingPathComponent(".nightwatch/policy.json")
        guard FileManager.default.fileExists(atPath: policyPath) else {
            return conservativeDefaults
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: policyPath))
            let decoded = try JSONDecoder().decode(NightwatchPolicy.self, from: data)
            return decoded
        } catch {
            let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.policy")
            logger.warning("Failed to parse nightwatch policy at \(policyPath, privacy: .public): \(error, privacy: .public). Using conservative defaults.")
            return conservativeDefaults
        }
    }
}

// MARK: - Codable support for NightwatchPolicy

extension NightwatchPolicy: Codable {
    enum CodingKeys: String, CodingKey {
        case impactMapGlobs
        case compiledSizeCeiling
        case testHoldList
        case allowRebaseReclearance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route through the memberwise init so the hardSizeCeiling clamp
        // applies to policy files too — a policy edit can tighten the
        // ceiling but never widen it (design §7.1, policy-poisoning guard).
        self.init(
            impactMapGlobs: try container.decodeIfPresent([String].self, forKey: .impactMapGlobs) ?? [],
            compiledSizeCeiling: try container.decodeIfPresent(Int.self, forKey: .compiledSizeCeiling)
                ?? NightwatchPolicy.hardSizeCeiling,
            testHoldList: try container.decodeIfPresent([Int].self, forKey: .testHoldList) ?? [],
            allowRebaseReclearance: try container.decodeIfPresent(Bool.self, forKey: .allowRebaseReclearance) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(impactMapGlobs, forKey: .impactMapGlobs)
        try container.encode(compiledSizeCeiling, forKey: .compiledSizeCeiling)
        try container.encode(testHoldList, forKey: .testHoldList)
        try container.encode(allowRebaseReclearance, forKey: .allowRebaseReclearance)
    }
}

// MARK: - Merge Gate Evaluator

/// Pure, injection-based merge gate evaluator.
/// Takes input PR data and policy, returns a typed decision.
/// No I/O, no database access — deterministic for testing.
public struct MergeGate: Sendable {
    public let policy: NightwatchPolicy

    public init(policy: NightwatchPolicy = .conservativeDefaults) {
        self.policy = policy
    }

    /// Evaluate a PR against the merge gate.
    /// Returns the gate decision without executing any action.
    public func evaluate(input: GateInput) -> GateDecision {
        // Step 1: SAFETY_FLOOR — fail closed on any check failure.
        if let floorFailure = checkSafetyFloor(input: input) {
            return .escalate(floorFailure)
        }

        // Step 2: Check hard holds — these always block, regardless of clearance.
        if let hold = checkHardHolds(input: input) {
            return .hold(hold)
        }

        // Step 3: If no hard holds, this PR *would* merge (assuming a valid clearance exists).
        // Phase 1 = evaluate-only; we don't check actual clearances in the gate.
        // Return wouldMerge with a marker clearance ID (will be validated by RPC layer).
        let clearanceID = "phase1-would-merge-\(input.headSHA.prefix(8))"
        return .wouldMerge(clearanceID: String(clearanceID))
    }

    // MARK: - Safety Floor Checks

    private func checkSafetyFloor(input: GateInput) -> EscalateReason? {
        // Draft PRs cannot merge.
        if input.isDraft {
            return .safetyFloorFailed(detail: "PR is marked as draft")
        }

        // Must have an approved review on the current head SHA.
        if !input.hasApprovedReview {
            return .safetyFloorFailed(detail: "Missing claude-review APPROVED on current head SHA")
        }

        // Approval SHA must match current head SHA.
        if let approvedSHA = input.approvedSHA, approvedSHA != input.headSHA {
            return .safetyFloorFailed(detail: "Approval SHA mismatch: approved on \(approvedSHA.prefix(8)), head is \(input.headSHA.prefix(8))")
        }

        // All required checks must be clean.
        if !input.checksClean {
            return .safetyFloorFailed(detail: "Required checks not clean")
        }

        // No required check data is as bad as failing checks (misconfiguration).
        // (This is checked by the daemon at fetch time; we assume non-empty here.)

        return nil
    }

    // MARK: - Hard Holds

    private func checkHardHolds(input: GateInput) -> HoldReason? {
        // Test-hold list.
        if policy.testHoldList.contains(input.prNumber) {
            return .testHold
        }

        // Self-modifying CI/workflow (floor integrity guard).
        if input.touchesCI {
            return .selfModifyingChecks
        }

        // High-impact domain (from policy impact map).
        if let files = input.files {
            for glob in policy.impactMapGlobs {
                if fileMatchesGlob(files: files, glob: glob) {
                    return .highImpactDomain(domain: glob)
                }
            }
        }

        // Inadequate test coverage: runtime changes without tests.
        if !hasAdequateTestCoverage(input: input) {
            return .inadequateTestCoverage
        }

        // (Authoring worktree check & other holds would require DB access; Phase 1 doesn't have them.)

        return nil
    }

    private func hasAdequateTestCoverage(input: GateInput) -> Bool {
        guard let files = input.files, !files.isEmpty else {
            // No file list: be conservative.
            return true
        }

        // Check if any runtime files changed.
        let runtimeFiles = files.filter { !isTestFile($0) }
        guard !runtimeFiles.isEmpty else {
            // Only test files changed → adequate coverage.
            return true
        }

        // Runtime files changed; check if tests were also added/modified.
        let testFiles = files.filter { isTestFile($0) }
        return !testFiles.isEmpty
    }

    private func isTestFile(_ path: String) -> Bool {
        let testPatterns = [
            "Tests/",
            "test_",
            "_test.swift",
            "Test.swift",
            "Tests.swift"
        ]
        return testPatterns.contains { path.contains($0) }
    }

    private func fileMatchesGlob(files: [String], glob: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: Self.globToRegexPattern(glob)) else {
            return false
        }
        return files.contains { path in
            regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
    }

    /// Translate a path glob to an anchored regex by scanning characters —
    /// NOT by cascading string replacements, which corrupt each other's
    /// output (a prior version turned its own `.*` into `.[^/]*`).
    /// Semantics: `**/` = zero or more whole path segments (so `**/x` also
    /// matches a repo-root `x`), `**` = any characters incl. `/`,
    /// `*` = any characters within one segment.
    static func globToRegexPattern(_ glob: String) -> String {
        var out = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            if c == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    let after = glob.index(after: next)
                    if after < glob.endIndex, glob[after] == "/" {
                        out += "(?:[^/]+/)*"   // "**/" — zero or more segments
                        i = glob.index(after: after)
                    } else {
                        out += ".*"            // "**" — any depth
                        i = after
                    }
                } else {
                    out += "[^/]*"             // "*" — within one segment
                    i = next
                }
            } else {
                if #"\^$.|?+()[]{}"#.contains(c) { out += "\\" }
                out.append(c)
                i = glob.index(after: i)
            }
        }
        return out + "$"
    }
}
