# Running a command under a profile (`tbd profile exec`)

**Date:** 2026-10-09
**Status:** Design

## Problem

A model profile is TBD's name for the account a Claude session runs on. TBD
delivers a profile's account to a session by setting environment variables when
it spawns the session's terminal. Nothing outside TBD's own terminals can get
that delivery.

For a signed-in (OAuth) profile that gap is small. Its credential is a `/login`
stored inside the profile's isolated config directory, so any process that sets
`CLAUDE_CONFIG_DIR` to that directory runs on the account.

For a setup-token profile the gap is total. Its credential is a
`claude setup-token` value TBD stores in `~/.tbd/claude-tokens/<uuid>.token` and
injects as `CLAUDE_CODE_OAUTH_TOKEN` only into the terminals it spawns. A process
that sets `CLAUDE_CONFIG_DIR` to a token profile's directory finds no credential
there, and `claude` answers `Not logged in`.

So headless work — a scheduler, a background runner, a cron job running
`claude -p`, a script that fans prompts out across accounts — can use signed-in
profiles by reaching into their directories, and cannot use token profiles at
all. Token profiles are exactly the ones people mint for automation.

## Non-goals

- **Choosing the profile.** The caller names it. Balancing picks a profile for a
  new terminal; a headless caller that wants the same answer can read
  `tbd profile list --json` (the capacity contract) and choose.
- **Counting the command as a session.** It holds no terminal row, appears in no
  live-session count, and takes no balancing reservation. Its usage reaches the
  usage readings the way any other use of the account does.
- **Repo context.** The command runs under a profile, not in a repo, so
  repo-scope env overrides and repo settings fragments do not apply.

## Design

### The verb

```
tbd profile exec <profile> -- <command> [args…]
```

The profile is resolved the way every `tbd profile` verb resolves one: exact
name, unique case-insensitive name, or UUID. Everything after `--` is the
command; an empty command is a usage error.

### What the command gets

The environment a spawned Claude session gets **from its profile**, and nothing
it gets from its terminal:

- **Routing** – `ClaudeSpawnCommandBuilder.routingEnv`: `CLAUDE_CONFIG_DIR` for
  every non-Bedrock kind, `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` when set,
  and for Bedrock `CLAUDE_CODE_USE_BEDROCK`, `AWS_REGION`, `AWS_PROFILE` and
  `ANTHROPIC_MODEL`.
- **Credential** – `ClaudeSpawnCommandBuilder.credentialEnv`: the stored secret
  as `CLAUDE_CODE_OAUTH_TOKEN` for a token profile and as `ANTHROPIC_API_KEY` for
  an API-key profile; nothing for a signed-in or Bedrock profile.
- **Env overrides** – global and profile scope, merged by `EnvOverrideResolver`,
  with routing and credential layered on top. This is the order a session's
  launch environment uses (`ModelProxyRouteAttachment.Outcome.launchEnvironment`),
  so an override can never replace the account the profile names.

`credentialEnv` is extracted from `build` rather than written a second time, and
`ClaudeSpawnCommandBuilder.execEnvironment` composes the three. A test holds
`execEnvironment` equal to `build`'s `sensitiveEnv` minus the terminal-only keys,
for every credential kind, so a session and an exec child cannot drift apart.

Left out, because each belongs to a terminal rather than a profile:

- **The model-proxy route.** It is attached to one terminal on the holder
  transport, keyed by that terminal's id.
- **The settings overlay** carrying TBD's hooks, which report events about a
  terminal the command does not have.
- **`DISABLE_AUTO_UPDATE` and the `ClaudeEnvRegistry` settings.** The first stops
  an interactive rc file from prompting; the second tunes the interactive UI. A
  headless child has neither.

The config directory is provisioned exactly as a spawn provisions it, through
`ClaudeProfileConfigDirManager.resolveConfigDir`, so a profile whose directory
does not exist yet gets a seeded one.

### Clear, then apply

The child inherits the caller's environment, as `env(1)` and `sudo -E` do, so
`PATH`, `HOME` and the caller's tools still work. Before the profile's variables
are applied, every inherited variable that chooses Claude's credential,
provider, endpoint or model is removed (`ProfileExecEnvironment.clearedKeys`).

The case this exists for: a caller that is itself a session on another token
profile carries that profile's `CLAUDE_CODE_OAUTH_TOKEN`. Claude Code ranks that
variable above the login stored in a config directory, so without the clear a
command run under a signed-in profile would run on the caller's account instead.

The cleared set has two halves, both in `ProfileExecEnvironment`:

- **`profileKeys`** – every key the builder can produce for some kind, less
  `AWS_REGION` and `AWS_PROFILE`. A test holds it equal to the builder's output,
  so a new routing key cannot be added to the builder without the clear covering
  it.
