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
- The generated `~/.codex/tbd.config.toml` enables the TBD plugin and disables
  the `shadcn` MCP server for TBD sessions. This prevents parallel Codex
  sessions from starting one resident server each and exhausting startup
  resources. Claude's `disabledMcpjsonServers` setting does not control Codex
  and is not a substitute for this profile invariant.
- The initial prompt tells Codex to read the handoff and applicable
  `AGENTS.md`/`CLAUDE.md` files, inspect the live worktree, verify assumptions,
  preserve unrelated changes, and then continue.
- A successful RPC means the terminal was launched. Readiness remains a
  separate, machine-observed state reported by session/activity hooks.

The RPC target is structured for future adapters, but the MVP accepts only
`local_codex`. It does not invoke Ollama or another summarization model.

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
