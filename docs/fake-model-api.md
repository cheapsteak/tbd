# Fake model API: run the real `claude` with zero tokens

`scripts/claude-stub.py` starts a mock of the Anthropic Messages API on
loopback and runs the **real** `claude` CLI against it, so a whole session —
headless `-p` or the interactive TUI — happens offline, with no API key and
without spending tokens. The stub is a fake model, not a fake CLI: the binary,
its config, its hooks, its terminal rendering are all the genuine article;
only the answers are scripted locally, which makes them deterministic and
makes the run structurally zero-token.

Reach for it when you need a live agent session to look at something that has
nothing to do with what the model says — terminal rendering, resize behavior,
hook wiring, session files, spawn plumbing.

## What it is

The server is `stub_server.py` under
`.github/workflows/claude-review-v2/tests/e2e/`: a stdlib fake of
`POST /v1/messages` that answers in SSE from a list of canned turns. It was
built for the PR-review gate's e2e tests, and that directory's `README.md`
documents the review-gate scenarios it scripts. `claude-stub.py` is the
general-purpose front door to the same server: it builds the sandbox, starts
the server, runs `claude` in your current directory, and prints a summary of
what the stub served.

## Quick start

Run it from a throwaway directory unless you mean otherwise — `claude` runs in
your current working directory and picks up that project's
`.claude/settings.json`, hooks and permissions.

Headless, one scripted answer:

```sh
scripts/claude-stub.py --text "hello from the stub" -- -p "say hello"
```

```
hello from the stub
claude-stub: 1 request(s) served at http://127.0.0.1:51548
claude-stub: unexpected paths: none
claude-stub: client disconnects: 0
claude-stub: no request left this machine — ANTHROPIC_BASE_URL was http://127.0.0.1:51548 (loopback)
```

Everything after `--` goes to `claude`. With nothing after it you get the
interactive TUI. The summary goes to stderr, so `-p` output stays pipeable, and
the wrapper exits with `claude`'s own status.

Piping into it from a script is worth one flag: `claude -p` waits ~3 s for
stdin when stdin is not a terminal, so add `< /dev/null` in non-interactive
callers.

## Interactive TUI, and resize

With no arguments after `--`, `claude-stub.py` opens the real TUI. The default
turn script is one long numbered answer (`--lines`, default 200) — the shape
that fills the scrollback and exercises the renderer:

```sh
scripts/claude-stub.py --lines 200
```

Driven inside a 120x40 tmux window, typing a prompt renders the whole scripted
answer:

```
  197. stub answer line 197 of 200 — filler so the answer is long enough to scroll.
  198. stub answer line 198 of 200 — filler so the answer is long enough to scroll.
  199. stub answer line 199 of 200 — filler so the answer is long enough to scroll.
  200. stub answer line 200 of 200 — filler so the answer is long enough to scroll.
```

Resizing that window to 100x30 delivers a SIGWINCH to the CLI, which reflows
and repaints against the new width — the session survives it and stays at the
prompt. That is the loop for measuring what the CLI emits on a resize: hold a
long answer on screen, resize, read what came back.

`/exit` ends the session and the summary follows:

```
claude-stub: 2 request(s) served at http://127.0.0.1:51707
claude-stub:   route (ordered turns): 1
claude-stub:   route session title: 1
claude-stub: unexpected paths: none
claude-stub: client disconnects: 0
claude-stub: no request left this machine — ANTHROPIC_BASE_URL was http://127.0.0.1:51707 (loopback)
```

Two requests, because the TUI opens every session with a second, concurrent
request asking the model to name the session. That one is answered from its
own content-keyed route so it cannot eat a scripted turn; headless `-p` sends
none.

The interactive TUI also raises one dialog headless mode never does — "Detected
a custom API key in your environment … use this API key?" — so the wrapper
pre-approves the stub key under `customApiKeyResponses` in the sandbox's
`.claude.json`, on top of the trust and onboarding keys the e2e harness already
writes. Without it the session stops on that prompt instead of reaching the
composer.

## Driving `claude` by hand from another pane

`--print-env` starts the server, prints shell-quoted `export` lines, and keeps
serving until SIGINT or SIGTERM. Use it when you want to type into `claude`
yourself, or run it under instrumentation, rather than have the wrapper launch
it:

