# Running a command under a profile

`tbd profile exec <profile> -- <command> [args…]` runs a command with the
account a TBD session on that profile would use. It is for headless work —
scripts, schedulers, background runners — that wants a profile's account
without opening a terminal:

```
tbd profile exec work -- claude -p "summarize the diff"
```

The profile is named the way every `tbd profile` verb names one: exact name,
unique case-insensitive name, or UUID.

## What the command gets

The same thing a Claude session spawned on the profile gets **from the
profile**:

- **Signed-in (OAuth) profiles** – `CLAUDE_CONFIG_DIR` pointing at the profile's
  isolated config directory, where its `/login` credential lives.
- **Setup-token profiles** – the same config directory, plus the stored token as
  `CLAUDE_CODE_OAUTH_TOKEN`. This is the case the verb exists for: setting
  `CLAUDE_CONFIG_DIR` alone leaves a token profile signed out, because its token
  is stored by TBD rather than in the directory.
- **API-key profiles** – the config directory and `ANTHROPIC_API_KEY`, plus the
  profile's `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` when set.
- **Bedrock profiles** – `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`, the profile's
  `AWS_PROFILE` when set, and `ANTHROPIC_MODEL`.
- **Every kind** – the global and profile [environment
  overrides](env-overrides.md), beneath the profile's own variables so an
  override never replaces the account. Repo overrides do not apply; the command
  runs under a profile, not in a repo.

What a session gets from its **terminal** is left out: the model-proxy route,
the settings overlay with TBD's hooks, and the interactive-only variables
(`DISABLE_AUTO_UPDATE`, and the Claude display settings in the Terminal
settings pane, such as fullscreen rendering).

Everything else is inherited from the calling process. The variables that choose
a Claude account are cleared from it first — `CLAUDE_CODE_OAUTH_TOKEN`,
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`ANTHROPIC_MODEL`, `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_USE_BEDROCK` — so a
caller that is itself a session on another profile cannot leak its own account
into the command. `AWS_REGION` and `AWS_PROFILE` stay inherited unless the
profile sets them: other tools read them, and Claude Code consults them only for
Bedrock.

## Exit status and output

The command replaces the `tbd` process, so its output, signals and exit status
are its own. When the command never runs, the status follows `env(1)`:

- **125** – TBD could not prepare it: the daemon is unreachable, the profile is
  unknown, a token or API-key profile has no stored credential, or the profile's
  config directory could not be created. The reason is on stderr.
- **126** – the command was found but could not be executed.
- **127** – the command was not found.

`tbd profile exec` prints nothing on success and never prints a credential. The
daemon hands the credential over its owner-only socket in the
`modelProfile.execEnvironment` result, whose description lists variable names
only.

## Stricter than a spawn

A spawned session tolerates two problems that a headless command cannot show
anyone, so `exec` refuses them instead:

- A token profile with no stored token spawns a pane that asks for a login;
  `exec` exits 125 and names the repair.
- A profile whose config directory could not be created still spawns; `exec`
  exits 125, because the command would otherwise read the caller's own Claude
  config and run on whatever account is signed in there.
