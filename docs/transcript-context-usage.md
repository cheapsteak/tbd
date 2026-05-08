# Reading Context Usage from Claude Code Transcripts

Claude Code does not expose a CLI command, RPC, or hook for "how full is the context window right now." But every assistant turn in the on-disk transcript records the exact token counts the API used, so the transcript viewer can derive context usage by reading the file.

## Where the data lives

Each session writes a JSONL file to:

```
~/.claude/projects/<slugified-cwd>/<sessionId>.jsonl
```

One line per event. Assistant turns carry a `message.usage` object populated from the Anthropic API response:

```json
{
  "type": "assistant",
  "message": {
    "usage": {
      "input_tokens": 1,
      "cache_creation_input_tokens": 1077,
      "cache_read_input_tokens": 41667,
      "output_tokens": 261,
      "cache_creation": {
        "ephemeral_5m_input_tokens": 0,
        "ephemeral_1h_input_tokens": 1077
      }
    }
  }
}
```

User messages, tool results, and system events do **not** carry `usage` — only assistant turns do.

## Computing context used

The number `/context` shows is the total prompt size sent on the most recent request:

```
context_used = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

`output_tokens` is the model's reply and is **not** part of the prompt size — exclude it from the "context used" figure.

To get the latest value, scan the JSONL backwards (or forwards, taking the last hit) for an `assistant` line with a `message.usage` object and apply the formula above.

## When assistant lines are written

An assistant line is written **every time the API returns a response**, not once per user prompt. A single user message typically produces several assistant lines if the turn involves tools:

```
user message
  → assistant line (text + tool_use)        ← usage snapshot #1
tool_result (recorded as a "user" line)
  → assistant line (more tool_use)          ← usage snapshot #2
tool_result
  → assistant line (final text)             ← usage snapshot #3
```

Each line's `usage` reflects the prompt as it was for *that* API call. Within one user turn the numbers climb monotonically — call #2's prompt includes call #1's output plus the tool result, call #3's includes everything before it, and so on. The viewer can poll the file during a long tool-heavy turn and watch context grow in near real time.

Two structural notes that matter for rendering:

- **Tool results are stored as `type: "user"` lines** with a `tool_result` content block, even though the user didn't type them. They carry no `usage`. Don't render them as user chat bubbles.
- **Sidechain / subagent calls** appear in the same JSONL with `isSidechain: true` and their own `usage` values. They run in a separate context window from the parent session, so don't fold their usage into the parent's "context used" figure — show them separately or skip them when computing the headline number.

## Semantics: it's a per-request snapshot, not a running total

Each assistant turn's `usage` records the size of *that one API request*. Every turn re-sends the system prompt + every prior message, so consecutive turns overlap massively — **don't sum them**. The latest turn's value already represents "everything in context as of that request."

The number is immutable once written. Re-reading the file later returns the same value.

## Caveats for the UI

- **Lag vs. live.** The recorded value reflects the last request the model answered. Between then and now, the user may have typed a new message, tools may have produced output, and new `<system-reminder>` blocks may have been injected. The next turn will be larger. Show the value as "as of last response," not "right now."
- **Compaction resets it.** Auto-compact rewrites the prompt, so post-compact turns show a much smaller number. This is a real drop, not a bug — the viewer should render it as such (e.g. a step-down in a sparkline rather than smoothing across it).
- **Window size is model-dependent.** The denominator (200K, 1M, etc.) comes from the model name on the same assistant message, not from `usage` itself. Read `message.model` and map it to the limit.
- **Cache splits are informational.** `cache_read_input_tokens` is the bulk of context once a session warms up; `cache_creation_input_tokens` is the newly added portion that just got cached; `input_tokens` is whatever wasn't cacheable. They all count toward the window equally — the split only matters for cost/latency display.

## Hooks can read the same data

Claude Code hooks (`Stop`, `SubagentStop`, `PostToolUse`, `PreCompact`, `Notification`, etc.) do not receive `usage` in their stdin payload, but every hook event includes a `transcript_path` field pointing at this same JSONL file. A hook script can read it, scan backward for the last `type: "assistant"` line, and compute context size with the formula above — exactly the same logic the viewer uses. Good fits:

- `Stop` — log final context size per turn.
- `PreCompact` — record the pre-compact size for a "compacted at X tokens" trail.
- `Notification` — warn the user when context crosses a threshold.

Worth factoring the parser into a shared helper so the viewer and any hook scripts agree on what counts.

## Viewer surface

Show `context_used / window_size` only on the **latest** assistant line, collocated with that message — no per-turn history, no sparkline, no display on older messages. Render it diminutively (small, muted) since it's reference info, not primary content. Older assistant lines all carry their own `usage` too, but those values are stale and would just clutter the transcript.
