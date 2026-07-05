import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("MergeGate Unit Tests")
struct MergeGateTests {

    // MARK: - Safety Floor Tests

    @Test("Safety floor: passes with valid approval and clean checks")
    func safetyFloorPass() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            approvedSHA: "abc123"
        )
        let decision = gate.evaluate(input: input)

        guard case .wouldMerge = decision else {
            Issue.record("Expected wouldMerge decision for valid input, got \(decision)")
            return
        }
    }

    @Test("Safety floor: fails for draft PR")
    func safetyFloorFailsDraft() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: true,
            hasApprovedReview: true,
            checksClean: true
        )
        let decision = gate.evaluate(input: input)

        if case .escalate(let reason) = decision {
            if case .safetyFloorFailed = reason {
                return
            }
        }
        #expect(Bool(false), "Expected escalate due to draft status")
    }

    @Test("Safety floor: fails without approved review")
    func safetyFloorFailsNoApproval() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: false,
            checksClean: true
        )
        let decision = gate.evaluate(input: input)

        if case .escalate(let reason) = decision {
            if case .safetyFloorFailed(let detail) = reason {
                #expect(detail.contains("claude-review"), "Expected approval error")
                return
            }
        }
        #expect(Bool(false), "Expected escalate due to missing approval")
    }

    @Test("Safety floor: fails with mismatched approval SHA")
    func safetyFloorFailsSHAMismatch() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            approvedSHA: "def456"
        )
        let decision = gate.evaluate(input: input)

        if case .escalate(let reason) = decision {
            if case .safetyFloorFailed = reason {
                return
            }
        }
        #expect(Bool(false), "Expected escalate due to SHA mismatch")
    }

    @Test("Safety floor: fails when checks not clean")
    func safetyFloorFailsChecks() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: false
        )
        let decision = gate.evaluate(input: input)

        if case .escalate(let reason) = decision {
            if case .safetyFloorFailed = reason {
                return
            }
        }
        #expect(Bool(false), "Expected escalate due to failing checks")
    }

    // MARK: - Hard Holds Tests

    @Test("Hard hold: test-hold list")
    func hardHoldTestHoldList() {
        let policy = NightwatchPolicy(testHoldList: [42, 100, 200])
        let gate = MergeGate(policy: policy)
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true
        )
        let decision = gate.evaluate(input: input)

        if case .hold(let reason) = decision {
            if case .testHold = reason {
                return
            }
        }
        #expect(Bool(false), "Expected hold for PR on test-hold list")
    }

    @Test("Hard hold: self-modifying CI")
    func hardHoldSelfModifyingCI() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            touchesCI: true
        )
        let decision = gate.evaluate(input: input)

        if case .hold(let reason) = decision {
            if case .selfModifyingChecks = reason {
                return
            }
        }
        #expect(Bool(false), "Expected hold for self-modifying CI")
    }

    @Test("Hard hold: high-impact domain (glob matching)")
    func hardHoldHighImpactDomain() {
        let policy = NightwatchPolicy(
            impactMapGlobs: ["**/.nightwatch/**", "**/.claude/**"]
        )
        let gate = MergeGate(policy: policy)
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            files: ["sources/main.swift", ".nightwatch/policy.json", "README.md"]
        )
        let decision = gate.evaluate(input: input)

        if case .hold(let reason) = decision {
            if case .highImpactDomain = reason {
                return
            }
        }
        #expect(Bool(false), "Expected hold for high-impact domain")
    }

    @Test("Hard hold: inadequate test coverage (runtime without tests)")
    func hardHoldInadequateTestCoverage() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            files: ["Sources/main.swift", "README.md"]  // Runtime changes, no tests
        )
        let decision = gate.evaluate(input: input)

        if case .hold(let reason) = decision {
            if case .inadequateTestCoverage = reason {
                return
            }
        }
        #expect(Bool(false), "Expected hold for inadequate test coverage")
    }

    @Test("Hard hold: adequate test coverage (runtime with tests)")
    func noHoldWithAdequateTestCoverage() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            files: ["Sources/main.swift", "Tests/mainTests.swift"]
        )
        let decision = gate.evaluate(input: input)

        guard case .wouldMerge = decision else {
            Issue.record("Expected wouldMerge when test coverage is adequate, got \(decision)")
            return
        }
    }

    @Test("Hard hold: doc-only changes (no test requirement)")
    func noHoldDocOnlyChanges() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            files: ["README.md", "docs/guide.md"]
        )
        let decision = gate.evaluate(input: input)

        guard case .wouldMerge = decision else {
            Issue.record("Expected wouldMerge for doc-only changes, got \(decision)")
            return
        }
    }

    // MARK: - Policy Tests

    @Test("Conservative defaults applied when using default policy")
    func conservativePolicyDefaults() {
        let gate = MergeGate()  // Uses conservativeDefaults
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true,
            files: ["scripts/deploy.sh"]  // Matches conservative default impact map
        )
        let decision = gate.evaluate(input: input)

        if case .hold(let reason) = decision {
            if case .highImpactDomain = reason {
                return
            }
        }
        #expect(Bool(false), "Expected conservative policy to hold scripts/**")
    }

    // MARK: - Decision Type Tests

    @Test("wouldMerge decision includes clearance ID")
    func wouldMergeDecision() {
        let gate = MergeGate()
        let input = GateInput(
            prNumber: 100,
            repo: "test/repo",
            headSHA: "abc123",
            isDraft: false,
            hasApprovedReview: true,
            checksClean: true
        )
        let decision = gate.evaluate(input: input)

        if case .wouldMerge(let clearanceID) = decision {
            #expect(!clearanceID.isEmpty, "Clearance ID should not be empty")
            return
        }
        #expect(Bool(false), "Expected wouldMerge decision")
    }
}

