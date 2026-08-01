# Importing a Claude session into Codex: the `externalAgentConfig` app-server surface

**Status:** Investigated, not implemented
**Tested:** 2026-07-31 by driving `codex app-server` over stdio with codex-cli 0.145.0 — `detect` and a
single-session `import` were both executed against a live server
**Plugin surface inspected:** `openai/codex-plugin-cc` 1.0.6 (`db52e28`, upstream HEAD)

## Summary

Codex can ingest a Claude Code session transcript natively. The conversion is performed by Codex
from a filesystem path; no caller needs to parse Claude's JSONL, and no model turn is consumed on
either side.

The capability is an app-server protocol surface, not a CLI subcommand and not a plugin feature.
`codex --help` has no `import`. The `codex-plugin-cc` `/codex:transfer` command is a convenience
wrapper over the same protocol, so an integration does not depend on that plugin being installed.

Two properties make this materially different from writing a handoff summary. Fidelity is not a
design question — Codex reads the whole transcript rather than a caller-chosen excerpt. And the
path is reachable with no Claude process running, so it works when the source session is out of
quota, which a Claude-side command cannot be.

The surface is experimental and moving. `codex app-server` is marked `[experimental]`, and the
entire client path landed upstream between plugin 1.0.4 and 1.0.6.

## Reproducing

Bare `codex app-server` speaks newline-delimited JSON-RPC on stdio. (A socket form,
`codex app-server --listen unix://…`, is documented in
[the channels findings](../2026-07-26-claude-code-channels/findings.md).)

```jsonc
>> {"jsonrpc":"2.0","id":1,"method":"initialize",
    "params":{"clientInfo":{"name":"probe","title":"probe","version":"0.0.1"}}}
<< {"id":1,"result":{"userAgent":"probe/0.145.0 (Mac OS 26.1.0; arm64) …",
    "codexHome":"/Users/…/.codex","platformFamily":"unix","platformOs":"macos"}}

>> {"jsonrpc":"2.0","method":"initialized","params":{}}
>> {"jsonrpc":"2.0","id":2,"method":"externalAgentConfig/detect",
    "params":{"cwds":["/path/to/a/worktree"],"includeHome":true}}
<< {"id":2,"result":{"items":[ … ]}}
```

The full protocol schema can be generated locally, without running a server:

```sh
codex app-server generate-json-schema --out <dir>   # --out is required
```

## Observed facts

### `detect` is a setup-migration API; sessions are one item type of ten

`ExternalAgentConfigMigrationItemType` is an enum of `AGENTS_MD`, `CONFIG`, `SKILLS`, `PLUGINS`,
`MCP_SERVER_CONFIG`, `SUBAGENTS`, `HOOKS`, `COMMANDS`, `MEMORY`, `SESSIONS`.

A single `detect` call on a developer machine returned ten items. Alongside `SESSIONS`, it proposed
migrating `~/.claude/CLAUDE.md` to `~/.codex/AGENTS.md`, hooks from `~/.claude` into
`~/.codex/hooks.json`, skills and commands into `~/.agents/skills`, MCP servers into
`~/.codex/config.toml`, and enabled plugins from `~/.claude/settings.json`.

This framing is the origin of the context-parity concerns that surround Claude-to-Codex handoff
generally: the same mechanism that moves a conversation also moves — or offers to move — the
agent's whole configuration.

### Session detection is home-scoped; config detection is repo-scoped

Passing `cwds` produced repo-scoped `HOOKS`, `SKILLS` and `AGENTS_MD` items carrying that `cwd`.
The `SESSIONS` item came back with `cwd: null` and covered **49 recent sessions from
`~/.claude/projects`** regardless of the `cwds` argument.

Restricting sessions to a working directory is therefore a client-side filter over the returned
list, not a server-side query. In the observed sample, 7 of 49 sessions had a `cwd` under a TBD
worktree.

### Each detected session carries a usable title

Session entries are `{path, cwd, title}`. Titles are human-readable summaries of the conversation
rather than filenames or ids — this investigation's own session came back as
`"Investigate PR 561 brainstorming skip"`. A picker can be built from `detect` alone.

The other 48 are not reproduced here, and that is itself the finding: because session detection is
home-scoped, the list spans every repository on the machine, and a title is a one-line description
of what that work was about. Any picker built on `detect` will therefore show a user titles from
unrelated projects — including, on a shared or work machine, ones that are confidential to another
org. Filtering to the current worktree is a client-side concern with a confidentiality dimension,
not just an ergonomic one.

### `import` returns the created thread id, so no client ledger is needed

`SessionMigration` requires `{cwd, path}` with optional `title`. The request returns
`{importId}` — an id for the import *operation*. The thread id arrives in the
`externalAgentConfig/import/progress` and `.../completed` notifications, whose per-item success
entries pair the input with the output:

```jsonc
{"itemType":"SESSIONS",
 "cwd":null,
 "source":"/Users/…/.claude/projects/<slug>/<session-id>.jsonl",
 "target":"019fb9d4-f45a-7061-8953-d377b660dba3"}
```

`target` is a resumable Codex session. The import above produced
`~/.codex/sessions/2026/07/31/rollout-<ts>-019fb9d4-….jsonl`, 96 KB, whose `session_meta` carries
`session_id` equal to `target` and the source session's `cwd`. Codex records the import in its own
`~/.codex/external_agent_session_imports.json`. Round trip was roughly 60 ms.

