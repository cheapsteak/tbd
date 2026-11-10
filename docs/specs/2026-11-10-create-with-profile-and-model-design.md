# Choose the profile and Claude model when creating a worktree or tab

**Date:** 2026-11-10
**Status:** Design

## Problem

An agent cannot start a worktree or a tab on a chosen model profile (an account) from the CLI. `tbd worktree create` and `tbd terminal create` have no profile flag. So when a person asks an agent to "make a worktree on the acme-work account", the agent creates it on whatever profile the normal choice gives. Then it runs `tbd terminal swap-profile` to move the session. The swap restarts a Claude that has already started work, and the restart can kill the background agents it launched.

The daemon already supports most of this. Only the CLI leaves it out:

- **`WorktreeCreateParams.profileID`** chooses the profile for the new worktree's first tab. It skips the repo setting, the scratch setting, the global default and balancing.
- **`WorktreeCreateParams.model`** chooses the Claude model for the first tab. The daemon passes it as `ANTHROPIC_MODEL`, but for the first start only.
- **`TerminalCreateParams.overrideProfileID`** chooses the profile for a new tab.
- **The app's account picker** (`WorktreeProfilePickerView`) sends all three. Each Claude account row also sends `primaryAgentPreference: claude`, so choosing an account always gives a Claude first tab.

Three faults in the current daemon also matter here:

- **The chosen Claude model is lost after the first start.** Nothing saves it. A parked tab wakes on the profile's model, so a tab started on `opus` can come back on another model with no warning.
- **An unusable explicit profile fails in different ways.** On `worktree.create`, a profile ID that no longer exists gets a logged warning and the normal choice. On `terminal.create`, the tab quietly starts on the machine's own login. `swap-profile` and `continue-in-claude` refuse the same ID.
- **No credential check runs at start.** An OAuth profile that never logged in still starts, and its tab opens at Claude's login screen. An agent sends its prompt there, and nothing happens.

## Goals

- `tbd worktree create` and `tbd terminal create` can choose the profile and the Claude model in one step.
- An agent can ask for "the account I run on" without first looking up its own profile.
- A chosen Claude model stays with its tab through every later start.
- An explicit profile that cannot work is refused before anything is created, whoever sends it: the CLI or the app.
- The agent-facing `tbd` skill teaches the new flags, so agents stop creating and then swapping.

## Non-goals

- **Choosing Codex as the first agent from the CLI.** `--codex-model` keeps its rule: it never chooses the agent.
- **Saving a profile on the worktree.** A new tab in the worktree still goes through the normal choice, as a new tab in the app does.
- **Passing the caller's profile on by default.** A child gets the normal choice unless the caller asks for its own profile.
- **Changing how reopen and revive choose a profile.** Reopening a closed tab and reviving an archived worktree choose the profile again, as they do today. The saved model does survive both, because it travels with the tab's other saved settings.
- **Checking model names.** TBD passes the alias or ID to Claude Code unchanged. TBD supports only the current Claude Code, and Claude Code owns the model names.
- **Changing balancing.** An explicit profile skips balancing and the pool opt-out, as it does today. It is used even when its usage is high.

## Design

### CLI surface

`tbd worktree create` gains two flags:

- **`--profile <name | uuid | caller>`** chooses the profile for the first tab. It makes that tab Claude.
- **`--claude-model <alias | id>`** chooses the Claude model for the first tab, for example `opus` or an exact model ID. It makes that tab Claude. An empty value is refused.

Either flag, when given, makes the CLI send `primaryAgentPreference: claude`. This is what the app's account picker does. Either flag together with `--codex-model` is refused, because they ask for different agents. `--claude-model` without `--profile` keeps the normal profile choice: repo setting, global default, then balancing.

`tbd terminal create` changes in two ways:

- **`--profile <name | uuid | caller>`** is new. It requires `--type claude`, as `--plugin-dir` does.
- **`--model <alias | id>`** follows `--type`. With `--type claude` it is the Claude model. With `--type codex` it is the Codex model. A terminal with no type is a shell, and `--model` on a shell is refused. The flag name on `terminal create` stays `--model`, because `--type` already names the agent. The flag on `worktree create` names its agent (`--claude-model`, `--codex-model`), because there the daemon, not the caller, picks the agent when neither flag is given.

When a profile is given, the human-readable output of both commands adds a `Profile: <name>` line, so an agent can check which account it got. The JSON output does not change.

### Profile lookup

Both commands use the lookup that `swap-profile` and `continue-in-claude` already share (`resolveProfile` in `ProfileCommands.swift`). It tries, in this order:

