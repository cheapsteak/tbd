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
binding is stamped `host: "github.com"` (`:239`). The three discovery
paths that start from a URL — the `PostToolUse:Bash` hook, branch matching, and
`tbd pr attach <url>` — funnel through that pattern, so on a non-GitHub worktree
no binding forms from a URL at all. The status-bar chip a user sees there is
synthetic, and the URL that chip carries is rejected by the daemon if they try to
act on it. The fourth path, `tbd pr attach <number>`, does form a binding
anywhere, because it composes its own URL — but it composes a github.com one for
every host, so on a non-GitHub worktree it yields a binding that points at a
repository which is not the user's.

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

**Neither mechanism reads the hostname's shape, and nothing else may either.**
"Not github.com" describes GitHub Enterprise, Bitbucket, Gitea and Codeberg as
readily as it describes a self-managed GitLab, and all of them serve `/pull/<n>`,
so a host-keyed classifier is wrong for every non-GitLab fleet off github.com —
it would label their pull requests "MR" and compose merge-request URLs that
404. `Forge` therefore offers exactly one classifier, `Forge.forURL`, keyed on
the `/-/merge_requests/` marker the extractor already anchors on, and every
per-binding label reads the binding's own `url` through it. Where no URL exists
yet the forge is established rather than classified — see "Attaching by bare
number".

**Why derive from `glab` rather than declare or probe.** A host appears in that
list only because someone ran `glab auth login --hostname <host>`, and that same
act is what makes every subsequent API call succeed. Declaration and capability
become one precondition, so TBD can never reach the state "I know this is GitLab
but I cannot talk to it" — the state every other option permits, and the one
whose symptom (no binding ever forms, silently) is the bug being fixed. It also
needs no configuration column and therefore no migration.

**TBD reads the host list only, never the authentication verdict.** This
distinction carries the design. A host appears because someone declared it, and
that is the only fact being extracted. Whether credentials currently work is
proven by an API call succeeding, never by status text — which is measurably
unreliable: on a self-managed instance the block for a working host printed
`✓ Logged in to <host>` and `! Invalid token provided in configuration file`
together, while every REST and GraphQL call with that token succeeded.

Four constraints on the derivation:

- **Ignore the exit status entirely; parse the per-host blocks.** `glab auth
  status` exits `1` if *any* configured host fails to authenticate, so a
  perfectly working setup reports failure whenever an unused `gitlab.com` entry
  sits in the same config. The exit code is uninformative in both directions.
- **`gitlab.com` appears in the list even with no credentials**, so its presence
  proves nothing. Only a non-default host is evidence.
- **Attempt it only when the remote host is not `github.com`.** A GitHub-only
  fleet then spawns no `glab` subprocess at all, so the common case pays
  nothing.
- **Pass `--hostname` explicitly on every `glab` invocation.** Outside a
  repository directory `glab api` silently defaults to `gitlab.com`, so relying
  on ambient repo context would send a self-managed instance's queries to the
  public one.

**The derivation remembers three outcomes for three different spans, because
they are three different facts.** Nothing is persisted; all of it lives in
memory for the daemon run.

- **A non-empty derivation** — `glab` ran and named hosts — is kept for the
  resolver's life. It is a derived truth about a declaration the user made, and
  nothing invalidates a declaration.
- **`glab` failing to launch** is never remembered. It is not an observation
  that the fleet has no GitLab hosts, only a failure to ask: the binary is
  absent, or one exec failed transiently. Remembering it would mean a user who
  runs `glab auth login` after TBD started gets no GitLab support until the
  next restart, with no message anywhere. Retrying costs nothing in the case
  that dominates, because an absent `glab` resolves to a static nil path that
  spawns no subprocess at all.
- **`glab` running and naming no host** is remembered for a bounded window,
  `emptyStatusLifetime`, of 300 seconds. That one *is* an observation, and it is
  the steady state of every fleet with `glab` installed and no GitLab host
  configured — so re-deriving it per call means one `glab auth status`
  subprocess per worktree per poll tick, forever, for an answer that has not
  changed. It cannot be kept for the run either, since the same user is one
  `glab auth login --hostname …` away from making it wrong.

