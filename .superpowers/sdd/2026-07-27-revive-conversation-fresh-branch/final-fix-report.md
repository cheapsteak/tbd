# Final Fix Wave Report

Date: 2026-07-27

## Outcome

Addressed all four final-review findings in commit `cf8a3475`:

1. Fresh conversation revive now opts out of the ordinary generated-name
   collision retry. If both initial base-ref attempts fail, the operation
   throws and `completeCreateWorktree` removes its phase-one `.creating` row.
   Ordinary creates retain the existing retry behavior through a trailing,
   defaulted `retryGeneratedNameOnCollision: Bool = true` control.
2. `GitManagerCommitDateTests` now creates two differently dated commits and
   verifies that both an older explicit SHA and an older tag return the older
   commit's own committer date while `HEAD` returns the newer date.
3. `createInitialNoteTab` documentation now describes both ordinary empty Notes
   and caller-provided seeded Notes.
4. The fetch-success fresh-revive fixture now begins with a stale
   `origin/main`, advances the bare remote from a separate clone, and verifies
   that revive fetches the new commit before creating the branch.

No restart was performed.

## TDD Evidence

### RED

Command:

```text
swift test --filter generatedNameCollisionFailsWithoutCreatingMisleadingFreshRevive
```

Result: exit 1, one test failed with five intended issues.

The two-rejection `reference-transaction` hook forced the initial
`origin/main` and local `main` add attempts to fail. The pre-fix implementation
then silently used its generated-name retry and returned `.ready`. The
regression observed every reported hazard:

- no error was thrown;
- the fresh worktree row remained;
- a seeded Notes row remained;
- the carried context prompt was sent;
- the actual created directory used a different generated name from the row.

This established that the test failed for the identity-drift bug rather than a
fixture or compilation error.

### GREEN

Command:

```text
swift test --filter generatedNameCollisionFailsWithoutCreatingMisleadingFreshRevive
```

Result: exit 0; one test passed.

With fresh revive passing `retryGeneratedNameOnCollision: false`, the same
forced collision throws before the alternate generated-name attempt. The
existing `completeCreateWorktree` catch removes the creating row, and the test
confirms no created path, prompt, or Notes remain.

The companion `ordinaryCreateStillRetriesGeneratedNameCollision` test confirms
the default-on branch still consumes exactly two forced rejections and succeeds
through the ordinary generated-name retry.

## Files

- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`
  - added the trailing/defaulted retry control;
  - threaded it into `attemptWorktreeAdd`;
  - documented seeded and unseeded initial Notes.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+ReviveFresh.swift`
  - disabled generated-name collision retry for identity-sensitive fresh revive.
- `Tests/TBDDaemonTests/WorktreeReviveFreshTests.swift`
  - added deterministic forced-collision and ordinary-create preservation tests;
  - made the fetch-success remote-tracking fixture genuinely stale.
- `Tests/TBDDaemonTests/GitManagerCommitDateTests.swift`
  - added newer `HEAD`, older explicit SHA, and older tag assertions.

## Verification

Focused and adjacent suites:

```text
swift test --filter WorktreeReviveFreshTests
swift test --filter GitManagerCommitDateTests
swift test --filter WorktreeLifecycleTests
swift test --filter WorktreeConversationCarryoverTests
swift test --filter NoteTabOnCreateTests
swift test --filter PreSessionHookTests
```

Results:

- fresh revive: 13 tests passed;
- commit date: 1 test passed;
- worktree lifecycle: 30 tests passed;
- conversation carryover: 3 tests passed;
- initial Notes: 3 tests passed;
- pre-session hook: 40 tests passed.

Repository checks:

```text
git diff --check
swift build
swiftlint --strict
swift test
```

Results:

- diff check: exit 0;
- build: exit 0;
- lint: exit 0, 0 violations in 617 files;
- full tests: exit 0, 4,552 tests in 508 suites passed in 29.929 seconds,
  with one expected known issue from the flaky-quarantine self-test.

SwiftPM continued to emit the repository's existing unhandled-file warnings
for `CLAUDE.md` and source files excluded from particular targets; no new build
warning was introduced by this fix.

## Commit

- `cf8a3475 fix: prevent fresh revive identity drift`

## Concerns

- Ordinary create's legacy generated-name retry remains intentionally unchanged,
  including its existing row/path identity limitation. This fix prevents the
  fresh-revive feature from entering that path because its prompt and Notes
  have already captured the phase-one identity.
- The full suite reports one expected known issue in
  `FlakyQuarantineSelfTests.retriesUntilPass()`; it is the self-test fixture's
  deliberate first-attempt failure and did not fail the suite.
