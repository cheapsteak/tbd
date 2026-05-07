# Transcript-pane perf instrumentation

## Problem

Switching to a tab whose Claude session has thousands of items (target: maven-dashboard `511161cd-...jsonl`, 2372 JSONL lines / 5.1 MB / ~31 subagent files) freezes the app UI. We don't know which layer is responsible. The hypothesis that eager `VStack` rendering is the culprit is unverified — making `LazyVStack` swap a guess.

## Goal

Add focused, throwaway timing instrumentation across the transcript pipeline so a single repro produces a log timeline that pinpoints which layer dominates: daemon parse, RPC transit + decode, main-actor array swap, or SwiftUI render. Then we design the real fix from data.

Out of scope:

- Any fix. Pure measurement.
- New tooling (Instruments signposts, custom UI overlays). `os.Logger` + `log stream` is sufficient for one-shot diagnosis.
- Production-grade telemetry. Logs are diagnostic-only; they get demoted or deleted after the bottleneck is identified.

## Conventions

- Subsystems: `com.tbd.daemon` and `com.tbd.app` (existing).
- Category for every log added by this spec: `perf-transcript`.
- Level: `.debug`. Activated on demand with `log config --subsystem … --mode "level:debug,persist:debug"`; silent in normal use.
- Privacy: every dynamic interpolation gets explicit `privacy: .public` (this is a dev tool, all values are non-sensitive numbers, IDs, file paths).
- Format: structured key=value pairs, one log line per measurement, easy to grep. Always include a stable verb ( `parse.start`, `parse.end`, `pollOnce.end`, etc.) and a duration in milliseconds.
- Timing primitive: `ContinuousClock().measure { ... }` for synchronous regions. For async regions, capture `let start = ContinuousClock.now` and compute `Duration.formatted` at the end. Convert to integer ms for log readability.

## Instrumentation points

### Daemon (subsystem `com.tbd.daemon`)

1. **`TranscriptParser.parse(filePath:)`** — `Sources/TBDDaemon/Claude/TranscriptParser.swift`. Wrap the public entry. Log:
   - `parse.start file=<basename>`
   - `parse.end file=<basename> elapsed_ms=<n> items=<n> bytes=<n> subagents=<n>`
   - `bytes` is the total bytes read across the top JSONL plus every recursive subagent file. Track in a local accumulator passed through the recursion.
   - `subagents` is the count of subagent JSONLs encountered (not items).

2. **`terminal.transcript` RPC handler** — `Sources/TBDDaemon/Server/RPCRouter.swift:151`. Wrap the handler body covering parse + response encoding. Log:
   - `rpc.handle.start method=terminalTranscript`
   - `rpc.handle.end method=terminalTranscript elapsed_ms=<n> response_bytes=<n> items=<n>`
   - `response_bytes` is the size of the JSON-encoded RPC response payload returned to the client.

### App (subsystem `com.tbd.app`)

3. **`daemonClient.terminalTranscript`** — find this method in the app's `DaemonClient`/RPC layer (search for the call site referenced from `LiveTranscriptPaneView.pollOnce`). Wrap the entire async call including JSON decode of the response. Log:
   - `client.rpc.start method=terminalTranscript`
   - `client.rpc.end method=terminalTranscript elapsed_ms=<n> bytes=<n> decode_ms=<n> items=<n>`
   - Split `decode_ms` from total elapsed by timing the JSONDecoder step separately.

4. **`pollOnce`** — `LiveTranscriptPaneView.swift`. End-to-end wrap:
   - `pollOnce.start sid=<short>`
   - `pollOnce.end sid=<short> elapsed_ms=<n> changed=<bool> count=<n>`
   - Inside, time the `MainActor.run { ... }` block separately:
     - `pollOnce.mainActor.start sid=<short>`
     - `pollOnce.mainActor.end sid=<short> elapsed_ms=<n> equal_ms=<n> swap_ms=<n>`
     - `equal_ms` is the time `messagesEqual(prev, result.messages)` took.
     - `swap_ms` is the time the dictionary write + `touchSessionTranscript` took (zero if `equal == true`).

5. **`LiveTranscriptPaneView` view-appearance markers**. The freeze is observed on tab switch. Mark both ends of the user-visible gap:
   - On `transcriptWithAutoscroll`'s outer `ScrollView` `.onAppear`: `view.appear sid=<short> count=<n>`. This fires after SwiftUI has computed and laid out the view tree at least once for this tab.
   - On the `.task(id:)` startup at the top of `LiveTranscriptPaneView.body`: `task.start terminalID=<short>`. This fires when SwiftUI first attaches the task — slightly before `.onAppear` of nested views.
   - The wall-clock gap between `task.start` and `view.appear` is the user-perceived "view ready" time. If it's a multi-second gap with little daemon/RPC activity in between, the work is happening synchronously inside SwiftUI body/layout/render.

6. **`messagesEqual`** in `LiveTranscriptPaneView.swift`. Only log when one side has > 100 items (skip noise from cold polls). Log:
   - `messagesEqual elapsed_ms=<n> count_a=<n> count_b=<n> result=<bool>`

### App, optional layer 2 (skip unless layer 1 doesn't pinpoint it)

7. **`MarkdownSegments.split`** and **`Markdown(...)` realize** in `ChatBubbleView.swift`. Add a debug counter: `chatBubble.realize id=<short> prose_segments=<n> code_segments=<n> elapsed_ms=<n>`. Per-row log; expect noisy. Useful only if we suspect per-row markdown cost.