```sh
# pane 1
scripts/claude-stub.py --print-env --text 'served via print-env' --sandbox /tmp/stub-sandbox
```

```
export ANTHROPIC_API_KEY=stub-key
export ANTHROPIC_BASE_URL=http://127.0.0.1:64112
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CONFIG_DIR=/tmp/stub-sandbox/config
export HOME=/tmp/stub-sandbox
export NO_PROXY=127.0.0.1,localhost
export TERM=tmux-256color
export TMPDIR=/tmp/stub-sandbox/tmp
```

```sh
# pane 2
eval "$(cat exports.sh)"
claude -p 'hi'          # -> served via print-env
```

`PATH` is deliberately not exported — you already have your own. Ctrl-C (or a
`SIGTERM` to the process) stops the server and prints the same summary:

```
claude-stub: 1 request(s) served at http://127.0.0.1:64112
claude-stub: unexpected paths: none
claude-stub: client disconnects: 0
claude-stub: no request left this machine — ANTHROPIC_BASE_URL was http://127.0.0.1:64112 (loopback)
```

## The turn file

`--turns FILE.json` scripts more than one answer. Request N is served turn N:

```json
[
  {"text": "first scripted answer"},
  {"text": "second scripted answer"}
]
```

A turn may also carry tool calls, which is how you drive the CLI's tool loop:

```json
[
  {
    "text": "Writing the file.",
    "tool_calls": [
      {"name": "Write", "input": {"file_path": "/tmp/out.json", "content": "{}"}}
    ]
  },
  {"text": "Done."}
]
```

The object form adds content-keyed routing for parallel subagents, where
request order is nondeterministic and ordered indexing cannot work. Each key is
a sentinel string; a request whose **first** message contains it is served from
that key's own list, with its own per-route index, and anything unmatched falls
back to `turns`:

```json
{
  "turns": [{"text": "orchestrator turn 1"}],
  "role_turns": {
    "ROLE-CORRECTNESS": [{"text": "correctness specialist"}],
    "ROLE-SECURITY": [{"text": "security specialist"}]
  }
}
```

Put the sentinel in the subagent's Task prompt, and the routing follows it.

## What the stub models, and what it does not

- **Only `POST /v1/messages`.** Every other path — `count_tokens` included —
  gets a 404 and is recorded. The summary reports those as unexpected paths,
  minus the one `/api/hello` connectivity preflight the CLI sends per
  invocation and shrugs off.
- **SSE only, never plain JSON.** The CLI sends `stream: true`; answered with
  a plain body it silently retries a byte-identical request forever while
  executing nothing.
- **Scripted turns, not a model.** Answers are whatever you wrote. Requests
  past the end of the script get the overflow turn, whose text is
  `STUB-TERMINAL`, so a short script ends a session instead of hanging it.
- **No usage accounting, no rate limits, no auth.** The key is the literal
  string `stub-key` and nothing checks it.

## Isolation, and why tokens are structurally zero

The sandbox is a fresh directory used as `HOME` and `CLAUDE_CONFIG_DIR`, with
its own `TMPDIR` and a pre-written `.claude.json`. Your real `~/.claude` is
untouched, and the session's transcript lands in the sandbox. It is deleted at
exit unless you pass `--keep` or name it with `--sandbox` (an explicit sandbox
is always kept). `TERM`, `COLORTERM`, `LANG` and `LC_ALL` pass through from
your terminal, and `--env KEY=VALUE` overrides anything.

Tokens are zero by construction rather than by policy: `ANTHROPIC_BASE_URL`
points at `http://127.0.0.1:<port>`, so requests cannot leave the machine, and
the only credential in the environment is a placeholder. The summary's request
count is what the loopback server actually answered — if the CLI had reached an
upstream, the count would not add up.

## Pointing a TBD session at it

A TBD `proxy` model profile carries its own `ANTHROPIC_BASE_URL`, and that env
is what a spawned Claude session gets (see [`env-overrides.md`](env-overrides.md)
for how profile env layers over repo and global overrides). That is the seam
for aiming a TBD-spawned session at a running `--print-env` server rather than
at the real API.
