# GitLab support for PR binding

TBD's pull-request subsystem tracks GitHub only, and not by configuration —
by construction. This design adds GitLab as a second forge without a database
migration, a configuration column, or a feature flag, and without changing any
behaviour on the GitHub path.

Research backing every measured claim here:
[`docs/research/2026-08-16-gitlab-pr-support/findings.md`](../research/2026-08-16-gitlab-pr-support/findings.md).

## The problem

`PRBindingExtractor`'s URL pattern is host-locked to `https://github.com/`
(`Sources/TBDShared/PRBindingExtractor.swift:32-33`), and every discovered
binding is stamped `host: "github.com"` (`:239`). All three discovery
paths — the `PostToolUse:Bash` hook, branch matching, and manual attach — funnel
through that pattern, so on a non-GitHub worktree no binding can ever form. The
status-bar chip a user sees there is synthetic, and the URL that chip carries is
rejected by the daemon if they try to act on it.

The groundwork for fixing this was laid deliberately. The `host` column on
`worktree_pull_request` already exists, and the extractor's own comment
(`:29-31`) states the intent: "the binding's `host` column exists so enterprise
support is a later additive change."

## Scope

In scope: GitLab merge requests appear as bindings, poll for status, colour the
toolbar and sidebar, and participate in the merged-transition machinery exactly
as GitHub pull requests do.

Not in scope: GitHub Enterprise (the plumbing here makes it small, but it is a
separate change), Gitea and Forgejo, GitLab write actions beyond what already
exists, and merge-train position parity with GitHub's merge queue.

## Forge identification

**Two mechanisms, because the two discovery shapes need different things.**

URL-shaped discovery needs no host knowledge at all. GitLab merge-request URLs
contain the path segment `/-/merge_requests/<n>`, which no other forge uses, so
the URL identifies its own forge. `PRBindingExtractor` gains a second pattern
alongside the GitHub one:

- The GitHub pattern is unchanged, byte for byte. Its fail-closed reasoning
  (`:64-79`) — a false bind can auto-archive a worktree, so ambiguity must lose
  binds rather than invent them — is preserved by not touching it.
- The GitLab pattern anchors on the literal `/-/merge_requests/`, captures
  everything before it as the project path, and applies the same
  `(?!\.{1,2}/)` lookahead to every path segment that the GitHub pattern applies
  to two.
- The host is taken from the matched URL rather than stamped as a literal.

Repo-shaped discovery — branch matching, which starts from a worktree and its
remote rather than from a URL — does need to know the forge. It derives it from
`glab auth status`, whose output enumerates the hosts `glab` is configured for
and whether each authenticates.

**Why derive from `glab` rather than declare or probe.** A host appears in that
list only because someone ran `glab auth login --hostname <host>`, and that same
act is what makes every subsequent API call succeed. Declaration and capability
become one precondition, so TBD can never reach the state "I know this is GitLab
but I cannot talk to it" — the state every other option permits, and the one
whose symptom (no binding ever forms, silently) is the bug being fixed. It also
needs no configuration column and therefore no migration.

Three constraints on the derivation:

- **Parse the output, never the exit status.** `glab auth status` exits `0` while
  reporting that it could not authenticate to any configured instance.
- **`gitlab.com` appears in the list even with no credentials**, so its presence
  proves nothing. Only a non-default host is evidence.
- **Attempt it only when the remote host is not `github.com`.** A GitHub-only
  fleet then spawns no `glab` subprocess at all, so the common case pays
  nothing.

The derived host set is cached in memory for the daemon run. Nothing is
persisted, so nothing needs invalidating, and no clock seam is required.

`RemoteRepoMatching` deliberately discards the host when normalising remotes and
documents the resulting collision — "a self-hosted GitLab mirror of a GitHub
repo" — as accepted (`Sources/TBDShared/RemoteRepoMatching.swift:17-23`). That
stays as it is; this design does not route forge identity through remote
matching.

