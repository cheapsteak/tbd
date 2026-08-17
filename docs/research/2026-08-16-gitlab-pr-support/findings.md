# Extending TBD's pull-request subsystem to GitLab

**Status:** Research only. No design, no spec, no implementation. The open
questions at the end are deliberately left open — a human answers them.

**TBD code read:** 2026-08-16, against the tree at `bf0719f4`. Every claim about
TBD cites `file:line` in that tree.

**GitLab facts checked:** 2026-08-16, against `docs.gitlab.com` and against
GitLab's own source at `gitlab-org/gitlab` `master`. Every claim about GitLab
names the page or file it came from. Claims that could not be verified are
listed in [What could not be verified](#what-could-not-be-verified) rather than
asserted.

Nothing here was measured against a live GitLab instance. `glab` is not
installed on the probe machine (`which glab` → not found), so no command
surface was exercised; the CLI section rests on documentation and on `glab`'s
own source.

## Summary

TBD's PR subsystem is GitHub-only in three separable ways, and they cost
different amounts.

**A URL regex and a handful of string literals** pin the host to `github.com`.
This is the cheap layer. `PRBindingExtractor.urlPattern`
(`Sources/TBDShared/PRBindingExtractor.swift:32`) will not match any other host,
and because every binding path — hook, branch match, manual attach, and the
poll's own heal — funnels through `parsePRURLs`, no binding can form on any
other host at all. The `host` column already exists and already defaults to
`github.com` (`Sources/TBDDaemon/Database/Database.swift:1255`), so the storage
groundwork is done.

**A hard dependency on the `gh` binary** is the middle layer. Every forge call
in the daemon is `gh` (`PRStatusManager.resolvedGHPath`,
`Sources/TBDDaemon/PR/PRStatusManager.swift:2236`), and `gh` is the *only*
forge subprocess in `Sources/` — there is exactly one call site to redirect.
`glab` turns out to be a close counterpart: `glab api graphql -f query='…'`
takes the same subcommand, the same flag spelling, and the same semantics as
`gh api graphql -f query='…'`.

**An assumption about GitHub's data model** is the expensive layer, and it is
where the design work actually is. Three assumptions do not survive the move:

- **A repository is `(owner, repo)`.** GitLab projects live at arbitrary
  namespace depth — up to 20 levels of subgroup nesting
  ([subgroups](https://docs.gitlab.com/user/group/subgroups/)) — so a project's
  identity is a single `fullPath` string, not a pair. This reaches the DB unique
  index, `PRBinding.identityKey`, the cross-repo heal, and the wrong-repo
  rejection.
- **Mergeability is `mergeStateStatus` + `reviewDecision` + a per-check
  `isRequired` rollup.** GitLab collapses all three into one enum,
  `detailed_merge_status`, with 22 values that do not partition the way TBD's
  eight states do. Some GitLab states have no TBD expression; some TBD states
  have no GitLab answer.
- **Required checks are a per-PR list you must fetch separately.** GitLab has no
  per-check required flag. That removes TBD's second round trip per PR entirely,
  which is a *simplification* — and it removes the distinction TBD's icon colour
  currently rests on.

**Batching is not a risk; it is the strongest part of the story.** GitLab's
GraphQL `mergeRequests` resolver takes `iids: [String]`
([resolver source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/resolvers/merge_requests_resolver.rb)),
so N merge requests in a project come back from one *field*, not N aliases —
and `detailedMergeStatus` and `headPipeline { status }` ride in the same
response, eliminating TBD's per-PR check query. Per-tick round trips on a
40-worktree fleet go from roughly 11–51 down to roughly 5–6. REST batches too:
`GET /projects/:id/merge_requests?iids[]=…`. The real cost question is not the
number of calls but the server-side price of the fields, several of which are
`calls_gitaly: true`, against a documented complexity ceiling of 250 for an
authenticated GraphQL query.

**Host identification is the genuinely unsolved part.** Self-hosted GitLab lives
on arbitrary domains, and nothing in a git remote says which forge answers
there. `glab` does not solve this — it does not probe at all; it takes the host
from configuration or `GITLAB_HOST` and assumes
([`internal/glinstance/host.go`](https://gitlab.com/gitlab-org/cli/-/raw/main/internal/glinstance/host.go)).
Whatever TBD does here is a decision, not a lookup.

A note on scope, because it changes the shape of the work: **GitHub Enterprise
is a much smaller, separable case.** `gh` already speaks to it, the GraphQL
schema is identical, and the state model is identical. Only the URL regex and
the `host` plumbing block it. Whether to do that first — as a cheap validation
of the host plumbing GitLab will also need — is one of the open questions.

## Part 1 — Where TBD assumes GitHub

### Hardcoded `github.com`

- **The binding URL regex.** `PRBindingExtractor.urlPattern` is
  `https://github\.com/…/pull/(\d+)`
  (`Sources/TBDShared/PRBindingExtractor.swift:32-33`), and `parsePRURLs` stamps
  `host: "github.com"` onto every result it returns (`:239`). Its own comment
  states the lock is deliberate and additive support is later (`:29-31`).
- **This regex is the single chokepoint for all three discovery sources.** The
  hook path calls it through `PRBindingExtractor.extract(fromHookPayload:)`
  (`:249-255`); manual attach calls it through
  `RPCRouter.resolvePRRef` (`Sources/TBDDaemon/Server/RPCRouter.swift:1237`);
  and the poll's branch matcher and both heals call it through
  `PRStatusManager.bindablePRURLs`
  (`Sources/TBDDaemon/PR/PRStatusManager.swift:714-725`), which routes through
  `parsePRURLs` *on purpose* so the poll obeys the same host lock. On a
  non-`github.com` host every one of these yields nothing, and the heals yield
  nothing in the safe direction (no removal).
- **Bare-number attach synthesises a GitHub URL.** `RPCRouter.prRef` builds
  `https://github.com/\(owner)/\(name)/pull/\(number)` with `host: "github.com"`
  (`RPCRouter.swift:1255-1260`). This is also what seeds provenance bindings
  from `Worktree.prNumber`, so `tbd pr attach 412` on a GitLab worktree would
  mint a URL pointing at the wrong forge.
- **The model default.** `PRBinding.init` defaults `host` to `"github.com"`
  (`Sources/TBDShared/PRBinding.swift:32`), as does the DB column
  (`Database.swift:1255`).
- **The display-only synthetic binding** the app lifts from a cached
  `Worktree.prStatus` takes that same default
  (`Sources/TBDApp/PRBindingPresentation.swift:71-81`), so a chip rendered from
  a cached status is labelled `github.com` regardless of where the PR lives.
- **The terminal's `PR #123` click target.** `TBDTerminalView.gitHubBrowserURL`
  rewrites an `scp`-style remote only when it starts with `git@github.com:` and
  then appends `/pull/<n>` (`Sources/TBDApp/Terminal/TBDTerminalView.swift:576`,
  `:586-593`). On any other host it produces a link to a path that does not
  exist.
- **URL parsing assumes the GitHub path shape.**
  `PRStatusManager.parseOwnerRepo(fromURL:)` requires `parts[2] == "pull"`
  (`PRStatusManager.swift:1340-1346`). A GitLab MR URL is
  `https://<host>/<namespace…>/<project>/-/merge_requests/<iid>`, whose third
  segment is `-`, so this returns nil — which in turn silently disables the
  cross-repo poisoned-cache heal (`:1691-1706`) and `fetchCheckSignals`
  (`:2155`).

### The `gh` CLI

- **One resolver, one runner.** `resolvedGHPath` probes
  `/usr/local/bin/gh`, `/opt/homebrew/bin/gh`, `/usr/bin/gh`, then `PATH`
  (`PRStatusManager.swift:2236-2249`), and `runGHResult` is the only place a
  forge subprocess is spawned (`:2196-2233`). A repo-wide grep for a forge
  binary finds `gh` in exactly this file and in the seeded Nightwatch scripts;
  no other `Sources/` target shells out to a forge.
- **The seam already exists.** `PRStatusManager.GHRunner`
  (`:129-131`) is an injected closure taking `(args, repoPath)`, used by tests.
  Whatever a second forge needs, it does not need a new process-spawning
  abstraction invented for it.
- **Five distinct `gh` argument vectors** are in use:
  - `repo view --json nameWithOwner --jq .nameWithOwner` (`:2017`) — resolve the
    checkout's `owner/name`, TTL-cached 15 minutes (`:2028-2035`).
  - `api graphql -f query=<viewer batch>` (`:2122-2133`) — the viewer's first
    100 PRs across every repo.
  - `api graphql -f query=<aliased by-number> -f owner= -f name=` (`:2098-2103`,
    `:829-834`) — the numbered and per-binding paths.
  - `api graphql -f query=<by branch> -f owner= -f name= -f branch=`
    (`:1398-1406`) — single-worktree refresh.
  - `api graphql -f query=<per-PR check detail>` (`:2159-2160`) — the required-
    check rollup for one PR.
- **Auth is assumed host-scoped and ambient.** The code notes that `gh` auth is
  host-scoped so any checkout serves as the working directory (`:434-438`,
  `:771-773`). `refreshBindingGroup` explicitly does *not* pass `group.host` to
  `gh`, and says so, precisely because binding is host-locked today
  (`:818-820`).

### GitHub's data model

- **`(owner, repo)` as the repository identity.** It is a tuple in every
  signature that carries it — `resolveNameWithOwner` (`:2016`), `repoIdentity`
  (`:2042`), `groupNumberedByRepo` (`:2055`), `groupBindingsByRepo` (`:792`),
  `repoBranchKey` (`:1619`) — and two columns in the schema
  (`Database.swift:1256-1257`) participating in the unique identity index
  (`:1273-1277`). `PRBinding.identityKey` is
  `host ⧉ owner ⧉ repo ⧉ number` (`PRBinding.swift:97-99`), and
  `PRBindingStore.identity(from:)` splits it back on exactly four parts
  (`Sources/TBDDaemon/Database/PRBindingStore.swift:257-264`).
- **Case folding justified by GitHub's rules.** Owner and repo are lowercased on
  write (`PRBindingStore.swift:29-31`) and on comparison
  (`PRBinding.swift:96-99`, `PRStatusManager.swift:1615-1621`,
  `PRBindingCoordinator.swift:81-82`), each citing that GitHub treats them
  case-insensitively.
- **The state derivation.** `mapStateAndReason`
  (`PRStatusManager.swift:1141-1178`) reads GitHub's `state`,
  `mergeStateStatus` (`CLEAN`, `HAS_HOOKS`, `UNSTABLE`, `BLOCKED`, `DIRTY`,
  `BEHIND`, `UNKNOWN`, `DRAFT`), `reviewDecision` (`CHANGES_REQUESTED`,
  `REVIEW_REQUIRED`, `APPROVED`), `isDraft`, and two booleans derived from the
  per-check query.
- **Required-check awareness.** `checkSignals` filters contexts to
  `isRequired == true` (`:1250-1256`), where `isRequired` comes from GitHub's
  `isRequired(pullRequestNumber:)` field on `CheckRun` and `StatusContext`
  (`prCheckQuery`, `:1351-1363`). The comment at `:1244-1249` states the
  consequence: a PR with no required checks gets no CI colouring at all, and
  `mergeStateStatus` decides instead.
- **The merge queue.** `PRStatus.mergeQueuePosition` is documented as
  "1-indexed position in GitHub's merge queue"
  (`Sources/TBDShared/Models.swift:1643-1650`), sourced from
  `mergeQueueEntry.position` (`PRStatusManager.swift:1875-1876`) — with a note
  that no `mergeStateStatus` value expresses it.
- **The viewer-authored batch as the discovery substrate.**
  `runGHGraphQL` fetches `viewer { pullRequests(first: 100, …) }`
  (`:2122-2132`), and the whole unnumbered path — `matchUnnumbered` (`:1660`),
  `bestNodeByRepoBranch` (`:1632`), `cachedNumberFallback` (`:1598`),
  `headRefVerificationTargets` (`:1789`) — is built on it, including the
  `batchSucceeded` predicate that gates both heals.
- **`PRMergeableState`** is eight cases (`Models.swift:1607-1630`) with an
  `attentionSeverity` ordering defined once in `PRBinding.swift:114-124`, read by
  the toolbar icon, the sidebar dot and the `Worktree.prStatus` column.

### The hook's `gh pr create` gate

- **The prefilter grep** is `pr([^[:alnum:]]|\\[tr])+create`
  (`Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift:182`), embedded in
  `prBindCommand` (`:196-197`) and wired as a `PostToolUse` `Bash` matcher with a
  3-second timeout (`:281-294`, `:209`). The pattern deliberately does not
  require `gh` adjacency (`:144-148`), so it would also admit a `glab mr create`
  payload only if the words `pr` and `create` appear — which they do not.
- **The authoritative gate** is `PRBindingExtractor.isPRCreateCommand`, which
  requires the command word to be `gh` or to end in `/gh`
  (`PRBindingExtractor.swift:210-212`) and the subcommand path to be exactly
  `["pr", "create"]` (`:224`), with `-R`, `--repo`, `--hostname` treated as
  value-taking flags (`:41`).

### UI copy and the CLI

Surfaces that say "GitHub" or "PR" to a user:

- **CLI help and errors.** `PRRefArgument.reference` help reads "PR number,
  #number, or full GitHub PR URL"
  (`Sources/TBDCLI/Commands/PRCommands.swift:99`), and the parse failure says
  the same (`:105`). `PRCommand.parseReference`'s doc says GitHub PR URL
  (`:17`).
- **The RPC error string** "pr reference must be a github PR url or a number in
  the worktree's own repo" (`RPCRouter.swift:1210`).
- **`tbd pr list` output** renders `#412  <reason>  <branch>  (<source>)`
  (`PRCommands.swift:86-90`) and "No PRs bound to this worktree." (`:76`).
- **The `tbd` skill** documents `tbd pr list|attach|detach` as PRs
  (`Sources/TBDShared/TBDSkillContent.swift:187-189`).
- **App copy**: `"\(bindings.count) PRs"` and `"#412"`
  (`Sources/TBDApp/PRBindingPresentation.swift:87-93`), `"Open PR #…"` and
  `"PR #…"` (`Sources/TBDApp/ContentView.swift:487-488`, `:1065`),
  `"Open PR \(chip.label)"` and the accessibility label
  (`Sources/TBDApp/Helpers/StatusBarView.swift:291-292`, `:333`), the sidebar
  tooltip (`Sources/TBDApp/Sidebar/WorktreeRowView.swift:213`, `:223`), the tab
  label `"PR #\(number)"` (`Sources/TBDApp/AppState+Tabs.swift:531`), the
  auto-archive and auto-hibernate toggles (`ContentView.swift:439`, `:455`;
  `Sources/TBDApp/Settings/SettingsView.swift:148`, `:154`), the branch picker
  placeholder "Filter branches & PRs"
  (`Sources/TBDApp/Sidebar/BranchPickerView.swift:53`) and its rows (`:225-226`),
  and the hibernation banner "Hibernated after the PR merged"
  (`Sources/TBDApp/Terminal/TerminalContainerView.swift:408`).
- **Deliberately forge-neutral already**: the `PRUndeterminedCause` vocabulary
  says "the forge CLI was unavailable", "the forge query failed" and so on
  (`PRStatusManager.swift:13-34`) — a closed vocabulary chosen so a tooltip never
  carries a host or org name. That naming convention is the one piece of
  user-facing copy that already generalises.

## Part 2 — What GitLab offers, against what TBD needs

GitLab exposes both a REST v4 API at `/api/v4`
([REST docs](https://docs.gitlab.com/api/rest/), `PRIVATE-TOKEN` header,
pagination default 20 / max 100) and a GraphQL API at `/api/graphql`
([GraphQL docs](https://docs.gitlab.com/api/graphql/), `Authorization: Bearer`).

Against each fact TBD needs:

- **Merge-request number** — `iid`, the per-project internal ID. In GraphQL it
  is typed `GraphQL::Types::String`, not `Int`
  ([`merge_request_type.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/types/merge_request_type.rb)),
  so a parse must accept a string. There is also a separate instance-global
  `id`; the `iid` is what appears in the URL and in the UI.
- **Title** — `title` (GraphQL and REST).
- **State** — `state`, values `opened`, `closed`, `merged`, `locked`
  ([merge requests API](https://docs.gitlab.com/api/merge_requests/)). Note
  `opened`, not GitHub's `OPEN`, and the extra `locked`.
- **Mergeability** — `detailed_merge_status` (REST) / `detailedMergeStatus`
  (GraphQL), a 22-value enum; plus a coarse `mergeable` boolean and a
  `conflicts` boolean. The older `merge_status` (`unchecked`, `checking`,
  `can_be_merged`, `cannot_be_merged`, `cannot_be_merged_recheck`) is deprecated
  in favour of `detailed_merge_status` as of GitLab 15.6.
- **Review / approval decision** — there is no single field. GitLab exposes
  `approved` (Boolean), `approvedBy`, and, in the EE code path,
  `approvalsLeft`, `approvalsRequired`, `approvalState` and `changeRequesters`
  ([`ee/…/merge_request_type.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/master/ee/app/graphql/ee/types/merge_request_type.rb)).
  Per-reviewer state lives in `MergeRequestReviewState`, whose values are
  `UNREVIEWED`, `REVIEWED`, `REQUESTED_CHANGES`, `APPROVED`, `UNAPPROVED`,
  `REVIEW_STARTED`
  ([enum source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/types/merge_request_review_state_enum.rb)).
  Over REST, approvals are a *separate call*:
  `GET /projects/:id/merge_requests/:iid/approvals` (Free; returns
  `approvals_required`, `approvals_left`, `approved`, `approved_by`) and
  `GET …/approval_state` (Premium/Ultimate; per-rule detail)
  ([approvals API](https://docs.gitlab.com/api/merge_request_approvals/)).
- **CI status** — `headPipeline { status }`, an enum with values `CREATED`,
  `WAITING_FOR_RESOURCE`, `PREPARING`, `WAITING_FOR_CALLBACK`, `PENDING`,
  `RUNNING`, `FAILED`, `SUCCESS`, `CANCELING`, `CANCELED`, `SKIPPED`, `MANUAL`,
  `SCHEDULED`
  ([enum source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/types/ci/pipeline_status_enum.rb)).
  A merge request has **one** head pipeline, not a rollup of independent checks.
- **Head and base branch** — `sourceBranch` and `targetBranch` (GraphQL),
  `source_branch` / `target_branch` (REST).
- **Draft status** — `draft` (Boolean) in both. GitLab's draft state is derived
  from a `Draft:` title prefix but is exposed as a first-class field, and it also
  appears in `detailed_merge_status` as `draft_status`.
- **Merge-queue analogue** — merge *trains*
  ([docs](https://docs.gitlab.com/ci/pipelines/merge_trains/)). Position is
  available in GraphQL as `MergeTrainCar.index`, documented as "Zero-based
  position of the car in the merge train. Returns `null` if the car is not
  active in a merge train"
  ([car type source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/ee/app/graphql/types/merge_trains/car_type.rb)),
  reachable from the merge request as `mergeTrainCar { index }`. The REST merge
  trains API explicitly does not return a position — "The REST API response does
  not include an explicit queue position for each merge request" — and directs
  callers to sort by `id` ascending, or to use `MergeTrainCar.index`
  ([merge trains API](https://docs.gitlab.com/api/merge_trains/)). Merge trains
  are a paid-tier feature; TBD's merge-queue field is already optional and nil
  by default, so an instance without them simply reports nil.
- **Web URL** — `webUrl` (GraphQL) / `web_url` (REST), giving the canonical
  `https://<host>/<fullPath>/-/merge_requests/<iid>`.

## Part 3 — The state-model mapping, and where it breaks

TBD's `PRMergeableState` has eight cases with a strict attention ordering:
`checksFailed` (6) > `blocked` (5) > `changesRequested` (4) > `pending` (3) >
`mergeable` (2) > `draft` (1) > `merged`/`closed` (0)
(`PRBinding.swift:114-124`). That ordering is what a red dot means, and the
toolbar icon, the sidebar dot and the `Worktree.prStatus` column all read it.

### Where the mapping is clean

- `state = merged` → `.merged`; `state = closed` → `.closed`.
- `draft = true`, or `detailedMergeStatus = DRAFT_STATUS` → `.draft`.
- `detailedMergeStatus = MERGEABLE` → `.mergeable`.
- `detailedMergeStatus = CONFLICT` → `.blocked`, matching TBD's handling of
  GitHub's `DIRTY` ("Merge conflicts", `PRStatusManager.swift:1168-1169`).
- `detailedMergeStatus = NEED_REBASE` → `.blocked`, matching GitHub's `BEHIND`
  ("Behind base branch", `:1170-1171`).
- `detailedMergeStatus = CI_STILL_RUNNING`, `UNCHECKED`, `CHECKING`,
  `PREPARING`, `APPROVALS_SYNCING` → `.pending`. GitHub's `UNKNOWN` already maps
  that way (`:1172-1173`).
- `detailedMergeStatus = CI_MUST_PASS` → `.checksFailed`. This is the one that
  most needs a decision, and it is discussed below.
- `detailedMergeStatus = NOT_APPROVED` → `.blocked` or `.changesRequested`,
  depending on the answer to the review-decision question below.

### Where it breaks

**GitLab states TBD cannot express.** The 22-value enum
([source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/types/merge_requests/detailed_merge_status_enum.rb),
read 2026-08-16) includes several blockers that TBD can only flatten into
`.blocked`, losing the reason:

- `DISCUSSIONS_NOT_RESOLVED` — "Discussions must be resolved before merging."
  GitHub has no equivalent gate; TBD has no state for it.
- `BLOCKED_STATUS` (`merge_request_blocked`) — "Merge request dependencies must
  be merged." A cross-MR dependency; TBD models no such relation.
- `EXTERNAL_STATUS_CHECKS` (`status_checks_must_pass`) — Ultimate-tier external
  checks ([status checks](https://docs.gitlab.com/user/project/merge_requests/status_checks/)).
- `SECURITY_POLICIES_VIOLATIONS`, `JIRA_ASSOCIATION`, `TITLE_NOT_MATCHING`,
  `LOCKED_PATHS`, `LOCKED_LFS_FILES`, `MERGE_TIME`, `COMMITS_STATUS`.

`.blocked` already carries a free-text `reason` string, so the *reason* survives
in the tooltip. What does not survive is severity: all of these land at
severity 5, above `changesRequested`, and a `MERGE_TIME` block ("may not be
merged until after the specified time") demands no action at all while ranking
above a reviewer asking for changes. Whether the ordering needs a new tier — or
whether some of these should map to a low-severity "waiting" rather than
`.blocked` — is a design call, not a mechanical one.

**TBD states GitLab cannot answer.**

- **`.checksFailed` as distinct from `.blocked`.** GitHub gives TBD a per-check
  `isRequired` flag, and TBD colours the icon red *only* on a failing required
  check (`checkSignals`, `PRStatusManager.swift:1250-1256`). GitLab has no
  per-check required flag. Required-ness is expressed three other ways: the
  project setting that pipelines must succeed, `allow_failure` on individual
  jobs (which keeps the pipeline green), and Ultimate-tier external status
  checks. So on GitLab, "a required check is failing" collapses to
  `detailedMergeStatus = CI_MUST_PASS`, or to `headPipeline.status = FAILED` on a
  project that does not require pipelines. Those are two different facts and only
  one of them is a merge blocker.
- **GitHub's `UNSTABLE`.** TBD maps it to `.mergeable` with the explicit note
  "mergeable with only non-required checks failing → not red" (`:1162-1164`).
  GitLab's nearest equivalent is a green pipeline with `allow_failure` jobs that
  failed — which reports `SUCCESS`, so the state is simply invisible rather than
  mis-mapped. Acceptable, but it means the GitLab path can never show the amber
  "something failed but it doesn't block" signal.
- **`.changesRequested` as a first-class decision.** GitHub's `reviewDecision`
  is one field with three values. GitLab's nearest analogue is either
  `detailedMergeStatus = NOT_APPROVED` (which conflates "nobody has approved
  yet" with "someone objected") or the EE-only `changeRequesters` connection,
  or a scan of every reviewer's `reviewState` for `REQUESTED_CHANGES`. The
  first is available everywhere and is the wrong shape; the latter two are
  either paid-tier or cost extra fields. Note that TBD's current rule treats
  GitHub's `BLOCKED` + `REVIEW_REQUIRED` as `.mergeable`, deliberately
  ("Ready to merge", `:1166-1167`) — the analogous GitLab call would be to treat
  `NOT_APPROVED` with zero change-requesters as `.mergeable`, which needs the
  paid-tier field to distinguish.
- **`isTerminal`.** GitLab's `locked` state is a fourth value TBD's
  `PRMergeableState` has no case for. It is transient (the MR is mid-merge), so
  mapping it to `.pending` is probably right, but it must be mapped explicitly
  or the `default:` arm sends it to `.blocked`.

**The merge-queue index is off by one.** `PRStatus.mergeQueuePosition` is
documented as 1-indexed with "front of queue == 1" (`Models.swift:1643`);
`MergeTrainCar.index` is documented as zero-based. Whatever renders the bus icon
reads that number directly, so the mapping must add one — or the field's
contract must change, which touches the GitHub side too.

**Mergeability may be stale on a list read.** GitLab's merge-request list
endpoint documentation notes that listing "might not proactively update the
`merge_status` field, as this represents an expensive operation", and offers
`with_merge_status_recheck` to request (but not guarantee) an asynchronous
recomputation. TBD's `PRObservation` vocabulary already has the right shape for
this — an `.undetermined(cause:)` distinct from a value — but a
`detailedMergeStatus` of `UNCHECKED` arriving from a batch read is a *third*
thing again: the forge answered, and the answer is "I have not computed it".
Mapping that to `.pending` is plausible; mapping it to
`.undetermined(cause: …)` may be more honest. Whether the GraphQL path has the
same laziness is unverified.

## Part 4 — Batching and fleet cost

### What TBD spends today

Derived from the code, per poll pass (`RPCRouter.runPollPass`,
`RPCRouter.swift:735-774`), at 30 s foregrounded and 300 s backgrounded
(`GitPollCadence.prInterval`,
`Sources/TBDDaemon/Server/GitPollingPolicy.swift:40-42`):

- **1** viewer-batch GraphQL call covering every unnumbered worktree across
  every repo (`PRStatusManager.swift:2122-2133`).
- **1 per repo group** for the aliased by-number query
  (`fetchNumberedMatches`, `:2081-2120`).
- **≤1 per repo group** more for `cachedNumberFallback` (`:1598`), and **≤1 per
  repo group** more for the once-per-daemon-run head-ref verification (`:1789`).
- **1 per (host, owner, repo) group** for `refreshBindings` (`:774-785`,
  `:821-834`).
- **1 per PR** — the expensive term — for `fetchCheckSignals` (`:2154-2174`),
  run for every matched OPEN PR whose aggregate rollup is not `SUCCESS`, on both
  the worktree-keyed and the binding-keyed paths.
- **1 `gh repo view` subprocess per distinct checkout path**, behind a 15-minute
  TTL (`:2028-2035`).

On a 40-worktree fleet across 5 repos with every worktree bound, that is roughly
11 GraphQL round trips in the quiet case and up to ~51 when every PR is open and
non-green — each one a separate `gh` subprocess.

The 20-bindings-per-worktree cap exists explicitly to bound this: "Bounds the
per-poll GraphQL cost of a long-lived worktree"
(`PRBindingStore.swift:87-90`).

### What GitLab would spend

**GraphQL batches by argument, not by alias.** The `mergeRequests` resolver
takes `iids: [GraphQL::Types::String]` — "Array of IIDs of merge requests, for
example `[1, 2]`" — and also `sourceBranches: [String]`, `targetBranches`,
`state`, `authorUsername`, `reviewState(s)`
([resolver source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/resolvers/merge_requests_resolver.rb)).
So one field under `project(fullPath:)` returns N merge requests, and several
projects can be aliased in one document:

```
query {
  p0: project(fullPath: "acme/backend")  { mergeRequests(iids: ["1","2","3"]) { nodes { … } } }
  p1: project(fullPath: "acme/infra/db") { mergeRequests(iids: ["7"])         { nodes { … } } }
}
```

**And the second round trip disappears.** `detailedMergeStatus`,
`headPipeline { status }`, `approved`, `conflicts`, `draft`, `sourceBranch`,
`targetBranch` and `webUrl` are all fields on `MergeRequest`
([type source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/types/merge_request_type.rb)),
so the per-PR `fetchCheckSignals` call has no GitLab counterpart — the verdict
arrives in the batch. That removes the one term in TBD's cost that scales with
PR count rather than repo count.

**Net:** the same 40-worktree, 5-repo fleet costs roughly **5–6 round trips per
pass**, quiet case and busy case alike, versus 11–51 today. Batching is a
strength here, not a risk.

**REST batches too**, if a design prefers it:
`GET /projects/:id/merge_requests?iids[]=1&iids[]=2`, and the list response
carries `detailed_merge_status`, `draft`, `source_branch`, `target_branch`,
`web_url`, `has_conflicts` and `blocking_discussions_resolved`. It does **not**
appear to carry `head_pipeline` — that is documented on the single-MR response —
so a REST design would reintroduce a per-MR call for pipeline status, or accept
`detailed_merge_status` alone. This asymmetry is the strongest argument for
GraphQL on the GitLab side.

### The real cost ceilings

- **Query complexity.** Authenticated GraphQL queries are capped at **250**
  complexity, unauthenticated at 200, admin at 300; depth 15 authenticated-20;
  max query size **10,000 characters**; request timeout **30 seconds**; max page
  size **100 nodes**
  ([GraphQL limits](https://docs.gitlab.com/api/graphql/),
  [`gitlab_schema.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/gitlab_schema.rb)).
  Docs state "each field in a query adds `1` to the complexity score, although
  this can be higher or lower for particular fields", and do not document how
  connections or `calls_gitaly` fields are scored. A batch of 20 merge requests
  with 10 fields each is either 10 (if connections cost per-field) or 200+ (if
  per-node) — a factor of twenty apart, and the answer decides whether the
  20-binding cap is comfortable or already over budget. **This must be measured
  against a real instance before a cadence is chosen.**
- **Gitaly-backed fields.** `detailedMergeStatus`, `mergeable`, `approved`,
  `approvalsLeft` and `approvalsRequired` are all declared `calls_gitaly: true`.
  Each is a git-layer operation server-side. Asking for all of them across 20
  merge requests every 30 seconds, per project, per fleet, is a load question
  that no rate limit will surface until an administrator complains.
- **Rate limits are generous.** gitlab.com allows **2,000 authenticated API
  requests per minute per user** and 500 unauthenticated per IP
  ([gitlab.com limits](https://docs.gitlab.com/user/gitlab_com/)). At the 5-minute
  background cadence, a 5-project fleet spends about 60 requests per hour.
  Self-hosted instances set their own limits.

## Part 5 — Identifying the host

**A git remote gives you a hostname and nothing else.** `git@gitlab.acme.com:…`
and `git@git.acme.com:…` are equally plausible GitLab remotes, and
`git@git.acme.com:…` is an equally plausible Gitea, Forgejo, Bitbucket Server or
plain-SSH remote. TBD's existing `RemoteRepoMatching` deliberately *discards*
the host when normalising remotes (`Sources/TBDShared/RemoteRepoMatching.swift:17-23`),
and already documents the resulting collision — "a self-hosted GitLab mirror of
a GitHub repo" — as accepted. Nothing in TBD currently records which forge a
repo belongs to.

**`glab` does not solve this.** Its `internal/glinstance` package resolves a
hostname from configuration and environment only, and `IsSelfHosted()` is a
string comparison against `gitlab.com`
([`host.go`](https://gitlab.com/gitlab-org/cli/-/raw/main/internal/glinstance/host.go)).
There is no network probe anywhere in that logic. `glab api` selects the host by
taking "the authenticated GitLab host from that repo" if inside a git directory,
else gitlab.com, overridable with `--hostname`
([`glab-api(1)`](https://man.archlinux.org/man/glab-api.1.en)) — that is, the
user must first have run `glab auth login --hostname <host>`, which is itself
the declaration. **`glab`'s answer to "how do you know it's GitLab" is "the user
told us."**

**A cheap probe does exist, if a design wants one.** `GET
https://<host>/api/v4/version` returns **HTTP 401** unauthenticated — verified
directly against gitlab.com on 2026-08-16, which returned 401 with no body
readable. Authentication is required for that endpoint and for `/api/v4/metadata`
([version/metadata API](https://docs.gitlab.com/api/version/)). A 401 from
`/api/v4/version` is therefore a strong positive fingerprint: a non-GitLab host
almost certainly 404s. But it is an unauthenticated outbound request to an
arbitrary domain read from a user's git config, made by a background daemon, and
that is a decision with a privacy dimension, not a lookup.

**The options, stated without choosing between them:**

- **User declaration per repo** — a `forge` value the user sets, stored either as
  a DB column on `repo` (the structured-settings pattern) or as a file under
  `~/tbd/repos/<repoID>/` (the user-authored-blob pattern; see the two patterns
  in the root `CLAUDE.md`). Zero network, zero guessing, and consistent with
  "compile only what user-land cannot do well". Costs a setup step per repo.
- **Infer from what the user already configured** — if `glab auth status` (or
  `~/.config/glab-cli/config.yml`) already names the host, TBD can read that
  rather than asking again. This is exactly what `glab` itself relies on, and it
  degrades to "no GitLab support here" rather than to a wrong answer.
- **Hostname heuristic** — treat a host containing `gitlab` as GitLab. Cheap,
  wrong on `git.acme.com`, and wrong in the silent direction.
- **Network probe** — `/api/v4/version` as above, cached per host.
- **Try both CLIs** — run `gh` and, on the "not a GitHub host" failure, run
  `glab`. No probe of TBD's own, but two subprocesses per resolution and an
  error path used as control flow.

## Part 6 — The CLI and auth story

**`glab` is the counterpart to `gh`**, published by GitLab at
`gitlab-org/cli`, and it is closer to a drop-in than the two projects'
independence would suggest.

- **The GraphQL invocation is character-for-character analogous.**
  `glab api graphql -f query='…'` is documented with GraphQL examples, `-f,
  --raw-field` is "Add a string parameter" and `-F, --field` is the
  type-inferring one — the same split as `gh`, including which letter means
  which ([`glab-api(1)`](https://man.archlinux.org/man/glab-api.1.en)). TBD's
  existing comment explaining why it uses `-f` and not `-F`
  (`PRStatusManager.swift:1392-1397`) transfers verbatim. `--paginate`,
  `--method`, `--header` and `--hostname` all exist.
- **Authentication.** Token resolution order is `GITLAB_TOKEN` environment
  variable, then `$HOME/.config/glab-cli/config.yml`
  ([README](https://gitlab.com/gitlab-org/cli/-/raw/main/README.md)); on macOS
  the config may also live under `~/Library/Application Support/glab-cli/`.
  `glab auth login` supports OAuth (web or device flow), a personal access token
  via `--token` or `--stdin`, and CI job tokens; a PAT needs at least the `api`
  and `write_repository` scopes
  ([authentication docs](https://docs.gitlab.com/cli/authentication/)).
- **Self-hosted is first-class.** `--hostname` targets an instance and
  `GITLAB_HOST` sets the default; glab is documented as supporting GitLab.com,
  Dedicated and Self-Managed. OAuth against a self-managed instance additionally
  requires an OAuth application registered on that instance with redirect URI
  `http://localhost:7171/auth/redirect` — a token is the simpler route for a
  daemon.
- **The multi-host question is where `gh` and `glab` differ in a way that
  matters.** `gh` auth is host-scoped and ambient, which is why TBD can run any
  `gh` call from any checkout and rely on the auth being right
  (`PRStatusManager.swift:434-438`). Whether `glab` holds credentials for several
  hosts simultaneously and picks per-repo, or whether `GITLAB_HOST` must be set
  per invocation, is **not clearly documented** and would need testing. If it is
  the latter, `refreshBindingGroup`'s existing per-`(host, owner, repo)` grouping
  (`:792-809`) is already the right shape to carry a `--hostname` per group —
  the code comment at `:818-820` anticipates exactly this.

**Is shelling out still the right move?** Three considerations, none of them
decided here:

- **For.** It reuses the one existing subprocess seam (`GHRunner`,
  `PRStatusManager.swift:129-131`); it inherits the user's existing auth without
  TBD ever holding a token; and it keeps TBD out of the credential-storage
  business entirely, which is a real ongoing cost avoided.
- **Against.** `glab` is one more binary a user must install and authenticate
  before anything works, and unlike `gh` its absence is invisible until a
  binding silently never forms. GitLab's REST API is a plain HTTPS call with a
  `PRIVATE-TOKEN` header — meaningfully simpler to speak directly than GitHub's,
  and TBD already has a NIO stack.
- **The token question is genuinely different.** GitLab PATs are per-instance
  and scoped; a direct-HTTP design would have to store one per host somewhere,
  which is a new class of secret in TBD (there is precedent in the ModelProfile
  keychain path, but PR polling has never held a credential).

## Part 7 — Discovery paths

TBD binds a PR three ways
(`docs/specs/2026-08-10-multi-pr-per-worktree-design.md`, "Discovery: three
sources"). Each has a GitLab counterpart, and one has a gap with no counterpart
at all.

**Hook binding — has a counterpart, needs a second gate.** The `PostToolUse`
`Bash` hook's authoritative gate demands the command word `gh` and the
subcommand path `["pr", "create"]`
(`PRBindingExtractor.swift:210-224`). The GitLab equivalent is `glab` with
`["mr", "create"]`, and the value-taking global flags differ (`glab` uses
`--hostname` and `-R/--repo` too, but the set should be re-derived from `glab`'s
own flags rather than assumed identical). The prefilter grep
(`ClaudeHookOverlay.swift:182`) matches `pr…create` and would drop every
`glab mr create` payload before the tokenizer ever ran — the exact failure mode
that comment warns about at `:144-148`. A second alternation is needed, and the
same "prefilter is a cost optimisation, never a gate" discipline applies.

Whether `glab mr create` prints the created MR's URL to stdout — which is what
makes the GitHub hook work — is **unverified**; the manpage documents no output
format and no JSON option.

**A discovery path with no GitHub analogue, and no hook counterpart.** GitLab
lets a plain `git push` create a merge request via push options:
`git push -u origin -o merge_request.create`, plus `merge_request.target=` and
related options. The tool call an agent makes is `git push` — so the hook's
command gate rejects it, correctly, and no `glab` ever runs. The MR gets created
and TBD never sees it. Branch matching would still find it on the next poll,
which is the safety net, but the *headline* case the hook exists for — a
subagent's MR on a branch the worktree never checked out — is not recoverable
this way. The push output does carry a URL, but GitLab's own issue tracker
records that the URL echoed by a push is the "create a merge request" form URL
rather than the created MR
([issue 441944](https://gitlab.com/gitlab-org/gitlab/-/issues/441944)); the
exact string emitted after a successful `merge_request.create` push is
**unverified**.

**Branch matching — has a counterpart, and a better one.** TBD matches a
worktree's branch candidates against the viewer's authored PRs
(`matchUnnumbered`, `PRStatusManager.swift:1660-1676`), scoped to the worktree's
own repo, from a single cross-repo `viewer { pullRequests(first: 100) }` batch
(`:2122-2132`). GitLab offers two shapes:

- **Repo-scoped, which is what TBD actually wants** —
  `project(fullPath:) { mergeRequests(sourceBranches: [...]) }`. This asks the
  question directly instead of fetching 100 PRs and filtering. It also removes
  the 100-PR truncation that motivates `cachedNumberFallback` (`:1574-1597`),
  though it costs one call per project rather than one call total.
- **Viewer-scoped, cross-project** — REST
  `GET /merge_requests?scope=created_by_me&state=all`, which returns merge
  requests across all accessible projects. The GraphQL root equivalent,
  `Query.mergeRequests`, exists but is marked `experiment: { milestone: '19.3' }`
  with `max_page_size: 20` and "At least one filter must be provided"
  ([`query_type.rb`](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/graphql/types/query_type.rb))
  — too new and too small a page to be the substrate a fleet poll rests on.

The `batchSucceeded` predicate is load-bearing across both heals
(`:1604`, `:1796`) and the observation vocabulary (`:670-673`): it distinguishes
"the forge answered and there is no PR" from "we could not ask". A repo-scoped
matcher changes what that predicate ranges over — per project rather than
globally — which is a behaviour change in the heals, not just a query swap.

**Manual attach — has a counterpart.** `tbd pr attach <number|url>` needs the URL
regex generalised and `RPCRouter.prRef` (`RPCRouter.swift:1255-1260`) taught to
synthesise the right URL shape for the worktree's forge. The bare-number form is
where the forge must already be known, since the URL is constructed rather than
parsed.

**Provenance seeding — has a counterpart, with a caveat.**
`seedProvenanceBindings` (`RPCRouter.swift:791-803`) turns `Worktree.prNumber`
into a binding through the same `prRef`. `Worktree.prNumber` is documented as a
GitHub PR number (`Models.swift:229`) and is fed by the branch picker's
`repo.listOpenPRs` flow (`PRStatusManager.fetchOpenPRs`, `:1938-1967`), which is
itself a GitHub-shaped GraphQL query including `isCrossRepository` and
`headRepositoryOwner { login }`. Fork PRs are the case that makes the number
load-bearing; GitLab's equivalent is a fork MR whose `sourceProject` differs
from the target, so the concept survives but the field names do not.

## Part 8 — Terminology

GitLab calls them merge requests, and the acronym differs in every surface
listed in [UI copy and the CLI](#ui-copy-and-the-cli) — roughly two dozen
strings, plus the `tbd pr` command name itself, the `pr.*` RPC method names, the
`worktree_pull_request` table, the `PRBinding`/`PRStatus` type names and the
`tbd` skill entry.

The options, without choosing:

- **Keep "PR" everywhere** and treat it as TBD's own generic term. Zero churn,
  zero migration, and wrong-sounding to a GitLab user reading their own toolbar.
- **Per-forge copy** — the label follows the binding's host, so a GitLab
  worktree shows `!412` (GitLab's own sigil for a merge request) and "2 MRs".
  Correct-looking, but the toolbar and the sidebar summarise *several* bindings
  under one label, and a worktree could in principle hold both — so the
  summarising surfaces need a fallback term anyway.
- **A neutral term** — "change", "review", "request". Correct on both, familiar
  on neither, and it means renaming surfaces that GitHub users already read
  fluently.

The command name is the sharpest instance: `tbd pr attach` is documented in the
`tbd` skill (`TBDSkillContent.swift:187-189`) and is therefore something agents
have been told to type. An alias is cheap; a rename is not.

Note that the internal vocabulary is already partly neutral —
`PRUndeterminedCause` says "forge", not "GitHub"
(`PRStatusManager.swift:13-34`) — so there is precedent for the neutral
direction in the layer users do not see.

## What could not be verified

Stated plainly rather than asserted anywhere above:

- **Whether `glab mr create` prints the created merge request's URL to stdout.**
  `glab` is not installed here, and its manpage documents no output format. The
  entire hook-binding path depends on this.
- **The exact remote message after `git push -o merge_request.create`,** and
  whether it contains the created MR's URL or only the "new merge request" form
  URL. GitLab's docs page for push options redirected to an authentication gate
  and could not be read.
- **How GitLab scores GraphQL complexity for connections and for
  `calls_gitaly: true` fields.** The 250 ceiling is documented; the arithmetic
  that consumes it is not. This decides whether a 20-MR batch fits.
- **Whether the GraphQL `detailedMergeStatus` is computed on read or is as lazy
  as REST's `merge_status`.** The REST laziness is documented; the GraphQL
  behaviour is not.
- **How EE-only fields behave on a Free instance.** `approvalsLeft`,
  `approvalsRequired`, `approvalState`, `mergeTrainCar` and `changeRequesters`
  are declared in `ee/`. Whether they are absent from the schema (query error) or
  present-and-null (graceful) on a Free self-managed instance was not tested, and
  a query that errors wholesale on one instance shape is a real failure mode.
- **Whether GitLab project paths are case-insensitive.** TBD lowercases owner and
  repo on write and on comparison specifically because GitHub is
  (`PRBindingStore.swift:29-31`, `PRBinding.swift:96-99`). GitLab has a
  long-standing open issue titled "Make project paths case-insensitive on
  database level", which suggests they are not — but the evidence found was
  mostly about GitLab Pages, not project lookup, so this is unresolved.
- **Whether `glab` can hold credentials for several hosts at once and select
  per-repo,** or whether `GITLAB_HOST` must be set per invocation.
- **The `detailed_merge_status` value count.** The enum source was read twice;
  one read reported "24 values" and one "21", while both listings enumerated the
  same 22 entries. The values themselves agreed exactly across both reads and are
  what Part 3 rests on, but the count should be re-derived before anything
  exhaustive is built on it.
- **Nothing was run against a live GitLab instance.** No latency figure, no
  measured complexity score, no observed response body for a merge request.

## Open questions for the design session

**1. Is the target GitLab, or is it "a second forge"?**
The two produce different architectures. A GitLab-specific path can hardcode
`glab` and GitLab's shapes throughout. A forge abstraction — a protocol behind
which GitHub and GitLab are two conformances — costs more now and is the only
thing that makes GitHub Enterprise, Gitea or Forgejo cheap later. *Evidence
bearing on it:* there is exactly one forge subprocess call site
(`PRStatusManager.swift:2196`) and one injected seam (`:129-131`), so the
abstraction is unusually cheap to introduce; but `PRStatusManager` is a
2,293-line actor whose heal logic is deeply entangled with GitHub's viewer-batch
shape, and the abstraction boundary would have to cut through it.

**2. Should GitHub Enterprise land first?**
GHE needs the URL regex generalised, the `host` column threaded through, and
`--hostname` passed to `gh` — and nothing else, because the schema and the state
model are identical. It would validate the host plumbing GitLab also needs, on a
change small enough to review in one sitting. *Against:* it is a detour if
nobody needs GHE, and shipping host-awareness without a second data model may
bake in assumptions that GitLab then has to unpick.

**3. How does TBD learn a repo's forge?**
The five options are laid out in [Part 5](#part-5--identifying-the-host). The
fork is essentially *ask the user* versus *probe the network*. *Evidence
bearing on it:* `glab` itself does not probe, and the repo's own doctrine
("compile only what user-land cannot do well") points at a declaration the user
edits rather than an inference the daemon computes. Against that: a fleet of 40
worktrees across many repos makes a per-repo setup step real friction, and a
wrong or absent declaration fails silently — no binding ever forms, which is
exactly the symptom that prompted this research.

**4. What is a repository's identity, now that it is not `(owner, repo)`?**
GitLab projects nest up to 20 levels. The choices are: keep two columns and
stuff the whole namespace into `owner` (works, but `owner` stops meaning owner,
and every log line and error message that renders `owner/name` becomes
misleading); add a `fullPath` column and treat `owner`/`repo` as a GitHub-only
projection; or migrate to a single path column for both forges. *Evidence
bearing on it:* the identity reaches a unique DB index
(`Database.swift:1273-1277`), a `\u{1}`-delimited four-part key
(`PRBinding.swift:97-99`) parsed back on exactly four parts
(`PRBindingStore.swift:257-264`), the cross-repo heal
(`PRStatusManager.swift:1691-1706`) and the wrong-repo rejection
(`PRBindingCoordinator.swift:81-85`). A migration touching the unique index is
the most invasive part of any GitLab work.

**5. Does `PRMergeableState` grow, and does `attentionSeverity` change?**
GitLab has blockers TBD flattens into `.blocked` at severity 5 — including
`MERGE_TIME`, which demands nothing, and `DISCUSSIONS_NOT_RESOLVED`, which
arguably demands more than a failing check. *Evidence bearing on it:* the
ordering is defined once (`PRBinding.swift:114-124`) and read by the toolbar,
the sidebar and the `Worktree.prStatus` column, which the design explicitly
requires not to disagree; and `attentionSeverity` also drives `worst(of:)`
(`:130-139`), so any new tier changes which PR a multi-PR worktree's single icon
represents — on GitHub too, not only on GitLab.

**6. What does a red dot mean on GitLab, given there are no required checks?**
`.checksFailed` currently fires only on a failing *required* check
(`PRStatusManager.swift:1250-1256`), and TBD deliberately does not colour on
non-required failures (`:1162-1164`, `:1244-1249`). On GitLab the available
facts are `detailedMergeStatus = CI_MUST_PASS` (the pipeline is a merge
blocker) and `headPipeline.status = FAILED` (the pipeline failed, blocker or
not). Treating only the first as red preserves today's meaning; treating the
second as red is what most GitLab users would expect from their own UI. These
diverge exactly on projects that do not require pipelines to pass.

**7. What stands in for `reviewDecision`?**
`NOT_APPROVED` conflates "nobody has approved yet" with "a reviewer objected",
and TBD currently treats the former as `.mergeable`
(`PRStatusManager.swift:1166-1167`) and the latter as `.changesRequested` at a
higher severity. Distinguishing them on GitLab needs either the EE-only
`changeRequesters` field or a per-reviewer `reviewState` scan. *The fork:* accept
that GitLab Free cannot express `.changesRequested` at all, or query paid-tier
fields and degrade when they are unavailable — which requires knowing how those
fields behave on a Free instance, listed above as unverified.

**8. `glab` subprocess, or direct HTTPS?**
Laid out in [Part 6](#part-6--the-cli-and-auth-story). The fork is really about
where the credential lives: `glab` means TBD never holds a token; direct HTTPS
means TBD must store one per host. *Evidence bearing on it:* `glab api graphql
-f query=` is close enough to `gh api graphql -f query=` that the subprocess
route is nearly free to build; but a missing or unauthenticated `glab` fails the
same silent way a missing forge declaration does, and TBD has no surface today
that tells a user "your PRs are not updating because a CLI is missing" —
`PRUndeterminedCause.cliUnavailable` exists (`:15`) but only reaches a tooltip.

**9. Does the hook gain a `glab mr create` arm, and what covers push-created
MRs?**
Adding the arm is mechanical. The gap is `git push -o merge_request.create`,
which no hook gate can admit without admitting every `git push`. *The fork:*
accept that push-created MRs are found only by branch matching (which cannot see
a subagent's branch — the case the hook exists for), or find a different signal.
*Evidence bearing on it:* a false bind can auto-archive a worktree, which is why
the gate fails closed (`PRBindingExtractor.swift:64-79`), so widening it to
`git push` is not a small trade.

**10. Terminology: "PR", "MR", per-forge, or neutral?**
Laid out in [Part 8](#part-8--terminology). *Evidence bearing on it:* the
`tbd pr` command name is documented in the `tbd` skill
(`TBDSkillContent.swift:187-189`) so agents have been instructed to type it; the
toolbar and sidebar summarise several bindings under one label and therefore
need a term that works when a worktree spans forges; and the daemon's internal
vocabulary already says "forge" rather than "GitHub"
(`PRStatusManager.swift:13-34`), so the neutral direction has precedent in the
layer users do not read.

**11. Does the 20-binding cap still make sense?**
It exists to bound per-poll GraphQL cost (`PRBindingStore.swift:87-90`), and on
GitLab that cost is a single `iids: [...]` argument rather than 20 aliases — so
the justification weakens considerably. *Evidence bearing on it:* whether it
weakens or vanishes depends on GitLab's connection complexity arithmetic, which
is unverified. If a connection costs per-node, the cap matters more on GitLab,
not less.