8. **Tool card decode hot paths** — `BashCard`, `EditCard`, `AgentCard`, `GenericToolCard`, etc. each call `JSONDecoder().decode(...)` from a computed body. Log per realize: `toolCard.decode card=<name> elapsed_ms=<n>`. Skip cards where decode takes < 1ms (which is most of them).

## Test recipe

Document this in the spec so the user (or whoever drives the test) follows the exact sequence:

1. Apply the patch.
2. `swift build` — must succeed cleanly.
3. `./scripts/restart.sh` (worktree-relative).
4. One-time per machine: `sudo log config --subsystem com.tbd.daemon --mode "level:debug,persist:debug"` and `sudo log config --subsystem com.tbd.app --mode "level:debug,persist:debug"`.
5. In a separate terminal: `log stream --level debug --predicate 'category == "perf-transcript"' --style compact`.
6. In TBD, open the maven-dashboard repo, switch to a Claude tab whose session is `511161cd-474e-4e23-9775-fd474b126ae5.jsonl`. (Confirm by checking the tab's `claudeSessionID`.)
7. Observe and capture the log stream output during the freeze.
8. Save the captured stream to `docs/superpowers/specs/perf-baseline-2026-05-06.txt` for later analysis.

## Expected output format

```
00ms   com.tbd.app    perf-transcript    task.start terminalID=AB12
04ms   com.tbd.app    perf-transcript    pollOnce.start sid=5111
05ms   com.tbd.app    perf-transcript    client.rpc.start method=terminalTranscript
06ms   com.tbd.daemon perf-transcript    rpc.handle.start method=terminalTranscript
07ms   com.tbd.daemon perf-transcript    parse.start file=511161cd-...jsonl
…      com.tbd.daemon perf-transcript    parse.end file=… elapsed_ms=420 items=2310 bytes=5_400_000 subagents=31
…      com.tbd.daemon perf-transcript    rpc.handle.end method=… elapsed_ms=480 response_bytes=5_500_000 items=2310
…      com.tbd.app    perf-transcript    client.rpc.end method=… elapsed_ms=720 bytes=5_500_000 decode_ms=210 items=2310
…      com.tbd.app    perf-transcript    pollOnce.mainActor.start sid=5111
…      com.tbd.app    perf-transcript    messagesEqual elapsed_ms=… count_a=0 count_b=2310 result=false
…      com.tbd.app    perf-transcript    pollOnce.mainActor.end sid=5111 elapsed_ms=… equal_ms=… swap_ms=…
…      com.tbd.app    perf-transcript    pollOnce.end sid=5111 elapsed_ms=… changed=true count=2310
[gap of N ms — UI appears frozen here]
…      com.tbd.app    perf-transcript    view.appear sid=5111 count=2310
```

Reading the timeline:

- Big number on `parse.end` → **daemon parse cost** dominates. Fix candidate: T2 parse caching, or T3 incremental parse.
- Big number on `client.rpc.end` minus `rpc.handle.end` → **RPC transit + decode**. Fix candidate: streaming RPC, or compress / shrink payload.
- Big number on `messagesEqual` → **deep equality check**. Fix candidate: identity-only comparison, or skip the check entirely on first-load case where prev is empty.
- Big number on `swap_ms` → unlikely; flag if so.
- Big gap from `pollOnce.end` to `view.appear` → **SwiftUI render cost**. Fix candidate: T1 LazyVStack (with the `proxy.scrollTo(lastID)` quirk addressed), deferred body, or chunked materialization.
- Repeated `client.rpc.end` events with full duration on every poll → **polling overhead**, not just first-load cost. Fix candidate: incremental fetch, or only re-render on actual changes.

## Cleanup

After the bottleneck is identified and fixed in a follow-up commit:

- Either delete the `perf-transcript` log statements wholesale (if they were single-shot diagnostic and have no ongoing value).
- Or demote them to `.trace` level and keep them for future regressions. Do NOT leave them at `.debug` — that's reserved for diagnostics that are silent by default and can be activated with `log config`. (`docs/diagnostics-strategy.md` is authoritative on level choice.)

The cleanup decision belongs to the follow-up PR that ships the fix, not this one.

## Risk

- Low. Logging adds nanoseconds per call; cannot affect the perf measurement itself meaningfully.
- The `ContinuousClock().measure` wrappers must be careful not to alter throw/control-flow — keep wrappers thin and pre-existing error-handling intact.
- `messagesEqual` instrumentation must not change `messagesEqual` semantics — wrap, don't inline-modify.

## Suggested commit shape

One commit:

```
chore: add perf-transcript timing logs across parse/RPC/poll/render

Throwaway diagnostic instrumentation under the perf-transcript log
category in both com.tbd.daemon and com.tbd.app subsystems. Wraps
TranscriptParser.parse, the terminal.transcript RPC handler, the app
RPC client call site, pollOnce + its mainActor block, messagesEqual,
and view.appear/task.start markers in LiveTranscriptPaneView.

Activate with:
  sudo log config --subsystem com.tbd.daemon --mode "level:debug,persist:debug"
  sudo log config --subsystem com.tbd.app --mode "level:debug,persist:debug"
  log stream --level debug --predicate 'category == "perf-transcript"'

Will be removed or demoted once the bottleneck is identified.
```