The window is bounded on the side that matters: the empty answer is at worst
300 seconds stale, never stale until restart. Its floor is the poll cadence —
`GitPollCadence.prInterval` is 30 s in the foreground and every distinct
worktree path on the tick asks — so even one interval collapses a fleet's worth
of spawns into one; its ceiling is how long a user who has just authenticated
waits. The wait is not merely cosmetic: for its duration the checkout is still
classified non-GitLab, so a stored merge-request number can be offered to gh's
by-number query, where a same-named GitHub repository may answer. Bounding it
to 300 seconds makes that self-healing rather than durable.

The window takes an injected **date** seam, `now: @Sendable () -> Date`, not a
clock. The timestamp is compared and never slept on, and the resolver schedules
nothing — `Duration` is behavior, `Date` is data. The comparison uses the
magnitude of the interval, so a wall clock that steps backwards re-derives
early rather than pinning the empty answer in place until the clock catches up.

None of this sits on a pure `github.com` fleet's path, which short-circuits
before any subprocess. It sits on a GitHub Enterprise, Bitbucket, Gitea or
Codeberg fleet's path, which is why the empty answer has to be cheap.

**Credential expiry is a reporting requirement, not a recovery one.** Tokens are
personal access tokens with an expiry and no refresh, so a host that worked
yesterday can start refusing today. When calls against a known GitLab host begin
failing on authentication, the failure names that host. It must not degrade into
"this is not a GitLab repo", because that is indistinguishable from the bug this
work exists to remove.

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
`headPipeline { status }`, plus one project-level field,
`onlyAllowMergeIfPipelineSucceeds`. Every one of these is Free-tier and predates
any instance likely to be in service. The project-level field is what makes a
faithful CI signal possible — see "State mapping".

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

**A REST call accompanies the GraphQL read, for one narrow purpose.** GitLab
computes mergeability asynchronously and does not recompute it on read, so a
merge request can report `UNCHECKED` indefinitely — 21 of 71 open merge requests
measured on a self-managed instance, including some open for months. GraphQL
offers no way to ask for a recomputation; both plausible argument spellings are
rejected as `argumentNotAccepted`. REST's list endpoint does, via
`with_merge_status_recheck=true`, and accepts it alongside `iids[]`.

So each poll pass issues one additional REST call per project, naming only the
merge requests TBD actually has bindings for, whose sole purpose is to request a
recomputation. Its response is discarded; the next GraphQL tick reads the
refreshed value. The cost is one call per project rather than per merge request,
and the scoping to bound merge requests matters — it queues background work on
someone else's server, so TBD asks about the handful it tracks rather than every
open merge request in the project.

This is not a fallback transport and does not reopen the transport decision. The
poll remains GraphQL; the REST call carries no data TBD reads.

**The recheck is detached, and single-flighted per project by
`GitLabRecheckGate`.** Nothing in the pass reads the recheck's answer, so
nothing in the pass may wait for it — and it is the call most likely to hang,
since its whole purpose is to queue work on someone else's server. Left
attached, one hung `glab` stalls PR polling for the entire fleet, because
`refreshBindings` walks its groups one at a time and `fetchAll` skips the next
poll while one is in flight. Detaching removes that stall and, unbounded, would
replace it with a subprocess leak: `runCLI` imposes no timeout and a detached
task inherits no cancellation, so a hung endpoint accumulates one `glab`, one
`Process` and its file descriptors per project per tick — around 288 of them
overnight at a five-minute cadence, and no reconciler covers a forge CLI
subprocess. `GitLabRecheckGate` is an actor holding the set of projects with a
recheck outstanding; a project with one in flight issues no second call, and
outstanding-forever is the intended reading of a hang — that project stops
asking until the process ends. Only non-terminal merge requests are named: a
merged or closed one has a mergeability nobody recomputes and nobody reads.

**Branch matching queries the server, not the viewer.** GitHub forces TBD to
fetch the authenticated user's own pull requests and match branches locally,
which is why a merge request opened by anyone else is invisible to branch
matching. GitLab accepts `mergeRequests(sourceBranches: [...])` with no author
filter, so TBD asks for exactly the branches its worktrees are on and gets back
matching merge requests regardless of who opened them — including ones created
through the web UI or by `git push -o merge_request.create`.

## Project identity

A GitLab namespace nests up to twenty levels, so a project path is
`acme/platform/backend/api-gateway` rather than `owner/name`. Nesting is the
common case rather than an edge case: of 100 projects sampled on a self-managed
instance, 72 had one intermediate subgroup and 7 had two, leaving 21 flat as the
minority. A design that treated `owner/name` as normal and nesting as an
exception would be calibrated backwards. The two existing columns hold it
unchanged, reframed as namespace and project: the namespace path
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

