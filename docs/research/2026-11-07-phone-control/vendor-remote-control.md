# Vendor-built remote control for agent sessions

**Status:** Research only. Nothing built.
**Sources accessed:** 2026-11-07. Claude Code 2.1.319 and codex-cli 0.166.0 were
installed locally; their `--help` output was read, and no session was started
for this report.

## Summary

Claude Code ships Remote Control, which lets the Claude app on a phone (or
claude.ai/code in a browser) drive a Claude Code session that keeps running on
the laptop. The laptop only makes outbound HTTPS connections to Anthropic, so
NAT is not a problem, and the phone gets almost everything this project wants:
the live transcript, status, sending messages, answering permission prompts and
`AskUserQuestion`, stopping a turn, diffs, and push notifications. TBD can turn
it on for every session it launches without anyone typing a command: it can
append `--remote-control <name>` to the `claude` command line, and a
`remoteControlAtStartup: true` user setting already does it today. On one
developer machine running TBD with that setting, 39 of 41 live Claude sessions
were connected. The limits are hard ones. Remote Control works only with a full
claude.ai login on a paid plan, so it excludes API-key, `setup-token`, proxy and
Bedrock profiles. Team and Enterprise need an Owner to enable it, and
ZDR and HIPAA organizations cannot use it. Anthropic stores the transcript while
a session is connected. There is no public API, so TBD cannot put its own UI,
its worktree context, or its Codex sessions on that phone screen. Codex,
Cursor and GitHub Copilot each have their own version of the same idea, and
each needs that vendor's app, account and relay. None of them can carry another
vendor's sessions.

## How the evidence is labelled

- **Documented** – stated in vendor documentation or the vendor changelog. A
  link follows each claim.
- **Reported** – stated in a public GitHub issue by a user, not confirmed by
  the vendor.
- **Measured** – read on a developer machine on 2026-11-07, read-only. Nothing
  was started or changed.
