# Attributing peer messages in the transcript viewer

## The problem

When another Claude session sends a message, TBD's transcript viewer renders it
as an ordinary user prompt whose text begins:

```
Another Claude session sent a message:
```

Three things are wrong with that.

**It hides who sent it.** The reader learns a peer spoke but not which one. In a
fleet of dozens of concurrent sessions that is nearly no information. The
sending session's own terminal shows the name — the transcript viewer, reading
the same transcript, shows less than the TUI does.

**It cannot be followed.** Having learned that a specific session sent a
message, the natural next gesture is to go look at that session. Nothing in the
viewer supports it.

**It renders the delivery envelope as content.** The bubble carries the framing
line, a `<cross-session-message …>` open and close tag, the body, and a ~90-word
anti-escalation security preamble appended to every peer message. The envelope
tags survive into the rendered markdown as empty blocks, so the body appears
pushed down by stray blank lines.

## What the transcript already records

Peer messages land as ordinary `type:"user"` JSONL lines carrying a harness-written
`origin` dictionary. Nothing here requires parsing rendered screen text.

Three shapes appear in a measured 19-message corpus (Claude Code 2.1.237 through
2.1.241):

- **Verified peer** — `kind:"peer"`, `from:"uds:/tmp/cc-socks/<pid>.sock"`, plus
  `name`, `verifiedPeerPid`, `msg_id`, `fromMode`, `body`, and sometimes
  `hopChain`. The `name` is the sending session's registered peer name. 8 of 19.
- **Asserted peer** — `kind:"peer"` and a bare `from` label such as
  `"acme-bot"`, with no name, no pid, and no body. An external script naming
  itself. 11 of 19.
- **Older verified peer** — 2.1.237-era rows carrying a uds path in `from` but
  none of the richer fields; these behave as the asserted shape.

`origin` is written by the receiving harness, not by the sending model. The
`body` is agent-authored. That boundary is load-bearing for the design below.

The `from` field is sender-asserted and unverified: anything running as the same
OS user can set it. What the harness actually verifies is the peer socket and
pid, which is why only the verified shape carries `name` and `verifiedPeerPid`.

TBD passes `--name <worktree displayName>` when it spawns a session, so a
verified `name` is normally the sender's TBD worktree display name and matches
one exactly. Display names are not unique — a measured local fleet of 1,916
worktrees contained a duplicated pair — so a name match can be ambiguous.

## Design

### A distinct transcript item

`TranscriptItem` gains a case rather than extra fields on `.userPrompt`:

```swift
case peerMessage(id: String, sender: PeerSender, text: String,
                 deliveredPayload: String?, timestamp: Date?)
```

`PeerSender` lives in `TBDShared`:

```swift
public struct PeerSender: Codable, Sendable, Equatable, Hashable {
    public let name: String?      // verified peer name, when the harness recorded one
    public let from: String       // raw origin.from, always present
    public let verified: Bool     // a verified peer socket backed this message
    public let pid: Int?          // origin.verifiedPeerPid, when present
}
```

A message received from a peer is a different thing from something the user
typed, and the model should say so. The practical payoff is that every
exhaustive `switch` over `TranscriptItem` — seven of them across the app — must
now state what it does with a peer message, instead of the item silently
inheriting user-prompt rendering the way it does today.

`text` is the clean body: `origin.body` when the harness recorded one, otherwise
the raw content with the framing line and the `<cross-session-message>` envelope
stripped. `deliveredPayload` is the untouched original, retained for the detail
overlay, and `nil` when it would merely repeat `text`.

### Extraction stays a pure function of one row

`TranscriptParser.buildItems` carries a documented rule that every item must be
derivable from its own row, because the tail parse sees only the lines inside
its byte window and any cross-row state starts empty there. Peer extraction
obeys it: a shared `PeerOriginExtractor` reads the row's `origin` dictionary and
its content string, and nothing else. No registry lookup, no worktree matching,
no filesystem access at parse time.

`ClaudeSessionScanner` calls the same extractor, so the transcript bubble and
the session-picker rows cannot drift apart in how they read an envelope.

### Resolution is a pure function over the worktree list

```swift
PeerSenderResolver.resolve(_ sender: PeerSender, worktrees: [Worktree]) -> UUID?
```

- An asserted sender never resolves. There is no verified identity to resolve.
- A verified sender resolves by exact `displayName` match against the active
  worktrees the app already holds.
- Exactly one match returns its id. Zero or two-or-more returns `nil`.

Refusing to guess between duplicate display names is deliberate: navigating to
the wrong session is worse than not navigating, because it looks like it worked.