Composing the URL requires the forge, and this is the one user-facing path with
no URL to read it from. So the repo resolver returns the host alongside the
owner and name, and the daemon asks the host-list derivation directly —
`PRStatusManager.isGitLabHost`, answered by `GitLabHostResolver` in the
worktree's own directory, where `glab` reads its configuration. Only a host
named there gets `/-/merge_requests/<n>`; every other host gets `/pull/<n>`,
which is the shape github.com has always been given and the shape a GitHub
Enterprise, Bitbucket, Gitea or Codeberg checkout serves. github.com
short-circuits inside the resolver, so a GitHub-only fleet spawns nothing.

The answer is one declaration, so a fleet on which nobody has run
`glab auth login --hostname …` composes GitHub's shape — the same URL it
composed before GitLab existed here, on the worktree's own host rather than a
hardcoded github.com. When the repo itself cannot be named the call returns nil
and the caller defers rather than guessing, exactly as it does when a worktree
has no resolvable identity.

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

### The CI signal is separate from the merge status

`detailedMergeStatus` reports **one** blocker, chosen by a precedence GitLab
owns, and continuous-integration failure sits low in that order. Field
measurement makes this unmissable: across 71 open merge requests on a project
configured with `only_allow_merge_if_pipeline_succeeds`, 33 had a failing head
pipeline and **not one** reported `CI_MUST_PASS`. Approval, draft and
unchecked states masked every one of them.

Two consequences follow, and together they rule out reading CI state off
`detailedMergeStatus` at all. Colouring red only on `CI_MUST_PASS` would show red
essentially never on such an instance. Worse, combined with `NOT_APPROVED`
mapping to `.mergeable`, a merge request with a failing pipeline would render as
"Ready to merge".

So the GitLab arm takes the structure GitHub's arm already has: a CI signal
computed independently of the merge status, evaluated after draft and before the
merge-status switch, with one signal ranked above it — see "What outranks the CI
signal" below.

- The signal is **gated on the project's `onlyAllowMergeIfPipelineSucceeds`**,
  which is the faithful analogue of GitHub's "required check". A failing pipeline
  on a project that does not gate merges on pipelines is the same situation as
  GitHub's `UNSTABLE`, which TBD deliberately does not colour red.
- `FAILED` on a gating project yields `.checksFailed`; `RUNNING` and `PENDING`
  yield `.pending`.
- `MANUAL` yields `.pending`, "Pipeline awaiting manual action" — neither failing
  nor passing, and common enough to need its own wording (5 of the 71).
- A **null `headPipeline`** yields no CI signal at all, and the merge status
  decides. Very old merge requests have none.

Draft precedence is what makes this safe rather than noisy. Because `isDraft` is
evaluated first (`:1153`), a draft with a failing pipeline stays `.draft` — which
matters, since 15 of 17 drafts in the sample had failing pipelines. Work in
progress does not turn the fleet red.

- `MERGEABLE` maps to `.mergeable`.
- `NOT_APPROVED` maps to `.mergeable`, "Ready to merge". It is the precise
  analogue of GitHub's `BLOCKED` plus `REVIEW_REQUIRED`. This matters in
  practice: it is the single most common state observed in the field, so mapping
  it to `.blocked` would paint most of a healthy GitLab fleet as needing
  attention.
- `DISCUSSIONS_NOT_RESOLVED` maps to `.changesRequested`, "Unresolved
  discussions". A human is waiting on the author, which is what that state
  already means. Two of the same six merge requests reported it.
- `REQUESTED_CHANGES` maps to `.changesRequested`, and is the one value ranked
  above the CI signal. GitLab carries it as a dedicated `detailedMergeStatus`
  value, so no per-reviewer scan and no paid-tier field is needed to express it.
- `DRAFT_STATUS`, and the `draft` boolean, map to `.draft`.
- `CHECKING` and `PREPARING` map to `.pending`, "Checks pending". These are
  genuinely transient.
- `UNCHECKED` maps to `.pending` with the distinct reason **"Mergeability not
  checked"**, because it is *not* transient: GitLab computes mergeability
  asynchronously and leaves a stale merge request unchecked until something
  re-triggers it, so 21 of 71 sampled merge requests sat in it, some for
  months. The reason string must not imply the state is about to resolve. The
  recheck request described under "GitLab I/O" is what actually moves it.
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