## The typed seam

GitHub's data model reaches only one file. All 51 uses of `mergeStateStatus`,
`reviewDecision` and `statusCheckRollupState` live in
`Sources/TBDDaemon/PR/PRStatusManager.swift`; every other hit in `Sources/` is a
comment. Inside that file the two verdict fields are **carried, never
interpreted**, except in one function: they flow from `prNode` (`:1862-1892`)
through the `PRNode` struct to `mapStateAndReason` (`:1862-1886`, `:1141-1178`). The heal logic
that matches, poisons cache entries and verifies head refs branches only on
`state` and `statusCheckRollupState`.

That makes `PRNode` the seam, and the change to it small:

- `PRNode` gains `forge: Forge`, declared last and defaulted to `.github` so the
  memberwise initialiser stays source-compatible. This is the same technique
  `baseRefName` already uses and documents (`:1536-1540`).
- Its two verdict fields are renamed `mergeVerdictRaw` and `reviewVerdictRaw`.
  They hold whatever vocabulary their forge speaks, and the neutral names stop
  a GitLab value from sitting in a field called `mergeStateStatus`. The rename is
  confined to one file.
- `mapStateAndReason` takes the forge and dispatches. The `.github` arm is
  today's switch verbatim, so GitHub's mapping is unchanged because its code is
  unchanged.
- A `GLRunner` seam mirrors `GHRunner` (`:131`, `:145`) for test injection, and
  the GitLab subprocess call site mirrors `runGHResult` (`:2196`).

`Forge` is a two-case enum in `TBDShared`. It is derived at parse time and
carried on the node; it is never stored.

## GitLab I/O

**GraphQL, with a field set chosen to be available everywhere.** One batched
query per project replaces both of GitHub's calls, because GitLab's
`mergeRequests(iids: [String])` is a single field carrying pipeline status
inline — where GitHub needs a per-PR check query for the same fact. Measured
cost is roughly five to six round trips per poll pass against eleven to
fifty-one today, and GraphQL complexity is scored per query-AST field rather
than multiplied by page size, so a hundred nodes of eleven fields passes even
the lower unauthenticated ceiling.

The tier-1 field set is `iid`, `state`, `draft`, `detailedMergeStatus`,
`conflicts`, `sourceBranch`, `targetBranch`, `createdAt`, `webUrl`, and
`headPipeline { status }`. Every one of these is Free-tier and predates any
instance likely to be in service.

**No paid-tier fields are requested.** GraphQL rejects an entire query for one
unknown field, returning `"data": null` — on a hundred-node batch that turns a
single schema mismatch into zero merge requests. Requesting only fields that
exist everywhere makes that failure unreachable rather than recoverable, which
is why there is no schema-capability cache in this design, and nothing for a
reconciler to refresh. Adding a paid-tier field later is what would introduce
that machinery, and the mechanism is already known: an unknown field returns a
machine-readable `extensions.code: "undefinedField"` naming the offending field,
supporting a retry-lean-and-remember fallback that costs nothing on the happy
path.

**Branch matching queries the server, not the viewer.** GitHub forces TBD to
fetch the authenticated user's own pull requests and match branches locally,
which is why a merge request opened by anyone else is invisible to branch
matching. GitLab accepts `mergeRequests(sourceBranches: [...])` with no author
filter, so TBD asks for exactly the branches its worktrees are on and gets back
matching merge requests regardless of who opened them — including ones created
through the web UI or by `git push -o merge_request.create`.

## Project identity

A GitLab namespace nests up to twenty levels, so a project path is
`acme/platform/backend/api-gateway` rather than `owner/name`. The two existing
columns hold it unchanged, reframed as namespace and project: the namespace path
goes in `owner`, the project name in `repo`. GitHub's `owner` is simply a
one-segment namespace, so the concept is already shared; only the column's name
is narrower than what it holds, and that is documented at the declaration site.

