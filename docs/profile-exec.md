# Running a command under a profile

`tbd profile exec <profile> -- <command> [args…]` runs a command with the
account a TBD session on that profile would use. It is for headless work —
scripts, schedulers, background runners — that wants a profile's account
without opening a terminal:

```
tbd profile exec work -- claude -p "summarize the diff"
```

The profile is named the way every `tbd profile` verb names one: exact name,
unique case-insensitive name, or UUID. The design and its rejected alternatives
are in [the spec](specs/2026-10-09-profile-exec-design.md).

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

Everything else is inherited from the calling process, except the variables
that choose Claude's credential, provider, endpoint or model. Those are cleared
first, so a caller that is itself a session on another profile cannot carry its
own account into the command:

- **Ones a profile sets** – `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` and
  `CLAUDE_CODE_USE_BEDROCK`.
- **Ones no profile sets** – `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_CUSTOM_HEADERS`,
  `AWS_BEARER_TOKEN_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`,
  `CLAUDE_CODE_SKIP_BEDROCK_AUTH`, `CLAUDE_CODE_SKIP_VERTEX_AUTH`,
  `ANTHROPIC_BEDROCK_BASE_URL`, `ANTHROPIC_VERTEX_BASE_URL`,
  `ANTHROPIC_VERTEX_PROJECT_ID`, and the model defaults
  `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
  `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL`. A profile
  that needs one sets it in its env overrides, which are applied after the
  clear.

`AWS_REGION`, `AWS_PROFILE` and `CLOUD_ML_REGION` stay inherited unless the
profile sets them: other tools read them, and Claude Code consults them only for
a cloud provider, and the clear switches off every provider the profile does not
name.

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
