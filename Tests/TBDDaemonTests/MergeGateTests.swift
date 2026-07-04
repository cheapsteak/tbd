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

        #expect(
            if case .wouldMerge = decision { true } else { false },
            "Expected wouldMerge decision for valid input"
        )
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

        #expect(
            if case .wouldMerge = decision { true } else { false },
            "Expected wouldMerge when test coverage is adequate"
        )
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

        #expect(
            if case .wouldMerge = decision { true } else { false },
            "Expected wouldMerge for doc-only changes"
        )
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
