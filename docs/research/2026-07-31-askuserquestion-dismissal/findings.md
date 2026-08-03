# AskUserQuestion lifecycle: what answering, Escape, and hook-deny actually emit

**Status:** Tested, all four cases completed. 2026-07-31 (UTC 2026-08-01).
**Claude Code:** `2.1.220`. **Model:** `claude-haiku-4-5-20251001`. **Permission mode:** `default`.
**Harness:** isolated tmux server (`-L aq-test`), four fresh working directories, hooks
registered via `--settings` for PreToolUse / PostToolUse / PostToolUseFailure /
Notification / UserPromptSubmit / Stop / SessionStart, all with matcher `*`. Each hook
appended its full stdin JSON plus a millisecond wall-clock timestamp to a log. The
session transcript JSONL was polled every 20 ms to timestamp line arrival.

`PostToolUseFailure` **is** supported in 2.1.220 (verified by a control observation below).

## The five answers

**1. Escape → what event? → NONE.** No `PostToolUse`, no `PostToolUseFailure`, no
`Stop`. The last hook of the turn is the `PreToolUse` that opened the picker (plus an
idle `Notification` about six seconds later). Any design assuming "Escape → PostToolUse
fires" is assuming something false.

This is a real negative, not a misconfiguration — see the control observation, where the
*same settings file* delivered a `PostToolUseFailure` for a failed Bash tool.

**2. What lands in the JSONL after Escape** — four lines, flushed together 175 ms after
the keystroke: the buffered `assistant`/`tool_use`; a `user`/`tool_result` with
`is_error: true` and `toolUseResult: "User rejected tool use"`; a second `user` line with
text `[Request interrupted by user for tool use]`; a `system`/`turn_duration`. The
cancellation marker is the **generic tool-rejection payload** — nothing
AskUserQuestion-specific; join on `tool_use_id` to attribute it.

**3. Normal answer, PostToolUse → tool_result gap: ~165–175 ms**, measured twice
(165 ms, 173 ms; ±20 ms poller resolution). TBD's "JSONL lags PostToolUse" code comment
is correct in direction, and the lag is small and consistent.

**The bigger finding sits upstream.** While the picker is open the transcript contains
**no record of the question at all** — the `assistant` line holding the `tool_use` is
buffered and written only together with the result. Run 1: `PreToolUse` at `…458962`,
nothing on disk until `…468127` — **9.2 s of file silence spanning the whole dialog**.
The `tool_use` line's own `timestamp` field is honest (`03:04:18.952Z` ≈ the PreToolUse
instant); only the flush is deferred. Any code that discovers a pending question by
reading the transcript sees nothing until it is already answered or cancelled.
**`PreToolUse` is the only live discovery signal.** (Control: in the deny case, where no
dialog rendered, the `tool_use` reached disk 381 ms after `PreToolUse` — so the
buffering is tied to the open dialog, not a general write delay.)

**4. Escape then typed text → clean.** Text landed in the composer (confirmed by
capture-pane *before* Enter), Enter submitted, `UserPromptSubmit` about one second
later, the model replied, `Stop` fired. The transcript records an ordinary `user` line,
plain string content, `userType: "external"` — indistinguishable from any typed prompt.
No residue from the cancelled question. The Escape-then-paste delivery sequence works.

**5. PreToolUse deny → picker never renders.** `PreToolUse` fires (logger and denier),
then nothing tool-shaped: no PostToolUse, no PostToolUseFailure, no Notification.
`Stop` fires normally ~4.9 s later because the model just narrates the block. The
transcript **does** get a matched pair — `tool_use` plus `tool_result` with
`is_error: true` carrying the hook's `permissionDecisionReason`, and
`toolUseResult: "Error: <reason>"`. Nothing strands in the transcript.

From the **hook stream's** point of view, though, a blocked tool looks exactly like
Escape: an opened `PreToolUse` with no closing event. A pending-question store that
opens an entry on `PreToolUse` and closes it on `PostToolUse` strands that entry on
**both** the deny case and the ordinary Escape gesture. The transcript record is the
reliable closing signal; a GC on hook-keyed entries is load-bearing, not a safety net.

## Observed facts