1. **The keyword `caller`**, matched without regard to case. It is checked before any name, as `swap-profile` checks `ambient`. A profile that is actually named `caller` can then be chosen only by its UUID.
2. **A UUID.**
3. **The exact name.**
4. **A unique folded match.** Two names that differ only in case, in Unicode normalization form, or in invisible format characters (such as a zero-width joiner or an emoji variation selector) fold to the same key. A name typed without its invisible characters still matches.

No match, or more than one, is refused with a message that lists the profile names.

The keyword in step 1 belongs to the two create commands only. Steps 2 to 4 are the shared lookup, so the folded match in step 4 also reaches `swap-profile`, `continue-in-claude` and the `tbd profile` commands that take a profile name.

### `--profile caller`

The CLI resolves `caller` itself. It reads `TBD_WORKTREE_ID` and `TBD_TERMINAL_ID`, reads that tab's row from `terminal.list`, and sends the row's `profileID` as an explicit ID. It refuses in three cases:

- **Not in a TBD tab.** The environment variables are missing.
- **The tab has no profile.** It runs on the machine's own login.
- **The tab runs Codex.** Codex tabs have no profile.

The RPC has no value for "the machine's own login" as an explicit choice: a nil profile means "use the normal choice". So the CLI cannot honor "same as me" in the last two cases. The error tells the caller to name a profile or to leave out `--profile`.

### Daemon: checking an explicit profile

`worktree.create` with `profileID`, and `terminal.create` with `overrideProfileID`, check the profile before anything is created. For a worktree, the check runs in the handler, before git creates the worktree. So the refusal also reaches a caller that used `--no-wait`.

- **The profile must exist.**
- **The profile must have credentials:**
  - An OAuth profile needs a login. Its config folder must hold an account email. `tbd profile list` uses the same test to show "needs /login".
  - A token profile or an API-key profile needs its stored secret.
  - A Bedrock profile is not checked. AWS owns its credentials.
- **A failed check refuses the call.** The error names the profile and the fix, for example `run tbd profile login acme-work`. `terminal.create` no longer starts on the machine's own login when the ID is unknown.
- **A profile that passes is used as today.** It skips the repo setting, the scratch setting, the global default, balancing and the pool opt-out.

One gap stays open. A worktree's pre-session hook can run for minutes before the first tab starts. If a person deletes the profile during that time, the start falls back as it does today and logs a warning. Only a deliberate act during a create can cause this, so it gets no special handling.

Because the daemon runs the check, the app gets it too. The app's account picker already greys out logged-out OAuth rows. A profile that fails the check for another reason now shows an error in the app instead of a silent fallback.

### Daemon: saving the Claude model

The tab's row already saves Claude start settings in the JSON field `claudeSpawnExtras` (`ClaudeSpawnExtras` in `Models.swift`): the settings overlay and the plugin folders. That field is kept on the terminal row, on its history entry, and in an archived worktree's saved sessions. The Claude model joins it as a `model` key.

- **`worktree.create`** saves `model` on the first tab's row.
- **`terminal.create`** with `type: claude` and `model` passes the model as `ANTHROPIC_MODEL` and saves it on the row. This applies to a resume as well as a fresh start.
- **Every later Claude start of the tab** uses the saved model first, then the profile's model. This covers a wake, a restore after a reboot, a recreated window, a reopen from history, a revive from the archive and an account swap.
- **Fallback models** still come from the profile.
- **The overlay can still carry a `model` key of its own.** TBD does not read the overlay, and the `--settings` file and `ANTHROPIC_MODEL` then follow Claude Code's own order.

The JSON field ignores keys it does not know when it decodes, so this needs no migration. An older daemon that reads a row with a `model` key ignores the model and starts the tab on the profile's model.

The saved model stays with the tab through an account swap. An exact model ID may not exist on the new account's provider, for example a first-party ID after a swap to a Bedrock profile. Aliases such as `opus` avoid this.

### RPC changes

- **`TerminalCreateParams.model`** is accepted for `type: claude` as well as `type: codex`. For any other type it is refused. `modelRequiresCodexMessage` becomes a message that names both types.
- **`WorktreeCreateParams.profileID`** keeps its shape. Its doc comment changes: the resolved profile is saved on the first tab's row, as every chosen profile is, and nothing is saved on the worktree.
- **`WorktreeCreateParams.model`** keeps its shape. Its doc comment changes: the model is saved on the first tab's row and used for every later start of that tab.
- **No new RPC method.** `--profile caller` reads `terminal.list`.

### Agent skill and help text

The `tbd` skill (`TBDSkillContent.swift`) gains a short block:

