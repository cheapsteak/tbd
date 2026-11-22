# Why `tbd terminal send --submit` submits

How a message sent with `tbd terminal send --text "…" --submit` reaches an
agent session and is submitted rather than left standing in the composer, and
the evidence behind that design. The mechanism is `HolderSendComposition`
(`Sources/TBDDaemon/Server/HolderSendComposition.swift`); the screen and mode
contract it reads is in
[`specs/2026-09-05-child-as-contract-party-design.md`](specs/2026-09-05-child-as-contract-party-design.md).

## The failure

A message can land in an agent's composer and never be sent: the text sits
unsent at the prompt as `[Pasted text #N]`, while a short message to the same
session submits fine.

Claude Code and Codex both run a **paste-burst heuristic**: input that arrives
in the shape of a paste — several lines, or more bytes than one keystroke
carries, in a rapid burst — opens a short coalescing window, and everything
inside the window is pasted text. An Enter (`\r`) that arrives inside that
window is absorbed as a newline in the paste instead of being processed as the
key that submits. The heuristic keys on the *shape* of the input, not its size:
the Enter has been lost at about 230 bytes and again at 4 KB, and the newline
between the dispatch envelope and the body is shape enough. A bare `?` with
`--submit` is two bytes and submits.

## The mechanism

A send is **one write** to the session's pty, composed by
`HolderSendComposition.compose`:

```
ESC[200~ <body> ESC[201~ \r
```

The body is wrapped in an explicit bracketed paste, and the submitting `\r`
follows the end marker. The end marker closes the paste before the Enter
arrives, so the Enter is provably outside it and cannot be absorbed — there is
no timing in the argument. The message stays one write, so it is never split
across a routing decision or interleaved with another writer's bytes.

Three rules complete it:

- **Wrap only a child that asked for brackets.** Bracketed paste is a mode the
  child turns on (`CSI ?2004h`). When the daemon has watched the child since
  birth, its observed mode decides. When the mode is unobserved, an agent
  session is wrapped and a shell is not: a shell's line editor submits bare
  input of any length and has no burst heuristic to fool, while wrapping it
  would hand it markers to print or run. A stale "off" reading — taken from an
  emulator that stopped reading when a viewer attached, often milliseconds
  after the spawn and before the TUI turned bracketing on — is treated as not
  known rather than as off.
- **An empty body is never wrapped.** `--text "" --submit` is a real way to
  press Enter, and a paste of nothing is a pair of markers the child would have
  to interpret.
- **A body carries no paste markers of its own.** `ESC[200~` and `ESC[201~`
  are removed from every body, so text that recorded raw terminal input cannot
  close the paste early (sending the rest, Enter included, as keystrokes) or
  restart it.

## Evidence

The reproductions below were made with tmux as the pty writer, in isolated
`tmux -L` servers against Claude Code v2.1.205 and tmux 3.6a. What they show is
the pty's and the TUI's behaviour, which does not depend on the writer.

1. **The pty splits a large write into reads of about 1 KB.** A 2000-byte
   body observed by a raw pty reader arrived as reads of 1,022 and 978 bytes,
   then the Enter as a separate 1-byte read milliseconds later.
2. **A small body submits.** 596 bytes of multi-line text, then Enter:
   submitted at once, shown inline rather than collapsed to `[Pasted text]`.
3. **A large body loses its Enter.** 1,609 bytes of multi-line text, then
   Enter: the composer showed `[Pasted text #1]` followed by the rest of the
   body as raw text, the message stayed unsent, and nothing began working.
4. **A bracketed paste followed by Enter submits, whatever its size.** The
   same 1.2–1.6 KB bodies delivered as one bracketed paste, then Enter:
   submitted, and the composer cleared.
5. **A shell is unaffected.** A child that has not enabled bracketed paste
   receives bare bytes; only a child that opted in gets the markers.
6. **A delay before Enter is not a fix.** Sleeps of 50, 150, 300 and 600 ms
   between body and Enter gave inconsistent results across runs: the
   coalescing window is not a fixed value and stretches under load.
7. **Claude Code keeps bracketed paste on while its composer is live.** Across
   a session spanning an idle prompt, streaming turns, the slash menu and a
   `/model` dialog opened and closed, Claude Code emitted `CSI ?2004h` once at
   startup and `CSI ?2004l` never. A bracketed body is therefore always
   bracketed for it, and the Enter after the end marker always submits.

Field records of holder sends composed as one bare write — envelope, body and
`\r` together — showed the Enter lost at about 230 bytes and at 4 KB, and
showed bare sends composed against a mode reading taken about 19 ms after the
holder spawned, long before the TUI's `DECSET 2004`. Those two observations are
where the wrapping and the stale-reading rule come from.

## Knowing that a message landed

`tbd terminal send --submit` reports success once the message is written to
the session, not once the agent has read it. To confirm delivery, add `--verify`: the daemon then looks
for the send's dispatch envelope in the session's transcript, which is a
machine interface rather than the screen. It needs `--submit`, applies to Claude
sessions only, and is described in
[`specs/2026-09-05-child-as-contract-party-design.md`](specs/2026-09-05-child-as-contract-party-design.md#delivery-verification-on-holder-sends).

A message that must reach a session without touching a person's half-typed
composer should not go through `terminal send` at all, however reliably it
submits. A message posted to a Claude Code session's inbox socket preserved an
unsent draft byte for byte in testing; see
[draft-safe message injection: the Claude Code inbox socket and Codex app-server](research/2026-07-26-claude-code-channels/findings.md).

## Rejected alternatives

- **A delay before Enter.** The coalescing window is undocumented, varies by
  version and stretches under load (evidence 6), so a safe delay cannot be
  chosen; it would also add latency to every submit and detect nothing.
- **The paste and the Enter as two writes**, as tmux's `paste-buffer -p` and
  `send-keys Enter` delivered them. The end marker already puts the Enter
  outside the paste, so a second write buys nothing, and it splits one message
  into two writes that another writer can come between.
- **Verifying a submit by reading the screen.** Checking that the composer
  cleared, and pressing Enter again if it did not, defends a state evidence 7
  shows is unreachable for Claude Code. It also couples the daemon to the TUI's
  rendering (`❯`, `[Pasted text`), which would fail silently when that
  rendering changed, and it cost about 300 ms on every submit. Screen text is
  not an agent-state interface in TBD (`CLAUDE.md`, "No TUI screen-scraping");
  the transcript is, which is what `--verify` reads.

## What is not known

Evidence 7 covers Claude Code only. If another agent TUI turns bracketed paste
off while its composer is live, the daemon reads that and composes its sends
bare, and a long message to it can lose its Enter silently again. The fix there
is a loud detector that reports the drop through the exit status, not a silent
retry.