### Control — the PostToolUseFailure hook was genuinely wired

A shell command accidentally submitted as a prompt mid-experiment ran as Bash and
failed. The same settings file delivered:

```json
{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_01LyjSqG3uHF6RoHs7evCcH9","_ts":1785553524078}
{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"toolu_01LyjSqG3uHF6RoHs7evCcH9","error":"Exit code 1\nError: Input must be provided either through stdin or as a prompt argument when using --print","is_interrupt":false,"duration_ms":1231,"_ts":1785553525352}
```

Note `is_interrupt` exists on that payload — which makes the event's *absence* on
Escape more notable, since a user interrupt is exactly what the field is for.

### Case 1 — normal answer (session `36951226-…`, work1)

```
SessionStart      1785553431378
UserPromptSubmit  1785553454632
PreToolUse        1785553458962  AskUserQuestion  toolu_01QMFdm7iVZT3ZUtA596CEPV
Notification      1785553465006  (+6044 ms)
PostToolUse       1785553467962  (15 ms after the Enter keystroke at 1785553467947)
Stop              1785553469342
```

PreToolUse payload (paths elided):

```json
{"session_id":"36951226-a9f9-4004-81cd-3810879c3ca4","prompt_id":"3bf4e96f-cebe-4a76-a60b-7ca304a987b7","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Are you working on a coding task right now that you'd like help with?","header":"Current Task","options":[{"label":"Yes","description":"I have a specific task I want assistance with"},{"label":"No","description":"I'm just exploring or have a general question"}],"multiSelect":false}]},"tool_use_id":"toolu_01QMFdm7iVZT3ZUtA596CEPV","_ts":1785553458962}
```

Notification payload:

```json
{"session_id":"36951226-…","prompt_id":"3bf4e96f-…","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt","_ts":1785553465006}
```

PostToolUse payload:

```json
{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":["…"],"answers":{"Are you working on a coding task right now that you'd like help with?":"No"},"annotations":{}},"tool_response":{"questions":["…"],"answers":{"Are you working on a coding task right now that you'd like help with?":"No"},"annotations":{}},"tool_use_id":"toolu_01QMFdm7iVZT3ZUtA596CEPV","duration_ms":0,"_ts":1785553467962}
```

Two details worth carrying forward: `PostToolUse.tool_input` is **mutated** — it carries
an `answers` map absent from `PreToolUse.tool_input`; and `duration_ms: 0` (the dialog
wait is not counted).

Transcript `tool_use` (first on disk at `1785553468127`):

```json
{"type":"assistant","timestamp":"2026-08-01T03:04:18.952Z","uuid":"08859ed6-929f-4bc9-ac56-2903164e2e9a","message":{"content":[{"type":"tool_use","id":"toolu_01QMFdm7iVZT3ZUtA596CEPV","name":"AskUserQuestion","input":{"questions":[{"question":"Are you working on a coding task right now that you'd like help with?","header":"Current Task","options":[{"label":"Yes","description":"I have a specific task I want assistance with"},{"label":"No","description":"I'm just exploring or have a general question"}],"multiSelect":false}]},"caller":{"type":"direct"}}]}}
```

Transcript `tool_result`:

```json
{"type":"user","timestamp":"2026-08-01T03:04:27.998Z","uuid":"62aa2ab2-9574-4d6d-99aa-ddb35667774f","message":{"role":"user","content":[{"type":"tool_result","content":"Your questions have been answered: \"Are you working on a coding task right now that you'd like help with?\"=\"No\". You can now continue with these answers in mind.","tool_use_id":"toolu_01QMFdm7iVZT3ZUtA596CEPV"}]},"toolUseResult":{"questions":["…"],"answers":{"Are you working on a coding task right now that you'd like help with?":"No"},"annotations":{}}}
```

Arrival timeline (`_seen_ts`): `…455574` ai-title → *nothing for 12.5 s* → `…468127`
thinking + tool_use + tool_result + attachments in one batch → `…469443` assistant text,
`stop_hook_summary`, `turn_duration`.

Second normal-answer run (session `bbbdfeeb-…`, work3) reproduced it:
`PreToolUse 1785553755404` → `Notification 1785553761455` (+6051 ms) →
`PostToolUse 1785553762135` → transcript batch `1785553762308` (**173 ms**) →
`Stop 1785553764074`.