### What outranks the CI signal

Exactly one merge-status value is evaluated ahead of the CI signal:
`REQUESTED_CHANGES`. So the full order is terminal, draft, explicit change
request, CI signal, merge-status switch — the GitHub arm's own order, where
`CHANGES_REQUESTED` likewise sits ahead of the required-check signals. A merge
request that a reviewer has explicitly rejected while its pipeline is also red
reports the rejection; read off the merge status instead, it would report only
the pipeline and the reviewer's decision would surface nowhere in the UI.

`DISCUSSIONS_NOT_RESOLVED` does **not** share that slot, and the two are
deliberately not lumped together. The rule is that an explicit change request
outranks CI and an unresolved thread does not. GitHub's arm privileges only the
explicit review decision, and an open discussion thread is not a rejection —
the author may have answered every comment and simply not clicked resolve — so
when a pipeline is failing too, the pipeline is the more actionable thing to
show.

Ranking a change request above a failing pipeline is a deliberate step *down* in
attention severity: `.changesRequested` is 4 and `.checksFailed` is 6, so a
merge request with both renders as the less severe of the two. That is already
the GitHub arm's behaviour, and the stance behind it is that an explicit human
rejection is the thing to tell the author about — the icon is a pointer to the
next action, not a maximum over everything wrong.

### Observed distribution

Every mapping choice above is calibrated against field measurement rather than
against the enum's shape: 71 open merge requests on one active project of a
self-managed GitLab instance that requires both passing pipelines and resolved
discussions.

| `detailedMergeStatus` | count |
|---|---|
| `NOT_APPROVED` | 26 |
| `UNCHECKED` | 21 |
| `DRAFT_STATUS` | 17 |
| `DISCUSSIONS_NOT_RESOLVED` | 3 |
| `NEED_REBASE` | 3 |
| `MERGEABLE` | 1 |

| `headPipeline.status` | count |
|---|---|
| `FAILED` | 33 |
| `SUCCESS` | 32 |
| `MANUAL` | 5 |
| null | 1 |

Three facts fall out of those two columns and none of them is visible from the
schema alone. `MERGEABLE` is rare, so any design that treats it as the normal
case is calibrated wrong. The states TBD renders most often are precisely the two
with no GitHub equivalent, `NOT_APPROVED` and `UNCHECKED`. And 33 failing
pipelines produced zero `CI_MUST_PASS`, which is the measurement that forced the
CI signal to be computed independently.

## Terminology

The command name, the database tables, the daemon's internal vocabulary and any
label summarising several bindings keep saying "PR". Only user-facing text
describing one specific binding renders "MR", and only when that binding's own
URL says it is a merge request.

`tbd pr` is documented to agents in the `tbd` skill
(`Sources/TBDShared/TBDSkillContent.swift:187-189`), so agents have been
instructed to type it; renaming it would break instructions already in the field
and the tests that pin those substrings. Aggregate labels need a word that works
when a worktree spans forges, and "PR" is the one already in place. The daemon's
own vocabulary is already forge-neutral where it matters — `PRUndeterminedCause`
speaks of a forge rather than of GitHub (`PRStatusManager.swift:13-34`).

## Discovery: the hook arm

The `PostToolUse:Bash` hook gains a `glab mr create` arm alongside the
`gh pr create` one. Under a non-TTY `Bash` call `glab mr create` emits the bare
web URL, so the extractor has less to sift than on the GitHub side.

The arm earns its place on evidence rather than symmetry: merge requests in the
field are created almost entirely through `glab mr create`, much of it
agent-driven, which is exactly the case the hook exists to catch — an agent
opening a merge request that the fleet would otherwise not notice until the next
poll. The web UI accounts for the rest, and the merge requests measured on a
self-managed instance include none created by `git push -o merge_request.create`.

Because GitLab branch matching is author-blind, every route is discovered
eventually even without the hook, so the arm buys latency rather than coverage —
the opposite of its role on GitHub, where a pull request opened by anyone else is
invisible to branch matching.