A caller therefore goes from a Claude transcript path to a resumable Codex thread with no
bookkeeping of its own. `codex-plugin-cc` maintains a private ledger keyed by source path and
SHA256 to recover the same id; that is redundant for a client reading the notification.

`session_meta.originator` records the `clientInfo.name` the caller sent at `initialize`, so imports
are attributable to the tool that made them.

### Conversion keeps intent and caps bulk

Codex does not reproduce Claude's tool structure. Tool activity is transcoded into text inside
assistant messages, delimited by markers:

```text
[external_agent_tool_call: WebSearch]
input: {"query":"…"}
[/external_agent_tool_call]
[external_agent_tool_result]
…result text…
[/external_agent_tool_result]
```

There are no native `function_call` / `function_call_output` items in the result, so a resumed agent
reads tool history as prose rather than as structured turns.

Measured on a 156-line source that carried 20 `tool_use` and 20 `tool_result` blocks:

- all 20 tool calls survive, with tool name and full input JSON
- 17 result blocks survive, one of them empty — so 16 carry content, and 3 are lost outright
- results are capped at 4,000 characters each, and truncation is largely silent: 16,703 characters
  retained from 77,836, with two "truncated" markers and no ellipses
- conversation prose survives intact

About 79% of tool-result bulk is therefore discarded. What survives is which tools ran, with what
arguments, in what order, plus the head of each result — the shape of the work rather than its
output. For a handoff into the same worktree this is a reasonable trade: a truncated file read can
simply be re-run, whereas lost intent could not be reconstructed.

The conversion is literal enough to carry interface noise. A usage-limit notice rendered in the
source session was imported as an assistant turn.

### `import/readHistories` is an audit log

`ExternalAgentConfigImportHistoriesReadResponse` is `{connectors, data}`, where each `data` entry is
`{importId, completedAtMs, successes[], failures[]}`. It reports past import operations. It does not
enumerate available Claude sessions — `detect` is the discovery call.

## Plugin surface

`/codex:transfer` exists in `codex-plugin-cc` **1.0.6** and not in **1.0.4**; 1.0.4's
`scripts/lib/codex.mjs` contains no `externalAgentConfig` references at all. An installed copy is
not evidence the command is available.

Its frontmatter sets `disable-model-invocation: true`, which removes the command from the model's
SlashCommand tool and its metadata from context. It does not mean the command runs without a model
turn: the body pairs a `!`-prefixed bash invocation with the instruction *"Present the command
output to the user exactly as returned"*, so a turn is spent rendering the printed
`codex resume <session-id>`. A source session that is out of quota is therefore not served by the
command, even though the underlying import needs nothing from Claude. This reasoning follows from
the command definition; behavior under an exhausted quota was not observed.

The command accepts `--source <claude-jsonl>`, so it is not restricted to the session invoking it.

## Unknowns

- **Idempotency.** Whether importing the same session twice yields one thread or two, and what
  Codex's `external_agent_session_imports.json` does once the source transcript grows after import.
- Whether `migrationSource` selects agents other than Claude Code, and what values it accepts. The
  schema documents only that unrecognized values fall back to a default.
- Behavior of `/codex:transfer` against an exhausted Claude quota.
- `codex app-server` is experimental; none of these contracts are stable.

## Implication for TBD

TBD is well positioned for exactly one part of this, and it is not the part a handoff feature would
normally focus on. `detect` returns a global, unordered list of every recent Claude session. TBD
already knows which worktree, which tab, and which session id the user means, so it can collapse
that list to a single entry — and can skip `detect` altogether, constructing the `SessionMigration`
from the `transcriptPath` it already stores on the terminal row. The transcript problem —
truncation, excerpting, summarization — does not exist on this path, because TBD never reads the
transcript.

Because the imported thread already contains the conversation, there is no handoff document to read
and therefore no initial prompt to send. A Codex terminal resumed on `target` opens with history and
an empty composer, spending no turn. That is the behavior a generated-summary design has to work to
approximate.

Two constraints bound any such integration.

The destructive one: `import` is a migration call whose sibling item types overwrite
`~/.codex/AGENTS.md`, `~/.codex/hooks.json`, `~/.codex/config.toml`, and installed skills and
plugins. A caller must construct `migrationItems` containing only the `SESSIONS` entry it intends. A
malformed array rewrites a user's Codex configuration.

The stability one: the protocol is experimental, and the client surface for it appeared upstream
within a single quarter. Committing daemon code against it means tracking a target that is still
moving.

Both point the same way under existing repo convention: such work ships behind a default-off flag,
and needs a spec before implementation.

## Relation to PR #561

`feat: add Continue in Codex handoffs` implements Claude-to-Codex handoff by generating a summary
document instead of using this surface. Its `DeterministicCodexHandoffGenerator` reads the last
64 KB of the session JSONL, keeps only `user` and `assistant` entries with non-empty text, renders
at most 8 KB of that, and caps the document at 16 KB.

On a representative long session — 2.7 MB across 1,655 lines — the 64 KB window is 2.3% of the
transcript, taken from the tail. The slice grows least representative exactly as sessions grow
longest, which is when a handoff is most wanted. The filter also discards structured entries that
answer "what is this session doing" more directly than the prose does: `ai-title` (a one-line
summary Claude Code maintains), `last-prompt` (the most recent instruction), `file-history-delta`
and `file-history-snapshot` (files touched), and `pr-link`.

Codex's own `detect` surfaces an equivalent one-line title per session without any of that
machinery, and `import` consumes the entire transcript rather than a window of it.
