# `tbd terminal send --submit` silent non-submit — design brief

**Status:** Option 2 shipped (PR #389); Option 3 implemented (PR #398) then removed as dead code (2026-07-09) — see "Implementation Status" below
**Branch:** `tbd/submit-reliability-brainstorm`
**Author:** investigation session, 2026-07-08

## TL;DR

`--submit` frequently fails to submit **large / multi-line** messages: the text
lands in the target TUI's input box but is never sent, sitting unsent at the `❯`
prompt as `[Pasted text #N]`. Short messages submit fine.

Root cause (reproduced at the byte level): the daemon delivers the message body
with `tmux send-keys -l` and then sends Enter with a second `tmux send-keys
Enter`. For payloads larger than the pty buffer (~1 KB) the body is split by the
pty into **multiple rapid reads**. Claude Code (and Codex) treat that multi-read
burst as a *non-bracketed paste* and open a short coalescing window; the Enter
(`\r`) that follows a few milliseconds later lands **inside that window** and is
absorbed as pasted content instead of being processed as a submit key. Small
payloads arrive in a single read, are not detected as a paste, and their Enter
submits normally.

**Recommendation:** deliver the body as an *explicit bracketed paste*
(`load-buffer` + `paste-buffer -p`, the same mechanism the GUI paste path already
uses) and send Enter as a separate keystroke. The explicit `ESC[201~` terminator
makes the Enter unambiguously outside the paste, so it can never be absorbed.
This is a root-cause fix, TUI-agnostic, and empirically verified to submit large
multi-line messages. Optionally layer a verify-and-retry step so the unattended
(nightwatch) path can *detect* a non-submit rather than trust it blindly.

## The mechanism (current code)

`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:1324` —
`handleTerminalSend`:

```swift
try await tmux.sendKeys(server: …, paneID: …, text: params.text)   // send-keys -l  <text>
if params.submit == true {
    try await tmux.sendKey(server: …, paneID: …, key: "Enter")     // send-keys      Enter
}
```

`sendKeys` → `send-keys -l -t <pane> <text>` (literal), `sendKey` →
`send-keys -t <pane> Enter` (key name → `\r`). Two separate `tmux` subprocess
invocations, sequential. This is the **only** send path that pushes
arbitrary-size text through raw `send-keys -l`. It is unconditional — no
control-mode branch, no size threshold. (`LimitResumeActuator` and any other
daemon-originated sends go through the same two `TmuxManager` methods, so they
share the bug.)

Note the contrast with the **GUI paste path**, which already does the right
thing: app-level paste interception → `.paste` sidecar frame →
`ControlModeInputRouter.deliverPaste` → `PasteExecutor.paste` →
`load-buffer` + `paste-buffer -d -p` (bracketed), and the user's Enter arrives
later as a separate `.input` keystroke frame. That path is robust; the CLI path
is not.

## Evidence (reproductions)

All runs used tmux 3.6a and real Claude Code v2.1.205, in isolated `tmux -L`
servers (the live fleet was never touched).

**1. The pty splits a large `send-keys -l` into multiple reads.**
A 2000-byte `send-keys -l` observed by a raw pty reader arrived as:

```
read len=1022   (body)
read len= 978   (body)
read len=   1   b'\r'   ← the Enter, a separate read right after
```

The ~1 KB split is the pty buffer boundary. The Enter follows within
milliseconds.

**2. Small payload → submits (no paste UI).**
596-byte multi-line body via `send-keys -l` + Enter → Claude submitted
immediately; body shown inline, *not* collapsed to `[Pasted text]`.

**3. Large payload → the reported failure, exactly.**
1609-byte multi-line body via `send-keys -l` + Enter (the exact daemon path):

```
❯ [Pasted text #1]e.Item 14: … Item 20: … When finished reply with exactly: ACKF
```

Input box **non-empty**, message **unsent**, no "Brewing/Baked" — Enter absorbed.
This is the reported `[Pasted text #N]` symptom. The first pty chunk collapsed to
`[Pasted text #1]`; the second chunk appended as raw text; the trailing `\r` was
swallowed into the paste.

**4. Bracketed paste + separate Enter → submits, even large.**
Same ~1.2–1.6 KB multi-line body delivered via `load-buffer` + `paste-buffer -d
-p` then `send-keys Enter` → Claude submitted and replied `ACKG`; input box
cleared. The explicit `ESC[201~` terminator ends the paste before the Enter
arrives.

**5. No regression for plain shells.**
`paste-buffer -p` into a pane with bracketed-paste mode **off** (a plain shell)
sends **bare** bytes — `hello from paste\nsecond line\n` — no `ESC[200~/201~`.
tmux wraps *iff* the pane enabled the mode (`CSI ?2004h`), so shells behave
exactly as today and only TUIs that opt in get bracketed.

**6. Fixed-delay-before-Enter is flaky.**
Inserting sleeps (50/150/300/600 ms) between the raw `send-keys -l` and the Enter
gave inconsistent submit/non-submit results across runs — the coalescing window
is not a clean fixed value and stretches under load. Confirms the "just wait then
press Enter" hypothesis is fragile.

## Why short works and long doesn't (the crux)

- **Short (≤ ~1 KB):** one pty read → not a burst → not detected as a paste → the
  following `\r` is a distinct keypress → **submits**.
- **Long (> ~1 KB or enough to look pasted):** multi-read burst → detected as a
  non-bracketed paste → coalescing window open → the `\r` lands inside it →
  **absorbed**, message sits unsent.
- **The "later short append flushed everything":** the short send wasn't a burst,
  so *its* Enter was processed as submit and flushed the accumulated buffer —
  consistent with the report.

The failure is not tmux adding brackets (it doesn't, for `send-keys -l`) and not
a trailing `\r` being *literally pasted by design*. It is the TUI's
**non-bracketed paste-burst detection** mistaking a chunked `send-keys` for a
paste and eating the Enter.

## Options weighed

### Option 1 — Delay before Enter *(rejected)*
Sleep between the text and the Enter. Trivial, but the coalescing window is
undocumented, version-dependent, and load-dependent (evidence #6). Under load the
chunks themselves spread, so a "safe" delay can still fall inside the window; adds
latency to every submit; does nothing for detectability. **Reject.**

### Option 2 — Bracketed-paste delivery + separate Enter *(recommended, primary)*
Deliver `text` via `load-buffer` + `paste-buffer -d -p` (mode-aware bracketing),
then `send-keys Enter`.
- **Pros:** root-cause fix — the explicit `ESC[201~` terminator puts the Enter
  provably outside the paste, so it can't be absorbed (no timing dependence).
  TUI-agnostic (standard bracketed-paste protocol; both Claude Code and Codex
  enable `?2004h` — see `SwiftTermModeEscapeSmokeTests`). Mirrors the
  already-working GUI paste path (`PasteExecutor`). Mode-aware → no shell
  regression (evidence #5). Verified to submit large messages (evidence #4). Low
  complexity; implementable over the plain `tmux -L` subprocess path already used
  by `handleTerminalSend`, so **no new coupling to the `-CC` control connection.**
- **Cons:** slightly changes `--text` semantics for embedded escape/control
  bytes (they'd be literal pasted text) — but `send-keys -l` already treats
  `--text` as literal, so this is near-equivalent in practice. Does not by itself
  make a non-submit *detectable*. Rare transient edge: if the TUI is momentarily
  not at its prompt (mode off), the paste falls back to bare bytes and the burst
  risk returns — orthogonal to this fix and mitigated by Option 3.

### Option 3 — Verify-and-retry + trustworthy result *(recommended, follow-up)*
After submitting, capture the pane and check whether the input was actually
consumed (input box cleared / no residual `[Pasted text]`); on a detected
non-submit, retry Enter with bounded attempts, and return a real
success/failure so the CLI exit code / RPC result can be trusted.
- **Pros:** makes the silent non-submit **detectable and self-healing** — the
  thing the unattended nightwatch path most needs (today `dispatch()` in
  `NightwatchSkillContent.swift:405` fires `--submit` and returns `True`
  unconditionally, so a drop is invisible). Defense-in-depth on top of Option 2.
- **Cons:** TUI-coupled — "did it submit?" needs per-TUI heuristics (Claude vs
  Codex render differently); capture is async so it races the render (needs
  bounded polling, cf. condition-based waiting); a wrong "not submitted" verdict
  could double-send Enter (usually harmless, but could confirm an unrelated
  dialog). Best scoped to the agent TUIs, not shells.

### Option 4 — Make `--submit` return submit-success
Only meaningful *with* Option 3's verification (the daemon otherwise has no way to
know). Folds into Option 3.

## Recommendation

1. **Ship Option 2 now.** It removes the root cause with low risk, reuses a
   proven in-repo mechanism, and is TUI-agnostic. Add tests for both branches
   (bracketed TUI submit; bare shell submit) per the repo's branch-coverage rule.
2. **Then add Option 3 for the unattended path**, scoped to the agent TUIs, with
   bounded retry and a trustworthy exit code that `nightwatch dispatch()` checks —
   so a genuine drop pages/logs instead of silently reporting success.

The task's stated hypothesis ("send a separate Enter after the paste settles") is
half right: the Enter **must** be a separate keystroke — but the robustness comes
from *explicitly bracketing the paste so it has a terminator*, **not** from
waiting for it to "settle." Bracketing removes the race; waiting only narrows it.

## Open questions for Chang

1. **Always bracket, or only above a size threshold?** I lean always (uniform;
   mode-aware bracketing already no-ops for shells). Do any callers send raw
   escape/control sequences through `--text` that bracketing would neutralize? (I
   believe not — `send-keys -l` is already literal-only.)
2. **Include the verify-and-retry layer (Option 3) now, or ship Option 2 and
   observe first?** For nightwatch, detectability is the higher-value half.
3. **Should `--submit`'s exit code become meaningful** (non-zero on a confirmed
   non-submit)? That's a CLI-contract change nightwatch could then trust.
4. **Codex live confirmation:** I confirmed Claude Code end-to-end. The mechanism
   is protocol-level (both TUIs enable `?2004h`), but want me to spin up a Codex
   pane to confirm identical behavior before implementing?

## Implementation sketch (if Option 2 approved)

- Add a `TmuxManager.pasteBuffer(server:paneID:bytes:)` helper mirroring
  `PasteExecutor`'s temp-file → `load-buffer` → `paste-buffer -d -p` →
  best-effort `delete-buffer` dance, but over the plain `runTmux` subprocess path
  (not the `-CC` command client), consistent with how `handleTerminalSend`
  already talks to tmux.
- In `handleTerminalSend`, replace `tmux.sendKeys(text:)` with the new paste
  helper; keep the `if submit { sendKey("Enter") }` exactly as is (now safe).
- Tests: (a) TUI pane with `?2004h` on → body arrives bracketed and a large
  multi-line message submits; (b) shell pane → body arrives bare and submits;
  (c) `submit == false` → no Enter. Follow the daemon test discipline in
  `CLAUDE.md` (no `~/tbd`, live-tmux deadlines, rc-free bootstraps).

## Implementation Status (2026-07-08)

**Option 2 shipped in PR #389** (commit 4885f89): bracketed-paste delivery + separate Enter
is now the default for all `terminal.send --submit --text` calls. Two same-day failure reports
(busy mid-turn Claude session, paste landed but Enter never submitted) almost certainly hit a stale
daemon still running pre-#389 code: the fix was committed 14:37 local and the first daemon carrying it
started 16:00; the reports predate that restart. 16 live trials against the #389 byte sequence —
including the reported waiting-on-background-agent state and SIGSTOP-forced input coalescing — all
submitted.

**Option 3 (verify-and-retry) — implemented in PR #398, then removed (2026-07-09).** A live
spike against real Claude Code v2.1.205 (isolated `tmux -L`, byte-0 pty capture) showed the
residual race Option 3 defended is unreachable: across a full session spanning idle prompt,
streaming turns, the slash menu, and a `/model` modal open+close, Claude emitted `CSI ?2004h`
exactly once at startup and `CSI ?2004l` zero times — bracketed-paste mode is pinned ON while
the composer is live. The exact production paste+Enter sequence submitted every time, including
SIGSTOP-forced input coalescing; a control run reproduced the ORIGINAL bug with raw
`send-keys -l`, confirming the negatives are real. With the mode always ON, `paste-buffer -p`
is always bracketed and the Enter is always outside the paste, so Option 2 alone is sufficient.
Option 3 added a ~300 ms verify pass to every submit-with-text call (up to ~2.4 s when it
wrongly detected a stuck submit) and coupled the daemon RPC layer to brittle Claude-TUI strings
(`❯`, `[Pasted text`) that would degrade silently if the TUI changed. Removed as dead code.

**Caveat (accepted):** the spike tested Claude Code only, not Codex. If a future/other agent
TUI toggles `?2004l` while its composer is live, the silent-non-submit risk returns for that
TUI; the fix then is a PROPER loud detector (report the drop through the RPC / exit code), not
a silent retry. Also note nightwatch's `dispatch()` still returns success unconditionally
without inspecting the result — a separate latent gap, out of scope here.

**Exit-code semantics (Option 4)** remain deferred (documented as open question in this doc).