Widening the gate to bare `git push` remains off the table. The gate fails closed
because a false bind can auto-archive a worktree
(`PRBindingExtractor.swift:64-79`), and no gate can admit the push option without
admitting every push.

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
  unauthenticated host still yields both hosts despite the command exiting `1`, a
  block that reports "Logged in" and "Invalid token" simultaneously still yields
  the host, and absent or unconfigured `glab` yields none.
- Every `glab` invocation carries `--hostname`, asserted by an injected
  `GLRunner` that inspects the arguments.
- A GitLab host whose calls fail on authentication reports that host, and does
  not degrade to "not a GitLab repo".
- The CI signal: `FAILED` on a pipeline-gating project gives `.checksFailed`;
  `FAILED` on a non-gating project does not; a draft with `FAILED` stays
  `.draft`; `MANUAL` gives `.pending` with its own reason; a null
  `headPipeline` leaves the merge status to decide.
- The precedence around that signal, in both directions:
  `REQUESTED_CHANGES` with a failing gated pipeline gives `.changesRequested`,
  "Changes requested", while `DISCUSSIONS_NOT_RESOLVED` with the same pipeline
  gives `.checksFailed`, "Pipeline failed" — so a later edit cannot promote the
  unresolved-thread case to the change-request slot without going red. A draft
  carrying both stays `.draft`.
- `UNCHECKED` yields `.pending` with a reason distinct from the transient
  `CHECKING` and `PREPARING` cases.
- The recheck request names only bound merge requests, and a failure or an
  unparseable response from it does not disturb the poll's own result.
- Forge derivation is not attempted for a GitHub remote, asserted by an injected
  `GLRunner` that fails the test if invoked.
- GitLab node parsing, including an absent `headPipeline`.
- Attach by bare number composes a `/-/merge_requests/<n>` URL with the GitLab
  host on a GitLab worktree, and `/pull/<n>` on every host the resolver does not
  name — github.com and the self-hosted non-GitLab fleets alike, pinned by
  driving one host both ways so the branch is asserted rather than the string.
  It returns nil rather than guessing when the repo cannot be named.
- A binding's own label follows its URL: a `/pull/` binding reads "PR" whatever
  host it sits on, and a `/-/merge_requests/` one reads "MR" on gitlab.com and
  on a self-managed instance alike.

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
row is written that an existing sweep does not already cover. The single
exception is the detached mergeability recheck, whose subprocess outlives the
pass that spawned it; it is bounded at its creation site by `GitLabRecheckGate`
— at most one live recheck per project — because a forge CLI subprocess is
covered by no sweep and the count, not the lifetime, is what has to stay
finite.

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

**REST for the whole poll, not just the recheck.** REST is the worn path — the
surveyed tools and GitLab's own Go SDK all use it — it tolerates instance
variation by omitting unknown fields rather than failing the whole request, and
it is the only transport that can request a mergeability recomputation. Rejected
because its `iids[]` batch omits pipeline status, forcing one additional call per
merge request per poll pass, where the recheck costs one call per *project*.
Confining the GraphQL query to fields available on every edition also removes the
failure mode REST's tolerance protects against. Using each transport for what it
alone does well costs less than committing to either.

**Rendering `UNCHECKED` as unknown and leaving it there.** Zero extra calls, and
no background work queued on someone else's instance. Rejected because roughly a
third of observed merge requests sit in that state, some for months, so a
substantial part of a GitLab fleet would permanently display a status that
communicates nothing — and the state is reachable out of TBD's own poll, which
makes leaving it a choice rather than a limitation.

**Bounding the recheck with a timeout instead of single-flight.** A deadline on
the detached call would also stop the subprocess pile-up, and it would end a hung
`glab` rather than waiting on it. Rejected because single-flight is both cheaper
and the stronger statement: it needs no timer and therefore no injected clock
seam, and a second recheck for a project whose first is still outstanding is
asking the server to redo work it has not finished — so skipping it loses
nothing even when the endpoint is perfectly healthy. A timeout would still
permit one live process per project per tick until it fired. `GitLabRecheckGate`
is what ships.

**Growing `PRMergeableState`.** Dedicated cases for GitLab's distinct states
would be more faithful to what GitLab reports. Rejected because every new tier
reshuffles `attentionSeverity`, which the toolbar, the sidebar and the
`Worktree.prStatus` column all read and must not disagree about, changing which
binding a multi-PR worktree's icon represents on GitHub as well. Carrying the
detail in `PRStatus.reason` gets the precision without touching the ordering.