- **`otherSelectors`** – variables no profile sets that still redirect `claude`:
  other credentials (`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_CUSTOM_HEADERS`,
  `AWS_BEARER_TOKEN_BEDROCK`), other providers (Vertex, Foundry, the Bedrock and
  Vertex auth skips and base URLs, the Vertex project) and model defaults
  (`ANTHROPIC_DEFAULT_*_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`). A profile that
  needs one sets it in its env overrides, which arrive after the clear.

`AWS_REGION`, `AWS_PROFILE` and `CLOUD_ML_REGION` stay inherited unless the
profile sets them. Other tools read them, and Claude Code consults them only for
a cloud provider, which the clear switches off unless the profile names it.

### Exit status and output

The CLI replaces itself with the command (`execve`), so the command's output,
signals and exit status are its own, and a caller that kills `tbd` kills the
command. When the command never runs, the status follows `env(1)`, `nice(1)` and
`timeout(1)`:

- **125** – TBD could not prepare it: the daemon is unreachable, the profile is
  unknown, a token or API-key profile has no stored credential, or the config
  directory could not be provisioned.
- **126** – the command was found but could not be executed.
- **127** – the command was not found, looked up on the child's `PATH` (or
  `execvp`'s default path when it has none).

`tbd profile exec` prints nothing when it succeeds, and a one-line reason on
stderr when it does not.

### Stricter than a spawn

A spawn tolerates two problems that a headless command cannot show anyone, so
`exec` refuses them with status 125 instead:

- **A token profile with no stored token.** A spawn opens a pane that asks for a
  login, which the person sees and repairs. A headless child would fail with
  nobody watching, so `exec` names the repair instead.
- **A config directory that could not be provisioned.** A spawn still opens. A
  child without its `CLAUDE_CONFIG_DIR` falls back to the caller's own Claude
  config and runs on whatever account is signed in there.

## Where secrets travel

Before this design no RPC result carried a whole secret. A token profile was
shown everywhere by its masked tail (`tokenTail`), and the token left the daemon
only through tmux's `-e` into a spawned terminal's environment, never into
`ps` argv.

`modelProfile.execEnvironment` is the one RPC result that carries a whole
secret. It returns the token so the CLI can put it into the child's environment,
the same destination a spawn delivers it to. The boundary it crosses is the
daemon's socket, which the daemon `chmod`s to the owner before listening. That
is the same boundary as the 0600 token file the daemon itself reads: any process
that can connect to the socket can already read the file.

Three properties keep the new path from becoming a leak:

- **It is never printed.** `ModelProfileExecEnvironmentResult`'s `description`,
  `debugDescription` and `customMirror` list variable names only, so logging,
  interpolating or dumping the value shows no secret. The CLI writes nothing on
  success and only its own reason on failure. A test asserts all of this
  against a real stored token.
- **It is never logged.** The daemon's socket server encodes RPC responses
  without logging them.
- **It never enters argv.** The CLI passes the token to `execve` in the
  environment array, not on a command line.

The `tokenTail` documentation states the narrowed rule: the list never carries
the whole token, and one named RPC does.

## Testing

- `ClaudeExecEnvironmentTests` – exec equals spawn per credential kind;
  overrides never replace the profile's keys; a stray secret on a signed-in
  profile is not injected; `profileKeys` equals the builder's vocabulary and
  `otherSelectors` is disjoint from it.
- `ModelProfileRPCTests` – the handler against the real file store under the
  test fence: each kind's exact environment, both refusals, override merging,
  an unknown id, and redaction of the result's descriptions.
- `ProfileCommandsTests` – argument parsing, clear-then-apply against a caller
  carrying another profile's credentials, executable lookup, and the status
  mapping.

## Rejected alternatives

- **The CLI reads the token file itself.** The token would still be in the CLI's
  memory and the child's environment, so nothing is protected that the socket
  boundary does not already protect. The file store would have to move into
  `TBDShared` so the CLI could link it, and the environment would be composed
  half in the daemon and half in the CLI, where the two halves could disagree
  about which variable carries which kind's credential.
- **The daemon spawns the child and relays its stdio.** The token would stay in
  the daemon, but the child would become the daemon's child. A daemon restart
  would then orphan or kill it, and signals and the exit status would need
  forwarding over the socket. `execve` gives the caller all of that directly.
- **Only set `CLAUDE_CONFIG_DIR` and teach Claude Code to find the token
  there.** Writing the token into the profile's directory as a credential file
  would let a `/login` inside the directory and the stored token disagree
  silently, the shadowed-login hazard token profiles already document, and would
  put a second copy of every token on disk.
- **Inherit nothing (`env -i`).** The child would lose `PATH`, `HOME` and the
  caller's tools, and every caller would have to rebuild its own environment.
  Clearing the account-choosing variables gives the same account guarantee
  without that cost.