Nothing in the identity plumbing constrains the format. `identityKey` joins on
`\u{1}` (`Sources/TBDShared/PRBinding.swift:98`), the parse back requires only
four parts (`Sources/TBDDaemon/Database/PRBindingStore.swift:260-261`), and the
unique index imposes no shape (`Sources/TBDDaemon/Database/Database.swift:1273-1277`).
A namespace containing slashes survives all three.

Identity comparison already lowercases, justified by GitHub treating owner and
repo case-insensitively. GitLab does the same: `GitLab-Org/GitLab` and
`gitlab-org/gitlab` both resolve to one project. The existing rule needs no
change.

`parseOwnerRepo` (`Sources/TBDDaemon/PR/PRStatusManager.swift:1340-1346`) is the
only place that assumes a URL *shape*, requiring `parts[2] == "pull"`. It gains
a GitLab branch that splits the path on the `/-/` separator: everything left of
it is the project path, so no segment counting is needed and nesting depth is
irrelevant.

## Attaching by bare number

`tbd pr attach <number>` does not carry a URL, so the daemon builds one. That
path is GitHub-only in two ways at once: it stamps `host: "github.com"` and
composes a `/pull/` URL from the worktree's owner and name
(`Sources/TBDDaemon/Server/RPCRouter.swift:1255-1260`). On a GitLab worktree it
would fabricate a GitHub URL for a merge request that does not exist there,
which is worse than refusing, because the resulting binding looks valid.

Composing the URL requires the forge, and this is the one user-facing path that
depends on the repo-shaped derivation rather than on a URL that identifies
itself. So the repo resolver returns the host alongside the owner and name, and
the URL shape is chosen from the forge: `/pull/<n>` for GitHub,
`/-/merge_requests/<n>` for GitLab. When the forge cannot be determined the call
returns nil, which the existing contract already handles — the caller defers
rather than guessing, exactly as it does today when the repo cannot be named.

The related synthetic binding in
`Sources/TBDApp/PRBindingPresentation.swift:71-81` constructs a placeholder with
empty owner and repo, so it silently takes `PRBinding`'s `host` default of
`github.com`. Its URL comes from the observed status and is therefore correct,
but the host field is not; it is set from the status URL's own host so that no
part of a rendered binding disagrees with the others.

## State mapping

GitLab's states map into the existing eight `PRMergeableState` cases.
`PRMergeableState` does not grow and `attentionSeverity` is untouched, so
`worst(of:)` — which decides which binding a multi-PR worktree's single icon
represents — behaves identically for existing fleets. Precision that the eight
cases cannot express is carried in `PRStatus.reason`, which the tooltip and
sidebar already render, so a coarse icon can still be explained in words.

The mapping is derived from a position TBD already holds rather than invented for
GitLab. At `PRStatusManager.swift:1166`, a GitHub pull request that is `BLOCKED`
solely by an ungiven review maps to `.mergeable`, "Ready to merge", commented as
deliberate: checks are settled, and awaiting a review nobody has performed is not
something demanding the author's attention.

- `MERGEABLE` maps to `.mergeable`.
- `NOT_APPROVED` maps to `.mergeable`, "Ready to merge". It is the precise
  analogue of GitHub's `BLOCKED` plus `REVIEW_REQUIRED`. This matters in
  practice: of six open merge requests sampled live, three reported
  `NOT_APPROVED`, so mapping it to `.blocked` would paint most of a healthy
  GitLab fleet as needing attention.
- `DISCUSSIONS_NOT_RESOLVED` maps to `.changesRequested`, "Unresolved
  discussions". A human is waiting on the author, which is what that state
  already means. Two of the same six merge requests reported it.
- `REQUESTED_CHANGES` maps to `.changesRequested`. GitLab carries this as a
  dedicated `detailedMergeStatus` value, so no per-reviewer scan and no
  paid-tier field is needed to express it.