The function takes the worktree list as a parameter, does no I/O, and is
testable without standing up a pane.

**Archived senders do not resolve.** Archived worktrees are not held in memory,
and this design will not fire an RPC per rendered row to find them. The result
is a visible degradation — the name still renders, it simply is not clickable —
rather than a silent one.

Clicking a resolved link calls the existing `AppState.navigateToWorktree(id:)`,
the same entry point `tbd://open?worktree=<uuid>` uses. That path already
handles an archived target by way of an async lookup and a progress toast, so a
sender that was archived between sending and reading still lands somewhere
sensible on the occasions it does resolve.

### Rendering

**The bubble** gains a header row above the markdown body carrying a sender
glyph and the sender's name:

- Resolved: a link-styled `Button` that navigates to the sender's worktree.
- Verified but unresolved: plain text.
- Asserted: muted and italic, with a marker distinguishing it from a verified
  name.

The header is native SwiftUI chrome built from `origin`, rendered outside the
markdown body. A peer therefore can neither author its own attribution nor mint
a worktree-navigation link inside its message. This is the reason the design
puts attribution in chrome rather than prepending it to the text.

The body renders `text`. Peer bubbles take a tint distinct from the user's own
prompts so a received message never reads as something the reader said.

**The detail overlay** labels the item with the sender rather than `"User"`,
shows `text` as the body, and reveals `deliveredPayload` behind a disclosure.
The envelope and the security preamble remain auditable; they are merely no
longer the first thing on screen.

**Session-picker rows** in the History pane use a session's first and last user
message as headline and subtitle. Today a session whose last message was a peer
message reads `Another Claude session sent a message: <cross-session-message
from="uds:/tmp/…`. It becomes `🛠 Acme Deploy Watch: <first line of the body>`,
composed by the scanner from the shared extractor.

## Rejected alternatives

**Resolving the sender through the peer registry.** `verifiedPeerPid` indexes
`~/.claude/sessions/<pid>.json`, which carries the sender's `cwd` and
`sessionId` — an exact identification immune to name drift. It is rejected for
this design because the registry entry exists only while the sending process
lives, so it answers precisely the cases that name matching already answers and
stays silent on the historical ones. It also puts a filesystem read on a render
path that currently has none. Name matching plus an honest refusal to guess
covers the same ground with no I/O. The registry remains available if name drift
proves to be a real problem in the field.

**Resolving at parse time and stamping a worktree id onto the item.** This would
make the parser's output depend on state outside the row it is parsing, breaking
the guarantee that a tail parse produces items byte-identical to the bottom of a
full parse of the same lines. The registry and the worktree list can both change
between two parses of one row.

**Extra fields on `.userPrompt` instead of a new case.** Both options force
every pattern match to be updated, since an enum case's associated values cannot
be bound partially. Given equal churn, the case that names the concept is worth
more than the one that overloads an existing one.

**Attribution prepended to the body text.** Cheaper to build, and it puts
harness-written metadata into the same string as agent-authored content, where
nothing downstream can tell the two apart.

**Dropping the security preamble entirely.** It is identical boilerplate on
every peer message and belongs nowhere near the top of a bubble, but it is what
the model was actually told, and a viewer that cannot show what the model was
told is a worse debugging instrument. The overlay keeps it.

## Out of scope

No feature flag: this is additive rendering of one transcript item kind. It
takes no autonomous action, destroys no state, and replaces no load-bearing
path.

No database migration and no `config` column — nothing here is configurable.

No new durable external resource, so no reconciler owes it a sweep.

Keeping a session's peer name in sync with its TBD display name after a rename
is a separate question and is not addressed here.

## Testing

Fixtures are built from real captured JSONL lines rather than hand-written
approximations, so the shapes under test are the shapes the harness emits.
Because this repository is public, captured lines are scrubbed to acme
placeholders before landing: substitute values, never shape.

- The parser emits `.peerMessage` for each of the three origin shapes, with the
  right `sender`, `text`, and `deliveredPayload`.
- A row carrying `origin.body` takes it verbatim; a row without one gets the
  framing line and both envelope tags stripped, and no leading blank lines
  survive.
- A row whose `deliveredPayload` would equal `text` records `nil`.
- The resolver: exact match resolves; no match returns `nil`; duplicate display
  names return `nil`; an asserted sender returns `nil` even when its `from`
  happens to equal a worktree display name.
- The scanner composes picker text from the same extraction, and a session whose
  last message is a peer message no longer surfaces envelope text.
- An ordinary typed user prompt still parses as `.userPrompt`, and a row with no
  `origin` is untouched.