### Case 2 — Escape (fresh session `a5722b72-…`, work2)

Fresh session, fresh cwd, fresh log. Escape at `1785553580635`; observed 15 s,
rechecked +6 s. Complete hook log — the Escape added nothing:

```json
{"_event":"SessionStart","_ts":1785553524898}
{"_event":"SessionStart","_ts":1785553549030}
{"_event":"UserPromptSubmit","_ts":1785553561939}
{"_event":"PreToolUse","_ts":1785553566380,"tool_name":"AskUserQuestion"}
{"_event":"Notification","_ts":1785553572418,"notification_type":"permission_prompt","message":"Claude needs your permission"}
```

The turn ended (composer idle, `turn_duration` written) but **`Stop` did not fire** —
interrupted, not completed. `Stop` *did* fire later in this same session for the Case-3
turn, so the hook was live.

Transcript, verbatim, all flushed together at `1785553580810`:

```json
{"type":"assistant","timestamp":"2026-08-01T03:06:06.370Z","uuid":"424305e5-80bc-49d8-9569-a8a91526ec8f","message":{"content":[{"type":"tool_use","id":"toolu_01M9uYydXW7ax5KFmqUuYuBp","name":"AskUserQuestion","input":{"questions":[{"question":"Are you working on a specific task or feature today?","header":"Session Intent","options":[{"label":"Yes, I have a specific task","description":"I want to work on a particular feature, bug fix, or other defined work"},{"label":"No, I'm exploring or learning","description":"I'm browsing, investigating, or figuring out what to do"}],"multiSelect":false}]},"caller":{"type":"direct"}}],"stop_reason":"tool_use"}}
```

```json
{"type":"user","timestamp":"2026-08-01T03:06:20.692Z","uuid":"9a4b1079-9f30-4307-bfd7-0f3962cfbd0f","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.","is_error":true,"tool_use_id":"toolu_01M9uYydXW7ax5KFmqUuYuBp"}]},"toolUseResult":"User rejected tool use"}
```

```json
{"type":"user","timestamp":"2026-08-01T03:06:20.693Z","uuid":"ff5d4eee-f719-4c2f-be76-bff33e13f493","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"toolUseResult":null}
```

```json
{"type":"system","timestamp":"2026-08-01T03:06:20.694Z","uuid":"fe1d8b6f-7a68-434d-b015-e3a2c97fe9bf","subtype":"turn_duration","isMeta":false}
```

Pane after:

```
⏺ User declined to answer questions
  ⎿  · Are you working on a specific task or feature today? (Yes, I have a specific task / No, I'm exploring or learning)

✻ Cooked for 18s
```

Composer idle, no error state, turn over, model not re-prompted.

### Case 3 — Escape then new input (same session as Case 2)

Text sent 41 s after the Escape. Confirmed on the pane *before* Enter that the literal
text sat in the composer. Events: `UserPromptSubmit 1785553623065`, `Stop 1785553625959`.

```json
{"type":"user","timestamp":"2026-08-01T03:07:03.057Z","uuid":"ae0686c3-f153-4f0f-81c1-14a5af30ca9d","isMeta":null,"isCompactSummary":null,"userType":"external","message":{"role":"user","content":"My answer is: No, I'm exploring. Just reply OK."}}
```

Model replied `OK.`; `stop_hook_summary` + `turn_duration` written.

### Case 4 — PreToolUse deny (session `ce14a79f-…`, work4)