@Suite("NightwatchPolicy Unit Tests")
struct NightwatchPolicyTests {

    @Test("Policy loader: returns conservative defaults when file is absent")
    func policyLoaderAbsentFile() throws {
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/"),
            create: true
        ).path

        defer {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        let policy = NightwatchPolicy.load(repoPath: tmpDir)

        #expect(policy == .conservativeDefaults, "Should return conservative defaults when policy file is absent")
    }

    @Test("Policy loader: loads valid policy file")
    func policyLoaderValidFile() throws {
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/"),
            create: true
        ).path

        defer {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        // Create .nightwatch directory and policy.json
        let nightwatchDir = (tmpDir as NSString).appendingPathComponent(".nightwatch")
        try FileManager.default.createDirectory(atPath: nightwatchDir, withIntermediateDirectories: true)

        let policyJSON = """
        {
            "impactMapGlobs": ["**/dangerous/**", "**/critical/**"],
            "compiledSizeCeiling": 100,
            "testHoldList": [42, 99],
            "allowRebaseReclearance": true
        }
        """

        let policyPath = (nightwatchDir as NSString).appendingPathComponent("policy.json")
        try policyJSON.write(toFile: policyPath, atomically: true, encoding: .utf8)

        let policy = NightwatchPolicy.load(repoPath: tmpDir)

        #expect(policy.impactMapGlobs == ["**/dangerous/**", "**/critical/**"], "Should load impactMapGlobs")
        #expect(policy.compiledSizeCeiling == 100, "Should load compiledSizeCeiling")
        #expect(policy.testHoldList == [42, 99], "Should load testHoldList")
        #expect(policy.allowRebaseReclearance == true, "Should load allowRebaseReclearance")
    }

    @Test("Policy loader: returns conservative defaults on malformed JSON")
    func policyLoaderMalformedFile() throws {
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/"),
            create: true
        ).path

        defer {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        // Create .nightwatch directory with malformed policy.json
        let nightwatchDir = (tmpDir as NSString).appendingPathComponent(".nightwatch")
        try FileManager.default.createDirectory(atPath: nightwatchDir, withIntermediateDirectories: true)

        let malformedJSON = "{ invalid json ]"
        let policyPath = (nightwatchDir as NSString).appendingPathComponent("policy.json")
        try malformedJSON.write(toFile: policyPath, atomically: true, encoding: .utf8)

        let policy = NightwatchPolicy.load(repoPath: tmpDir)

        #expect(policy == .conservativeDefaults, "Should return conservative defaults on malformed JSON")
    }

    @Test("Policy loader: handles partial policy file with defaults")
    func policyLoaderPartialFile() throws {
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/"),
            create: true
        ).path

        defer {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        // Create .nightwatch directory with partial policy.json
        let nightwatchDir = (tmpDir as NSString).appendingPathComponent(".nightwatch")
        try FileManager.default.createDirectory(atPath: nightwatchDir, withIntermediateDirectories: true)

        // Only provide impactMapGlobs; let other fields use defaults
        let partialJSON = """
        {
            "impactMapGlobs": ["**/custom/**"]
        }
        """

        let policyPath = (nightwatchDir as NSString).appendingPathComponent("policy.json")
        try partialJSON.write(toFile: policyPath, atomically: true, encoding: .utf8)

        let policy = NightwatchPolicy.load(repoPath: tmpDir)

        #expect(policy.impactMapGlobs == ["**/custom/**"], "Should load custom impactMapGlobs")
        #expect(policy.compiledSizeCeiling == 50, "Should use default compiledSizeCeiling")
        #expect(policy.testHoldList == [], "Should use default testHoldList")
        #expect(policy.allowRebaseReclearance == false, "Should use default allowRebaseReclearance")
    }

    @Test("Policy file can tighten the size ceiling but never widen past the compiled hard ceiling")
    func policySizeCeilingClampsToHardCeiling() throws {
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/"),
            create: true
        ).path
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nightwatchDir = (tmpDir as NSString).appendingPathComponent(".nightwatch")
        try FileManager.default.createDirectory(atPath: nightwatchDir, withIntermediateDirectories: true)
        let policyPath = (nightwatchDir as NSString).appendingPathComponent("policy.json")

        // Widening attempt (the policy-poisoning vector): clamped to the hard ceiling.
        try #"{"compiledSizeCeiling": 5000}"#.write(toFile: policyPath, atomically: true, encoding: .utf8)
        let widened = NightwatchPolicy.load(repoPath: tmpDir)
        #expect(widened.compiledSizeCeiling == NightwatchPolicy.hardSizeCeiling,
                "A policy file must never widen the size ceiling past the compiled maximum")

        // Tightening is allowed.
        try #"{"compiledSizeCeiling": 10}"#.write(toFile: policyPath, atomically: true, encoding: .utf8)
        let tightened = NightwatchPolicy.load(repoPath: tmpDir)
        #expect(tightened.compiledSizeCeiling == 10, "A policy file may tighten the ceiling")

        // The memberwise init clamps too (not just the decoder path).
        let direct = NightwatchPolicy(compiledSizeCeiling: 9999)
        #expect(direct.compiledSizeCeiling == NightwatchPolicy.hardSizeCeiling)
    }
}