- To start on an account, pass `--profile <name>` to `tbd worktree create` or to `tbd terminal create --type claude`. `tbd profile list` shows the names. `--profile caller` means the account the agent itself runs on.
- To choose a model, pass `--claude-model opus` to `tbd worktree create`, or `--model opus` to `tbd terminal create --type claude`.
- Do not create and then run `swap-profile`. A swap restarts Claude, and the restart can kill its background agents.

The skill's existing Codex model line changes to say that `--model` follows `--type`. The `--help` text of each new flag says the same things.

## Error handling

Each refusal happens before anything is created, and each names its fix:

- **No profile matches the name, or more than one does.** The CLI lists the profile names.
- **`--profile caller` outside a TBD tab, from a tab with no profile, or from a Codex tab.** The CLI says to name a profile or to leave out `--profile`.
- **`--profile` or `--claude-model` together with `--codex-model`.** The CLI says the flags ask for different agents.
- **`terminal create --profile` without `--type claude`, or `--model` on a shell.** The CLI names the type each flag needs.
- **The profile ID no longer exists.** The daemon refuses and names the ID.
- **The profile has no credentials.** The daemon refuses, names the profile, and gives the login or secret fix.

## Tests

Every gated branch is tested both ways.

- **CLI validation:**
  - `--profile` or `--claude-model` with `--codex-model` is refused.
  - `terminal create --profile` without `--type claude` is refused.
  - `--model` without a type is refused. With `--type claude` and with `--type codex` it is accepted.
  - An empty `--claude-model` is refused.
- **CLI params:**
  - `--profile` or `--claude-model` sends `primaryAgentPreference: claude`.
  - Without them, no `primaryAgentPreference` is sent.
- **Profile lookup:**
  - The order: keyword, UUID, exact name, folded match.
  - Names that differ only in case, normalization form or invisible characters match.
  - Two names with the same folded key are refused as ambiguous.
- **`caller`:** each refusal (no environment, no profile, Codex tab) and the success case.
- **Daemon checks, on both RPCs:**
  - Each refusal: a missing profile, an OAuth profile with no login, a token profile with no secret, and an API-key profile with no secret. Each test also checks that no worktree, git branch or tab was created.
  - A Bedrock profile passes.
  - A valid explicit profile skips balancing.
- **Saved model:**
  - Both RPCs save the model on the row.
  - A wake uses the saved model ahead of the profile's model.
  - A row with no saved model falls back to the profile's model.
  - An account swap keeps the saved model.
  - A row written without a `model` key decodes as before.
- **Skill content:** the test requires `--profile`, `--claude-model` and `--profile caller`.

## Placement and rollout

- **Placement.** The keyword and the name lookup live in the CLI, where a change is cheap. The daemon keeps only the integrity check that every caller needs, the app included. The RPC contract gains no name format and no keyword.
- **No feature flag.** The flags are additive. Nothing acts without a user gesture, deletes anything or replaces a load-bearing path. The daemon's refusal replaces a silent fallback, and the saved model stops a silent model change on wake. Both restore what the caller asked for.
- **No new durable resource.** Worktrees and tabs are created through the existing paths, and the existing reconcilers cover them.

## Alternatives considered

### The CLI resolves names, and the daemon checks IDs – chosen

This keeps the RPC on IDs, as the app already uses it, and puts the policy-shaped parts (the keyword and the name fold) where a change does not need a daemon rebuild.

### The daemon accepts profile names – rejected

A new RPC field would carry a name or the keyword `caller`. All the logic would sit in one place, but the RPC would have to keep a name format and a keyword stable forever, and the app needs neither.

### The CLI does every check – rejected

The CLI would read `tbd profile list` and check the login itself, with no daemon change. The app's picker would keep its silent fallbacks. A profile deleted between the list and the create would get past the check.

### One agent-neutral `--model` on both commands – rejected

On `worktree create` the daemon picks the agent when the caller does not, so `--model opus` could reach a Codex tab. A flag that names its agent cannot.

### Save the choice on the worktree – rejected

Every new Claude tab in the worktree would use the saved profile and model. This needs a migration, a new step in the profile choice above the repo setting, and UI to show and clear it. Saving the choice on the tab fixes the reported problem without any of these.

### Pass the caller's profile on by default – rejected

If an agent started ten children, all ten would land on one account, and balancing could never spread them. The `caller` keyword gives the same result when the agent asks for it.

### Ignore `--profile` when the global setting says Codex – rejected

An agent told to use an account means a Claude session. Ignoring the flag would give it the wrong agent and no account. The app's picker already makes a chosen account start Claude.

### Let a logged-out profile start, with a warning – rejected

The tab would open at Claude's login screen. An agent cannot finish a login, so its prompt would go nowhere. A refusal costs one retry; a silent stall costs a session.