Second `PreToolUse` entry, `matcher: "AskUserQuestion"`, emitting on stdout:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"EXPERIMENT: AskUserQuestion blocked by PreToolUse hook."}}
```

Picker never rendered. Hooks:

```json
{"_event":"SessionStart","_ts":1785553680875}
{"_event":"UserPromptSubmit","_ts":1785553688120}
{"_event":"PreToolUse","_ts":1785553693841,"tool_name":"AskUserQuestion"}
{"_event":"PreToolUse-DENYHOOK","_ts":1785553694100,"tool_name":"AskUserQuestion"}
{"_event":"Stop","_ts":1785553698727}
```

Transcript:

```json
{"type":"assistant","timestamp":"2026-08-01T03:08:13.830Z","uuid":"f6dacdf6-34d7-48e4-99c3-6529cab6cfed","message":{"content":[{"type":"tool_use","id":"toolu_01W1DMCJSKDk8vkZrDjAbc9w","name":"AskUserQuestion","input":{"questions":[{"question":"Would you like to share anything about your current project or workflow that would help me assist you better in future conversations?","header":"Context","options":[{"label":"Yes","description":"I'd like to share context about my work or preferences"},{"label":"No","description":"Not right now"}],"multiSelect":false}]},"caller":{"type":"direct"}}]}}
```

```json
{"type":"user","timestamp":"2026-08-01T03:08:14.105Z","uuid":"9f57ce9e-24e1-401e-9b4e-b68e41701645","message":{"role":"user","content":[{"type":"tool_result","content":"EXPERIMENT: AskUserQuestion blocked by PreToolUse hook.","is_error":true,"tool_use_id":"toolu_01W1DMCJSKDk8vkZrDjAbc9w"}]},"toolUseResult":"Error: EXPERIMENT: AskUserQuestion blocked by PreToolUse hook."}
```

Arrival 381 ms after `PreToolUse`. Pane showed `⎿ Error: EXPERIMENT: …`, a narration
paragraph, then `✻ Churned for 10s`.

### Incidental — `Notification` is a reliable "question is waiting" signal

`notification_type: "permission_prompt"`, `message: "Claude needs your permission"`,
fired in all three cases where the picker rendered, at a strikingly consistent delay
after `PreToolUse`: **+6044 ms, +6038 ms, +6051 ms**. Did **not** fire in the deny case.
Carries no `tool_name` or `tool_use_id`, so it cannot be joined to a specific question —
it only says "this session is blocked on the user." Later than `PreToolUse`, but unlike
`PreToolUse` it does not fire for tools that never block.

## Caveats

- **One version, one model.** `2.1.220` + haiku-4.5 only. Hook semantics are internal
  behavior, not a documented contract; the Escape-fires-nothing result could change in
  any release. Re-run before relying on it across a version bump.
- **Permission mode `default`** only. Not tested under `acceptEdits`, `plan`, or
  `bypassPermissions`.
- **Single-question dialogs only** — one question, two options, every time.
  Multi-question arrays and `multiSelect: true` were not exercised; the `answers` shape
  under those is unverified.
- **The "Type something" and "Chat about this" picker rows were not exercised** — only
  arrow-key + Enter, and Escape. Free-text answering may yield a different
  `toolUseResult`.
- **Escape sent exactly once.** A second Escape (normally interrupts the turn) untested;
  nor held or double-tapped.
- **Timing resolution ±20 ms** (poller sleep) plus a few ms of hook-process startup
  before `_ts` is stamped. Read 165/173 ms as "roughly 150–200 ms", not a precise
  constant.
- **Transcript flush semantics were inferred from external polling**, not from
  instrumenting the writer. "The `tool_use` line is buffered while the dialog is open"
  rests on the poller seeing no file growth for 9.2 s — strong, but an observation of
  the file, not the code.
- **Daemon-restart-mid-dialog: untested.** What happens to a pending AskUserQuestion
  when the supervising process dies and reattaches remains open.
- **Cases 2 and 3 shared one session** (deliberately — that is the sequence TBD plans to
  use); Cases 1 and 4 had their own.
- The one accidental prompt submission in session 1 contaminated no measurement (Case 1
  was already complete) and supplied the `PostToolUseFailure` control observation.

## What this means for the design

Three things to absorb: (1) **Escape emits no hook event whatsoever** — a
pending-question entry opened on `PreToolUse` and closed on `PostToolUse` strands on the
single most likely user gesture, so transcript-record clearing is the mechanism and the
GC is load-bearing, not a safety net; (2) **the transcript is blind while a question is
pending** — `PreToolUse` is the only live discovery signal, and the `Notification` at
+6 s is the only secondary confirmation; (3) **the Escape-then-paste flow works
cleanly**, and the resulting text is an ordinary user message with no special marking.