- `DRAFT_STATUS`, and the `draft` boolean, map to `.draft`.
- `CHECKING`, `UNCHECKED` and `PREPARING` map to `.pending`.
- `CONFLICT` maps to `.blocked`, "Merge conflicts"; `NEED_REBASE` to `.blocked`,
  "Behind base branch"; `BLOCKED_STATUS` to `.blocked`, "Blocked by another
  merge request".
- `NOT_OPEN` defers to `state`, which distinguishes merged from closed.
- **Any value not listed maps to `.pending`, not `.blocked`.** GitLab's
  `DetailedMergeStatus` demonstrably grows — twenty-four values are live against
  twenty-two in the source tree at `master` — so treating unknown as blocked
  would make future GitLab releases silently paint merge requests as needing
  attention. Unknown means unknown. This is the one place the GitLab arm
  deliberately differs from the GitHub arm's `default: return (.blocked,
  "Blocked")` (`:1175`).

## Terminology

The command name, the database tables, the daemon's internal vocabulary and any
label summarising several bindings keep saying "PR". Only user-facing text
describing one specific binding whose forge is known renders "MR".

`tbd pr` is documented to agents in the `tbd` skill
(`Sources/TBDShared/TBDSkillContent.swift:187-189`), so agents have been
instructed to type it; renaming it would break instructions already in the field
and the tests that pin those substrings. Aggregate labels need a word that works
when a worktree spans forges, and "PR" is the one already in place. The daemon's
own vocabulary is already forge-neutral where it matters — `PRUndeterminedCause`
speaks of a forge rather than of GitHub (`PRStatusManager.swift:13-34`).

## Decisions this design defers

Two questions are answerable by a GitLab user's report rather than by reasoning,
and the design records both branches with the fact that selects each. Neither
blocks the rest of the work.

**What makes a GitLab chip red.** `.checksFailed` currently fires only on a
failing *required* check, and TBD deliberately does not colour on non-required
failures (`PRStatusManager.swift:1244-1256`). GitLab has no "required check"
concept; its analogue is `detailedMergeStatus == CI_MUST_PASS`, meaning the
pipeline blocks the merge. The strict analogue therefore colours red only when
the pipeline both blocks merge and failed, which preserves today's meaning
exactly — a failed non-blocking pipeline on GitLab is the same situation as
GitHub's `UNSTABLE`, which TBD already shows as not red. The alternative colours
red on any `headPipeline.status == FAILED`, which is what a GitLab user's own web
UI leads them to expect. *Selecting fact:* whether the instance in question gates
merges on pipelines. If it does, the two branches never diverge.

**Whether the hook gains a `glab mr create` arm.** Adding it is mechanical, and
cleaner than the GitHub side because under a non-TTY `Bash` call `glab mr create`
emits a bare web URL. Because GitLab branch matching is author-blind, merge
requests created outside the hook's view are already discovered, so the arm is a
latency improvement rather than the only route — which is the opposite of its
role on GitHub. *Selecting fact:* how merge requests are actually created in
practice. Widening the gate to bare `git push` is not on the table: the gate
fails closed because a false bind can auto-archive a worktree.

## Testing

The forge switch is a conditional that gates behaviour, so each branch is
tested.

- Both `mapStateAndReason` arms: every listed GitLab value to its expected
  state and reason, an unrecognised value to `.pending`, and the existing GitHub
  cases still passing unchanged.
- `PRBindingExtractor` accepting GitLab merge-request URLs, including a deeply
  nested namespace, and rejecting near-misses — a `merge_requests` path without
  the `/-/` separator, and `.`/`..` path segments — so the fail-closed property
  holds on the new pattern too.
- Identity round-trip: a binding whose namespace contains slashes survives
  `identityKey`, the four-part parse, and the unique index without collapsing
  into a different binding.
- `glab auth status` parsing: a host list with one authenticated and one
  unauthenticated host, a run that reports failure while exiting `0`, and absent
  or unconfigured `glab`.
- Forge derivation is not attempted for a GitHub remote, asserted by an injected
  `GLRunner` that fails the test if invoked.
- GitLab node parsing, including an absent `headPipeline`.
- Attach by bare number composes a `/-/merge_requests/<n>` URL with the GitLab
  host on a GitLab worktree, still composes `/pull/<n>` on a GitHub one, and
  returns nil rather than guessing when the forge is undetermined.

## Rules this design answers

**No feature flag.** The relevant criteria are behaviour that acts without a user
gesture, destroys or mutates persisted state, or wholesale-replaces a
load-bearing path. This is additive and unreachable for any host that is not
GitLab: a GitHub-only fleet spawns no new subprocess, takes the unchanged
`.github` arm, and sees no new state. The one edit that touches shared code — the
`PRNode` field rename and the `mapStateAndReason` signature — is a refactor whose
GitHub arm is unchanged, and is covered by the existing suite.

**No new reconciler.** No durable external resource is created. `glab`
subprocesses are transient in exactly the way `gh`'s already are, no git ref,
worktree, tmux entity, or file outlives the request that created it, and no new
row is written that an existing sweep does not already cover.

**No migration.** No column is added or changed, so the migration-plus-record-
plus-model rule has nothing to apply to.

## Rejected alternatives

**Translating GitLab into GitHub's vocabulary.** The GitLab parser could
synthesize `mergeStateStatus: "BLOCKED"` and similar, leaving everything
downstream untouched for the smallest possible diff. Rejected because it is
lossy exactly where GitLab is most informative: `DISCUSSIONS_NOT_RESOLVED` has no
GitHub equivalent, so it either collapses to "Blocked" and discards the only
useful part, or invents a string that falls into the GitHub arm's
`default: .blocked`. Every diagnostic about a GitLab merge request would also
speak GitHub.

**A full `ForgeClient` protocol.** Extracting query construction, subprocess
invocation, parsing and mapping into per-forge conformances is the right
long-term shape and is where the surveyed prior art lands. Rejected for now
because it cuts a new boundary through a 2,293-line actor to serve one known
user, and puts the working GitHub path on the far side of that cut. The `forge`
discriminator introduced here is the same seam such a protocol would need, so
this remains a refactor later rather than a rewrite.

**A `forge` configuration column.** An explicit per-repo declaration is
inspectable and matches the project's preference for behaviour that lives in
user-land. Rejected because it can be set correctly and still not work — a repo
declared as GitLab with an unauthenticated `glab` produces no bindings, silently,
which is the exact failure this work exists to remove — and because it costs a
migration that deriving from `glab` does not.

**Probing `/api/v4/version` per host.** Measured to discriminate cleanly: GitLab
answers `401` where four non-GitLab hosts, including another forge, answer `404`,
with no false positive. Rejected because it makes a background daemon send
unsolicited requests to arbitrary domains read out of a user's git config, and
because `401` cannot distinguish a GitLab instance the user can reach from one
they cannot.

**A hostname heuristic**, treating any host containing `gitlab` as GitLab.
Rejected because it is wrong precisely in the self-hosted case that motivates
this work, and wrong in the silent direction.

**REST instead of GraphQL.** REST is the worn path — the surveyed tools and
GitLab's own Go SDK all use it — and it tolerates instance variation by omitting
unknown fields rather than failing the whole request. Rejected because its
`iids[]` batch omits pipeline status, forcing one additional call per merge
request per poll pass, and because confining the query to fields available on
every edition removes the failure mode REST's tolerance protects against.

**Growing `PRMergeableState`.** Dedicated cases for GitLab's distinct states
would be more faithful to what GitLab reports. Rejected because every new tier
reshuffles `attentionSeverity`, which the toolbar, the sidebar and the
`Worktree.prStatus` column all read and must not disagree about, changing which
binding a multi-PR worktree's icon represents on GitHub as well. Carrying the
detail in `PRStatus.reason` gets the precision without touching the ordering.
