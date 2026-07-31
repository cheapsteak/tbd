# Continue in Codex

`Continue in Codex` is an explicit, non-destructive takeover from a Claude
terminal. TBD leaves the source terminal and worktree untouched, writes a
private `CODEX_HANDOFF.md`, and creates one local Codex terminal in the same
worktree. Retrying the action reuses the mapped live terminal instead of
creating another one.

## MVP contract

- The source must be a Claude terminal with an available JSONL transcript. TBD
  prefers the transcript path stored on the terminal row, then tries the
  profile-aware Claude projects path. No Claude request or model credit is
  required.
- The deterministic handoff contains bounded transcript text plus branch,
  status, recent commits, and available TBD notes or repository context. Raw
  JSONL is not copied into the handoff.
- Handoffs and their durable target mappings are stored outside the repository
  in owner-only TBD state. A generated handoff is never overwritten.
- Codex uses the existing global `~/.codex` authentication and TBD's
  profile-scoped plugin. TBD resolves an absolute Codex executable before it
  creates a tmux window or database row.
- The app and CLI each issue one dedicated `terminal.continueInCodex` RPC. The
  daemon includes the TBD Codex profile and initial handoff prompt in the
  command passed to `tmux.createWindow`; clients must not compose takeover from
  `terminal.create` followed by `terminal.swapProfile` or a post-launch prompt
  send. Startup trust or hook-review gates can exit or intercept that
  intermediate session before the intended profile and prompt take effect.
- The generated `~/.codex/tbd.config.toml` enables the TBD plugin and contains
  a complete, parser-valid disabled `shadcn` MCP entry:

  ```toml
  [mcp_servers.shadcn]
  command = "npx"
  args = ["shadcn@latest", "mcp"]
  enabled = false
  ```

  The command and arguments remain required configuration even when the server
  is disabled. Disabling it prevents parallel Codex sessions from starting one
  resident server each and exhausting startup resources. Claude's
  `disabledMcpjsonServers` setting does not control Codex and is not a
  substitute for this profile invariant.
- The initial prompt tells Codex to read the handoff and applicable
  `AGENTS.md`/`CLAUDE.md` files, inspect the live worktree, verify assumptions,
  preserve unrelated changes, and then continue.
- A successful RPC means the terminal was launched. Readiness remains a
  separate, machine-observed state reported by session/activity hooks.

The RPC target is structured for future adapters, but the MVP accepts only
`local_codex`. It does not invoke Ollama or another summarization model.

## Creation and profile-swap ordering

Fresh terminal creation is the reliable convergence primitive. A Claude
`terminal.create` request resolves its target profile and initial prompt before
creating the tmux window, so callers that know both values should pass
`overrideProfileID` and `prompt` in that single request. Continue in Codex uses
the same principle for Codex: its one `new-window` command already contains the
final Codex profile and handoff prompt. It never creates an intermediate
terminal or calls the Claude-only `terminal.swapProfile` RPC.

An in-place Claude profile swap is not atomic across TBD's database and tmux.
The current compatibility contract interrupts the old pane best-effort,
persists the target profile and session, and then asks tmux to respawn the
existing window. If that window disappeared after the terminal row was read,
the database can reflect the new profile even though no live pane remains.
Reordering those operations would only reverse the inconsistency when the
database write fails after a successful respawn.

Accordingly, automation must not create a terminal and immediately swap it to
the intended profile. Use fresh creation with the final profile and prompt.
Keep `terminal.swapProfile` as an explicit compatibility action for an existing
Claude session, and treat its returned terminal row as durable state rather
than proof that the pane is live.

## Context and bootstrap safety

Claude and Codex do not automatically receive identical skills or injected
context. The handoff and RPC warnings call out missing repository bootstrap,
broken generated `.Codex/skills` references, tracked `.agents/skills` or
`.claude/skills` equivalents, and skill sets that may exceed the context
budget.

Takeover is observational: TBD must never stage, repair, reset, clean, or
otherwise rewrite repository bootstrap files. The receiving agent verifies
the repository's current instructions and reports gaps.

Repository-specific task-routing or “punt” skills belong in that repository's
integration. They are not part of TBD's generic handoff or terminal adapter.

## Future adapter invariants

OpenAI's `codex-plugin-cc` [`/codex:transfer`](https://github.com/openai/codex-plugin-cc#codextransfer)
command currently uses Codex's
[`externalAgentConfig/import`](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#detect-and-import-external-agent-config)
app-server flow to create a persistent, resumable Codex thread from Claude
JSONL. TBD may support that as an optional future context-import adapter, but
it is not an MVP dependency. An adapter must feature-detect a compatible Codex
version, await completion, retain the imported thread ID, and account for
persistent global `CODEX_HOME` mutations. The plugin wrapper currently accepts
only canonical JSONLs under `~/.claude/projects`, while TBD profile transcripts
may live under profile-specific project roots or another stored transcript
path. The deterministic handoff remains the no-Claude-credits, no-plugin
fallback and still carries repository status, commits, and TBD context that
native session import does not.

Remote or hosted adapters must preserve three distinct states:

1. The prompt was written to the adapter's input channel.
2. An explicit submit action was sent, such as carriage return (`\r`).
3. Execution or readiness was observed through a machine interface such as a
   hook or structured event.

Writing a prompt is not proof of submission, and submission is not proof of
execution. Adapters must report these states separately and must not infer them
by scraping rendered terminal text.

Any mutating operation that yields must retain the direct process, session, or
terminal identifier returned by its create or claim operation. It must not
rediscover ownership by a display name or terminal screen. Git mutations also
require explicit postcondition checks for the expected branch, HEAD, status,
and remote state before success is reported.

These contracts do not add hosted execution, readiness polling, repository
repair, automatic staging, or a model-backed summarizer to the MVP.