- **Unverified** – an inference or an open question. These are collected again
  in [Unverified items](#unverified-items).

## 1. Claude Code Remote Control

Primary page: [Continue local sessions from any device with Remote
Control](https://code.claude.com/docs/en/remote-control).

### How it works

- **Who connects to whom** – The laptop connects out. "Your local Claude Code
  session makes outbound HTTPS requests only and never opens inbound ports on
  your machine. When you start Remote Control, it registers with the Anthropic
  API and polls for work. When you connect from another device, the server
  routes messages between the web or mobile client and your local session over
  a streaming connection." ([Connection and
  security](https://code.claude.com/docs/en/remote-control#connection-and-security))
- **Transport details** – The docs do not name the protocol. The changelog
  mentions a `/poll` call that drops to once every 10 minutes while connected
  ([2.1.70](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#2170)),
  "WebSocket disconnects" on bridge sessions
  ([2.1.76](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#2176)),
  and an "inbound event stream"
  ([2.1.261](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21261)).
  So it registers and polls, then streams over a long-lived connection. The
  exact wire protocol is private.
- **Where the work runs** – Claude, its tools and the filesystem stay on the
  laptop. The phone is "a window into that local session"
  ([overview](https://code.claude.com/docs/en/remote-control)).
- **Network loss** – An interactive session retries for as long as an outage
  lasts and reconnects by itself. Server mode gives up after about 10 minutes
  and exits ([Limitations](https://code.claude.com/docs/en/remote-control#limitations)).
  A session goes offline on the phone within seconds of the CLI exiting
  ([2.1.236](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21236)).

### How it is turned on

There are three per-session switches, one setting that covers every session,
and a default that applies when nothing is set.

- **`claude remote-control`** – A server mode with no local prompt. It hosts up
  to 32 sessions by default (`--capacity`) and can spawn each in its own
  worktree (`--spawn worktree`). It refuses global flags it cannot carry over,
  such as `--settings`
  ([Start a Remote Control session](https://code.claude.com/docs/en/remote-control#start-a-remote-control-session)).
  It asks `Enable Remote Control? (y/n)` until the user accepts once, and asks
  for workspace trust on the terminal. TBD does not need this mode; it owns
  its own spawning.
- **`claude --remote-control [name]`, alias `--rc`** – Starts a normal
  interactive session with Remote Control on. The local terminal stays fully
  usable ([CLI reference](https://code.claude.com/docs/en/cli-reference)).
  Local `claude --help` on 2.1.319 lists `--remote-control [name]` and
  `--remote-control-session-name-prefix <prefix>`.
- **`/remote-control`, alias `/rc`** – Turns it on inside a running session and
  carries over the conversation so far. Running it again opens a status panel
  with the URL, a QR code and a disconnect option.
- **`remoteControlAtStartup`** – A setting. `true` connects every interactive
  session at start. It appears in `/config` as **Enable Remote Control for all
  sessions**
  ([settings reference](https://code.claude.com/docs/en/settings-reference#remotecontrolatstartup)).
  Claude Code honors `true` from user settings and managed settings. It ignores
  `true` from project or local settings, so a repository cannot turn it on for
  everyone who clones it
  ([2.1.222](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21222)).
  A `false` in project or local settings wins even over a managed `true`
  ([exceptions to managed precedence](https://code.claude.com/docs/en/settings#exceptions-to-managed-settings-precedence)).
- **The Claude Code default** – When the key is unset, Claude Code follows
  "your organization's admin default if one is set, otherwise Claude Code's
  current default"
  ([Enable Remote Control for all sessions](https://code.claude.com/docs/en/remote-control#enable-remote-control-for-all-sessions)).
  Issue [#90341](https://github.com/anthropics/claude-code/issues/90341)
  reports sessions auto-connecting with the key unset, from a server-side
  rollout. So some users' sessions may already be connected without any
  choice (reported, not documented).

The off switch is `disableRemoteControl: true`. It refuses all of the above,
"auto-start" included, in any settings file
([settings reference](https://code.claude.com/docs/en/settings-reference#disableremotecontrol)).

#### Could TBD turn it on for every session without typing?

Yes. There are three routes, and they differ in scope and in how well they are
proven.

- **Append `--remote-control <name>` in the spawn command** – Documented as a
  per-session override that works "even when this key is `false`"
  ([settings reference](https://code.claude.com/docs/en/settings-reference#remotecontrolatstartup)).
  It affects only sessions TBD launches. TBD already builds the `claude`
  command line in `ClaudeSpawnCommandBuilder` and already passes `--name`, so
  this is a one-flag change. Not measured for this report.
- **`remoteControlAtStartup: true` in the user's `~/.claude/settings.json`** –
  Measured working with TBD. On one developer machine running TBD with this key
  set, 39 of the 41 live session-registry rows that Claude Code 2.1.318–2.1.319
  wrote under `~/.claude/sessions` carried a `bridgeSessionId`, the marker of a
  Remote Control connection. Every one of those sessions was interactive, and
  at least 36 of the 39 ran in TBD worktree directories. The 16 other rows had
  no `version` field and were left out (probably TBD's own stand-in peer rows;
  unverified). The cached server-side auto-enable flag named in #90341 was off
  on that machine, so the setting did the work. TBD's earlier census found 82
  of 84 rows carrying a `bridgeSessionId` on 2026-08-30
  ([cross-machine messaging findings](../2026-08-29-cross-machine-messaging/findings.md)).
  But this route changes the user's own non-TBD sessions too, because TBD's
  profile config dirs symlink the host `settings.json`
  ([channels findings](../2026-07-26-claude-code-channels/findings.md#implication-for-tbd)).
  TBD should not write it for the user.
- **`remoteControlAtStartup: true` in TBD's `--settings` overlay** – The
  settings docs say `--settings` "can set any key your user settings file can
  set" ([settings](https://code.claude.com/docs/en/settings)). It is
  unverified for interactive sessions. Issue
  [#91906](https://github.com/anthropics/claude-code/issues/91906) shows it has
  no effect under `-p`, which TBD does not use.

One open question remains on all three routes. The docs describe a one-time
confirmation for `claude remote-control` and for `/remote-control`. They do not
say whether `--remote-control` or auto-connect shows it. The measured machine
had already accepted it at some point. So a new user may see one confirmation
the first time, in the first TBD terminal (unverified).

### Requirements

All of these are from [Requirements](https://code.claude.com/docs/en/remote-control#requirements)
unless another link is given.

- **Plan** – Pro, Max, Ultra, Team or Enterprise. "API keys are not supported."
- **Organization** – On Team and Enterprise, an Owner must turn on the Remote
  Control toggle first; it is off by default. Enterprise custom roles must
  include both the cloud sessions permission and the Remote Control permission.
- **Login type** – A full claude.ai login from `/login`. A long-lived token
  from `claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN` is refused: "These
  tokens can only make model requests"
  ([troubleshooting](https://code.claude.com/docs/en/remote-control#remote-control-requires-a-full-scope-login-token)).
  If `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `apiKeyHelper` is set,
  Remote Control is off even when a claude.ai login also exists
  ([2.1.139](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21139)).
- **Provider** – Not on Amazon Bedrock, Google Cloud's Agent Platform or
  Microsoft Foundry. Not when `ANTHROPIC_BASE_URL` points anywhere but
  `api.anthropic.com`, such as an LLM gateway
  ([2.1.196](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21196)).
- **Feature flags** – `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or
  `DISABLE_GROWTHBOOK` makes it unavailable. `DISABLE_TELEMETRY` and
  `DO_NOT_TRACK` are fine from v2.1.283 unless the organization requires
  Trusted Devices.
- **Compliance** – Organizations with Zero Data Retention or the HIPAA
  configuration cannot enable it
  ([Connection and security](https://code.claude.com/docs/en/remote-control#connection-and-security)).
- **Interactive only** – `--remote-control` starts "an interactive session",
  and auto-connect applies to "every interactive session". Print mode (`-p`)
  ignores the setting (reported in
  [#91906](https://github.com/anthropics/claude-code/issues/91906)). TBD's
  Claude terminals are interactive, so this is not a blocker.

### Limits

- **One remote per process** – Each interactive process registers one remote
  session. Several devices can watch and type into that one session at once;
  the conversation "stays in sync across all connected devices"
  ([overview](https://code.claude.com/docs/en/remote-control)).
- **How many at once** – No account-wide cap is documented. Server mode
  defaults to 32 per process. The measured machine had 39 connected TBD
  sessions at the same time, so the practical ceiling is at least that.
- **Resume** – `claude --resume` or `--continue` reconnects to the Remote
  Control session recorded in that conversation
  ([Resume sessions](https://code.claude.com/docs/en/remote-control#resume-sessions-after-stopping-the-server)).
  A resume in a second terminal does not steal Remote Control from a first one
  that still has it
  ([2.1.232](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21232)).
  So TBD's park, suspend and restart-after-reboot paths, which resume by
  session ID, should keep the same phone entry. That is unverified for TBD's
  `--fork-session` path, which mints a new session ID.
- **Phone list** – The Claude app's **Code** tab lists the sessions. A Remote
  Control session shows a computer icon with a green dot while online. The
  title follows `--name`, then `/rename`, then history. A hook-supplied title
  also wins, which TBD measured on 2.1.299
  ([session title sync spec](../../specs/2026-10-14-session-title-sync-design.md)).
- **Timeouts** – Forwarded dialogs other than permission prompts and
  `AskUserQuestion` close after `dialogExpiry`, 5 minutes by default
  ([settings reference](https://code.claude.com/docs/en/settings-reference#dialogexpiry)).
  Presence heartbeats that fail for about 30 minutes disconnect an interactive
  session. Server-mode sessions can be brought back for about 4 hours after the
  server stops.
- **Local-only commands** – `/plugin`, `/resume` and other terminal-only
  commands do not work from the phone. A line starting with `!` goes to Claude
  as text, not to the shell
  ([Limitations](https://code.claude.com/docs/en/remote-control#limitations)).
- **Permission modes from the phone** – The app offers Manual, Accept edits,
  Plan and Auto. "You can't select Bypass permissions from the app"
  ([Claude Code on mobile](https://code.claude.com/docs/en/mobile#limitations)).

### What the phone can do

- **Read the transcript live** – Messages, tool activity, compaction progress,
  `/clear` resets, and subagent and workflow progress. Foreground subagents
  stream their tool calls
  ([2.1.251](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21251));
  background subagents show status only.
- **Send messages** – Text, photos and files. Files download to the laptop and
  reach Claude as `@` references.
- **Answer prompts** – Permission prompts and `AskUserQuestion` stay open until
  someone answers
  ([Limitations](https://code.claude.com/docs/en/remote-control#limitations)).
  Several open issues report `AskUserQuestion` not rendering or not reaching
  the CLI from mobile:
  [#100478](https://github.com/anthropics/claude-code/issues/100478),
  [#102055](https://github.com/anthropics/claude-code/issues/102055),
  [#95343](https://github.com/anthropics/claude-code/issues/95343),
  [#107108](https://github.com/anthropics/claude-code/issues/107108).
- **Interrupt** – A Stop button stops the turn the same way Esc does locally
  ([2.1.133](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21133),
  [2.1.261](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21261)).
  The phone can also stop individual background tasks.
- **See changes** – A diff pane shows the branch's changes since it split from
  the default branch, plus uncommitted edits.
- **Change model and effort** – From the device, plus a set of slash commands
  with arguments (`/compact`, `/clear`, `/model`, `/effort`, `/config key=value`
  and others).
- **Push notifications** – `inputNeededNotifEnabled` pushes when a prompt or
  question waits. `agentPushNotifEnabled` lets Claude push when it decides to,
  for example when a long task ends. Both default to off, and both work only
  while Remote Control is connected
  ([settings reference](https://code.claude.com/docs/en/settings-reference#inputneedednotifenabled),
  [Mobile push notifications](https://code.claude.com/docs/en/remote-control#mobile-push-notifications)).
  Claude Code skips the push while you type in or focus the connected
  terminal. `CLAUDE_CLIENT_PRESENCE_FILE` extends that: no push while a marker
  file exists ([env vars](https://code.claude.com/docs/en/env-vars)). Two
  recent issues report pushes missing after 2.1.316
  ([#107199](https://github.com/anthropics/claude-code/issues/107199),
  [#107202](https://github.com/anthropics/claude-code/issues/107202)).

### Security model

- **What Anthropic sees** – Everything in the conversation. "While Remote
  Control is connected, the session transcript, including your messages,
  Claude's responses, and tool activity, is stored on Anthropic servers." It is
  retained under the [data usage](https://code.claude.com/docs/en/data-usage)
  policy ([Connection and security](https://code.claude.com/docs/en/remote-control#connection-and-security)).
  Tool activity includes the contents of files Claude reads.
- **Transport and credentials** – TLS to the Anthropic API. "Multiple
  short-lived credentials, each scoped to a single purpose and expiring
  independently." ([security](https://code.claude.com/docs/en/security))
- **Who can drive a session** – Only the claude.ai account the session signed
  in with. Auto-connect "grants no one else access." A session belongs to the
  account and organization signed in when it started. Signing the machine in to
  another account stops it within seconds
  ([errors](https://code.claude.com/docs/en/errors#remote-control-stopped-because-the-signed-in-account-changed)).
- **Trusted Devices (beta)** – Optional. It requires an enrolled device and a
  sign-in under 18 hours old, refreshed by Face ID, Touch ID or a passkey.
  Owners turn it on for Team and Enterprise; Pro, Max and Ultra users turn it on
  themselves ([Trusted Devices](https://code.claude.com/docs/en/remote-control#trusted-devices)).
- **Revocation** – Run `/remote-control` and disconnect, set
  `disableRemoteControl`, or have an Owner turn off the organization toggle,
  which disconnects live sessions
  ([2.1.286](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21286)).
  Remove a device under Trusted devices, or use **Sign out everywhere** as an
  admin.

### Interaction with TBD's hooks, settings overlay and mod

- **Settings hooks** – A message typed on the phone is a normal prompt on the
  laptop. It passes through `UserPromptSubmit` hooks
  ([2.1.299](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21299)
  fixes a prompt "that had passed its hooks"). So TBD's hooks still see
  phone-originated turns, and TBD's state tracking keeps working.
- **The bridge session ID** – While connected, Claude Code sets
  `CLAUDE_CODE_BRIDGE_SESSION_ID` in hook and Bash-tool environments. Its value
  is the `session_…` ID in the session's claude.ai/code URL
  ([env vars](https://code.claude.com/docs/en/env-vars)). The registry row
  carries the same value as `bridgeSessionId`. TBD already scrubs the variable
  from inherited spawn environments (`SpawnBaseEnvironment`). TBD could read
  either one to show an "open on phone" link or QR code per terminal.
- **The mod** – A mod's hooks run in the session on the laptop. What the mod
  draws appears only in the terminal on the laptop, not on the phone
  ([Where mods run](https://code.claude.com/docs/en/plugins/mods/overview#where-mods-run);
  request [#106948](https://github.com/anthropics/claude-code/issues/106948)).
  Remote Control and SDK hosts no longer offer "don't ask again" on a mod's
  tool calls
  ([2.1.317](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21317)).
- **Bypass permissions** – TBD spawns every Claude session with
  `--dangerously-skip-permissions`. The phone cannot select that mode. Two open
  issues report that a mode change made from the phone, such as entering plan
  mode, leaves the session out of bypass with no way back from the phone
  ([#79990](https://github.com/anthropics/claude-code/issues/79990),
  [#87826](https://github.com/anthropics/claude-code/issues/87826)). An older
  report says the phone showed prompts despite bypass
  ([#29214](https://github.com/anthropics/claude-code/issues/29214)); a
  commenter there saw bypass honored. The current behavior is unverified.
- **Per-profile config dirs** – Each TBD profile can sign in to a different
  claude.ai account. The phone shows only the sessions of the account it is
  signed in to. An older report says a re-login under one `CLAUDE_CONFIG_DIR`
  disconnected Remote Control for a session under another
  ([#88855](https://github.com/anthropics/claude-code/issues/88855), closed as
  inactive, not as fixed).
- **Answering the same prompt twice** – TBD can answer prompts, and so can the
  phone. For Remote Control, the docs do not say which answer wins. For
  channels, the first answer wins and the other is closed
  ([permission relay](https://code.claude.com/docs/en/channels-reference#relay-permission-prompts)).
  First-answer-wins for Remote Control is likely but unverified.
- **Local latency** – One user reports the local session feels slower while
  Remote Control is connected
  ([#93924](https://github.com/anthropics/claude-code/issues/93924)). It is a
  single report with no measurements.

### Is there an API for third parties?

No. The docs index ([llms.txt](https://code.claude.com/docs/llms.txt)) lists no
Remote Control API, and no page describes the protocol or a way to add a client.
The only programmatic surfaces are around it, not in it:

- `CLAUDE_CODE_BRIDGE_SESSION_ID` and `bridgeSessionId` give the session's
  claude.ai/code ID, which is enough to build a link.
- Cross-session messaging uses the same connection to carry messages between a
  user's own sessions on different machines
  ([What connected devices see](https://code.claude.com/docs/en/remote-control#what-connected-devices-see),
  [cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging#availability)).
  That reaches Claude sessions, not a phone UI.

Upstream asks for related openness exist but none for a third-party client:
[#91906](https://github.com/anthropics/claude-code/issues/91906) (headless
sessions), [#102144](https://github.com/anthropics/claude-code/issues/102144)
(expose connection state to status lines).

## 2. Claude Code channels, revisited

TBD's earlier research is
[`docs/research/2026-07-26-claude-code-channels/findings.md`](../2026-07-26-claude-code-channels/findings.md).
Despite the directory name, it measured the per-session inbox socket on Claude
Code 2.1.233. Channels are a separate feature: an MCP server, installed as a
plugin, that pushes events into a running session and can relay permission
prompts back out ([channels](https://code.claude.com/docs/en/channels),
[channels reference](https://code.claude.com/docs/en/channels-reference)).

### What has changed since 2.1.233

- **Cross-session messaging reached more places** – Same-machine messaging now
  works on Bedrock, Claude Platform on AWS, Agent Platform and Foundry, and with
  feature-flag fetching off, from v2.1.248. Native Windows needs v2.1.234
  ([availability](https://code.claude.com/docs/en/cross-session-messaging#availability)).
  The earlier findings said it was unavailable on those providers. That is no
  longer true for same-machine messages.
- **Undelivered messages are visible** – A busy receiver lists a message under
  `Waiting to be delivered`, from v2.1.309.
- **Channel permission relay tightened** – Relay goes only to servers
  registered as channels for the session
  ([2.1.234](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21234)).
  A reply ID that repeats within a session is ignored instead of approving a
  different prompt
  ([2.1.290](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21290)).
  Plugin entries must match the installed plugin's name as well as its
  marketplace (2.1.281).
- **Still a research preview** – `--channels` accepts only plugins on
  Anthropic's allowlist or an organization's `allowedChannelPlugins` list. A
  custom channel needs `--dangerously-load-development-channels`, which shows a
  confirmation prompt and works only in interactive sessions
  ([test during the preview](https://code.claude.com/docs/en/channels-reference#test-during-the-research-preview)).
  Team and Enterprise need an Owner to set `channelsEnabled`. Pro, Max and
  Ultra users without an organization skip those checks.
- **Login types are wider than Remote Control's** – Channels need claude.ai or
  a Console API key
  ([2.1.128](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21128)),
  but not Bedrock, Agent Platform or Foundry.
- **Prompt tools** – `AskUserQuestion` and plan mode were disabled under
  `--channels`
  ([2.1.83](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#2183)),
  then plan mode returned for interactive sessions
  ([2.1.126](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21126)).
  The docs now say only `-p` disables tools that need terminal input. So
  `AskUserQuestion` is probably available in an interactive channels session
  (unverified).

### How channels could serve phone control

- **Off-the-shelf chat bridges** – The Telegram, Discord and iMessage plugins
  turn a chat thread into a phone remote. Inbound text becomes a prompt, and
  Claude replies through the plugin's reply tool. The plugin connects out to
  the chat service, so NAT is not a problem. But the transcript then sits with
  a third party (Telegram or Discord), the user sees Claude's chosen replies
  rather than the transcript, and each session needs its own opt-in on the
  command line. Several sessions polling one Telegram bot would likely collide;
  that is an inference from Telegram's API, not tested.
- **A TBD-built channel** – TBD could ship a channel plugin that relays to
  TBD's own phone surface. It would get two things: a supported push path into
  the session, and permission relay over
  `notifications/claude/channel/permission_request`. Permission relay covers
  tool approvals such as Bash, Write and Edit. It does not cover project trust
  or MCP consent dialogs, and the docs do not say it covers `AskUserQuestion`.
  But a custom channel cannot run without the dev flag's per-launch
  confirmation until Anthropic allowlists it. It also does not solve the hard
  part: getting from the laptop to the phone across NAT without a hosted
  backend.
- **Versus what TBD already has** – TBD already injects messages through the
  inbox socket without disturbing the composer, already reads the transcript
  JSONL, and already answers prompts. TBD sessions run in bypass mode, so
  permission prompts are rare. A channel adds little that TBD lacks. Its one
  real advantage is that permission relay is a documented contract.

## 3. Codex, Cursor, GitHub Copilot and others

### OpenAI Codex

- **Cloud tasks** – The ChatGPT mobile app's **Codex** section starts and
  follows Codex Cloud tasks, which run on OpenAI's machines
  ([Codex on mobile](https://learn.chatgpt.com/docs/mobile)).
- **Local control ("Control this Mac or PC")** – The same phone app can drive
  chats on a paired computer. The host runs the ChatGPT desktop app, set up
  under **Settings > Connections > Control this Mac or PC**, and pairs by QR
  code. The phone can start and continue chats, steer, answer questions,
  approve commands, review diffs and terminal output, and get notifications.
  "A secure relay layer keeps trusted machines reachable … without exposing
  them directly to the public internet"
  ([Remote connections](https://learn.chatgpt.com/docs/remote-connections)).
  Workspace admins may need to enable Remote Control access. The docs say
  "you can't set it up from the Codex CLI or IDE extension."
- **The CLI path** – The CLI reference contradicts that last line in part.
  `codex remote-control` is marked experimental. `start` runs the shared
  app-server daemon with remote control on, and `pair` prints a short-lived
  pairing code ([CLI reference](https://learn.chatgpt.com/docs/cli/reference)).
  Local `codex remote-control --help` on 0.166.0 shows `start`, `stop` and
  `pair`. One user reports pairing a headless Linux VM this way, with the
  daemon holding an outbound WebSocket to `chatgpt.com`
  ([openai/codex#56435](https://github.com/openai/codex/issues/56435)). It
  requires ChatGPT sign-in, not an API key; the daemon logs "remote control
  requires ChatGPT authentication"
  ([openai/codex#44706](https://github.com/openai/codex/issues/44706)).
- **Does it reach TBD's Codex tabs?** – No. Remote control lives on the shared
  background app-server. TBD launches Codex with `--no-daemon`, which "run[s]
  the interactive CLI without the shared background server"
  ([CLI reference](https://learn.chatgpt.com/docs/cli/reference)). Whether a
  TUI thread on the shared daemon shows up on the phone is unverified.
- **The app-server protocol** – `codex app-server` is the open protocol rich
  clients use, over stdio, WebSocket or a Unix socket. It is what a TBD-built
  phone bridge would talk to for Codex
  ([app-server](https://learn.chatgpt.com/docs/app-server)). The remote-control
  relay itself is not documented for third parties.

### Cursor

- **Cloud agents** – Cursor for iOS, cursor.com/agents and the desktop Agents
  window all start and steer cloud agents, which run in Cursor's cloud. There is
  no Android app yet
  ([Cursor for iOS](https://cursor.com/help/ai-features/mobile-app)).
- **Remote Control (beta)** – A local agent in the Agents Window can be handed
  to the phone with `/remote-control` after turning it on in **Settings >
  Agents**. "The agent loop moves to the cloud while its tools keep running on
  your machine." Cursor sends "the conversation state and model context"
  to its cloud. It needs Cursor 3.9.8 or later, a paid plan with Cloud Agents,
  cloud data storage allowed, and on Teams and Enterprise an admin toggle
  ([mobile reference](https://cursor.com/docs/cloud-agent/mobile#remote-control)).
  This differs from Claude and Codex: the model loop leaves the laptop.
- **The CLI** – The `agent` CLI does not offer Remote Control. It offers
  "Cloud Agent handoff", which pushes the conversation to a cloud agent with an
  `&` prefix ([CLI overview](https://cursor.com/docs/cli/overview)).

### GitHub Copilot

- **Cloud agent** – GitHub Mobile starts Copilot cloud agent sessions, assigns
  issues to Copilot and tracks the resulting pull requests. The work runs in a
  cloud sandbox by default
  ([cloud agent on mobile](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-mobile)).
- **Copilot CLI remote control** – The closest analogue to Claude's feature.
  `/remote on` in an interactive session, or `"remoteSessions": true` in
  `~/.copilot/settings.json`, makes the local session steerable from
  github.com and GitHub Mobile
  ([steering a session](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/steer-remotely)).
  "Session events … are sent from your local machine to GitHub. Remote commands
  are polled by Copilot CLI from GitHub and injected into your local session."
  The phone can answer permission requests and questions, approve plans, send
  prompts, switch modes and cancel the current operation. The CLI takes the
  first answer from either side. It works only for interactive sessions, and an
  organization seat needs the "Store local sessions in the Cloud" policy set to
  "View and control"
  ([about remote control](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)).
  TBD does not launch Copilot CLI today.

### Others

- **Happy (open source, not a vendor)** – Happy wraps Claude Code and Codex on
  the laptop and drives them from its own iOS, Android and web apps. Traffic is
  end-to-end encrypted through a relay server that is MIT-licensed and
  self-hostable, with a free hosted instance
  ([slopus/happy](https://github.com/slopus/happy)). It is credible (about 24k
  GitHub stars) and is the closest existing model for a vendor-neutral phone
  remote. It is listed here for contrast; it is not vendor-built.

## What this means for TBD

### Could TBD simply turn on Claude Code Remote Control?

Yes, for eligible Claude sessions. The narrowest change is a TBD setting that
appends `--remote-control <name>` in `ClaudeSpawnCommandBuilder` for sessions
whose profile can use it. That means the default login or an `oauth` (full
`/login`) profile with no `ANTHROPIC_BASE_URL`. No user typing is needed, and
TBD already proves the result works. With the user-level setting on, TBD's own
sessions are connected today. TBD could then add small things around it:

- Read `bridgeSessionId` from the registry, or
  `CLAUDE_CODE_BRIDGE_SESSION_ID` from a hook, and show a per-terminal "open on
  phone" link or QR code.
- Write a `CLAUDE_CLIENT_PRESENCE_FILE` marker while the TBD window is in front,
  so the phone does not buzz while the user is at the laptop.
- Leave push preferences to the user's own `/config`.

That gives Claude sessions transcript, status, messages, prompt answers,
interrupt, diffs and push notifications on the phone, with no backend and no
NAT work for TBD.

### What it costs

- **Data leaves the laptop** – Anthropic stores each connected session's full
  transcript, tool output included. This is a real change from a plain CLI
  session. Under TBD's rules it needs a default-off toggle and a spec.
- **Phone clutter** – Every TBD session becomes an entry in the Code tab. A
  user with dozens of worktrees gets dozens of entries. TBD's `--name` and hook
  titles keep them readable, but the phone has no TBD grouping.
- **Noise for ineligible profiles** – With an ineligible login,
  `claude --remote-control` still starts but shows a failure notification
  shortly after launch. So TBD must check eligibility before adding the flag.
- **Churn** – About 280 changelog entries mention Remote Control, and dozens
  of issues are open. The surface TBD would depend on changes weekly.
- **Local cost** – One more long-lived outbound connection per session. One
  unmeasured report of local slowdown
  ([#93924](https://github.com/anthropics/claude-code/issues/93924)).

### What it cannot do

- **Codex sessions** – Nothing here reaches them. Codex's own phone control
  needs the ChatGPT app and the shared daemon, and TBD runs Codex with
  `--no-daemon`.
- **API-key, `setup-token`, proxy and Bedrock profiles** – All four of TBD's
  non-login credential kinds are excluded, along with Agent Platform, Foundry
  and any LLM gateway.
- **Some organizations** – Team and Enterprise members need an Owner to turn
  it on. ZDR and HIPAA organizations cannot use it at all.
- **Mixed accounts** – Sessions under different TBD profiles land in different
  claude.ai accounts, and the phone shows one account at a time.
- **TBD's own UI and context** – No API exists to add TBD's worktree list, PR
  state, notifications, mod UI or Codex sessions to the Claude app. TBD would
  be a launcher for Anthropic's phone UI, not a phone product.

### What risk it carries

- **Remote control of a bypass-permissions session** – TBD's sessions skip all
  permission prompts. Anyone holding the user's claude.ai login on a phone can
  make the laptop run commands without approval. Trusted Devices reduces this
  but is beta and off by default.
- **Permission-mode drift** – A mode change on the phone can leave a TBD
  session out of bypass with no way back from the phone (#79990, #87826). TBD's
  own assumption that its sessions are in bypass could then be wrong.
- **Prompt answering races** – TBD and the phone could both answer one
  `AskUserQuestion` or permission prompt. Which answer wins is undocumented.
  Mobile `AskUserQuestion` is also the buggiest area in the open issues.
- **Server-side defaults** – Anthropic can roll auto-connect out to users with
  the key unset (#90341). TBD sessions might then be connected without TBD or
  the user choosing it. A TBD toggle cannot prevent that; only
  `remoteControlAtStartup: false` or `disableRemoteControl` can.
- **Vendor dependency** – Plans, login rules and the feature itself are
  Anthropic's to change. A phone feature built only on Remote Control would
  serve only TBD users who are Claude subscribers with eligible logins.

Remote Control is a cheap, strong option for Claude subscribers. It cannot be
TBD's whole answer for a multi-tenant, multi-agent product. It works best as an
opt-in for the users it fits, beside a vendor-neutral path that also covers
Codex and API-key users.

## Unverified items

- Whether `claude --remote-control` or auto-connect shows the one-time Remote
  Control confirmation for a user who has never accepted it.
- Whether `remoteControlAtStartup: true` in TBD's `--settings` overlay turns
  Remote Control on for an interactive session.
- Whether a phone answer or a TBD answer wins when both answer the same prompt
  in a Remote Control session.
- Whether the phone today honors or overrides a session started with
  `--dangerously-skip-permissions` (conflicting reports in #29214).
- Whether a resume with `--fork-session` reattaches to the original Remote
  Control session or creates a new one.
- What the 16 versionless registry rows on the measured machine were.
- Whether channel permission relay covers `AskUserQuestion`, and whether
  `AskUserQuestion` is available in an interactive `--channels` session.
- Whether a Codex TUI thread on the shared daemon appears in the ChatGPT phone
  app once `codex remote-control start` runs.
- Any account-wide cap on concurrent Remote Control sessions beyond the 39
  observed.
