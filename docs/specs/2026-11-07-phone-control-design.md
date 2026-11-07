# Phone control of TBD sessions

A TBD user often walks away from the laptop while agents keep working. A session that needs an
answer then waits until the user is back at the desk. This design lets the user read and drive
TBD sessions from a phone: see every session's status, read one transcript, send a message,
answer a prompt, switch or fork a session's model, and start a new worktree or remote session.

The phone runs a web page, not a native app. Laptop and phone meet through a tiny relay that each
user deploys on their own Cloudflare account, so TBD depends on no server the maintainer hosts.
Everything that crosses the relay is end-to-end encrypted, and the relay sees only ciphertext. A
phone gets control only through a QR-code pairing that the user confirms on the laptop.

The feature ships behind `phone_control_enabled`, off by default.

The research behind each decision is in `docs/research/2026-11-07-phone-control/`. Each section
cites the report it rests on.

## User story

As a TBD user away from my laptop, I want to watch my sessions and drive one of them from my
phone, so that a session waiting on me does not sit idle until I am back at my desk.

## Goals

- Show every session TBD manages, grouped as the laptop sidebar groups them, each with a live
  status.
- Show one session's transcript at a time, live, with a fast first screen on a cellular link.
- Send a message to a session, including one that is parked.
- Answer an open question or permission prompt, with the same choices the laptop offers.
- Switch a local Claude session to another model profile, fork it under a profile, and change its
  model with `/model`.
- Create a local worktree with a first message, or a remote-provider session.
- Work across NAT on both ends with no port forwarding and no VPN app.
- Need no server that the TBD maintainer hosts. Each user's setup is their own.
- Keep the relay, the network and Cloudflare unable to read or inject anything.
- Pair many phones with one laptop, and one phone with many laptops.

## Non-goals

- **Codex transcripts.** Codex sessions appear in the list with their status only. Their
  transcript and actions come in v1.1, under their own spec.
- **Push alerts.** v1 is open-the-page-and-look. The design leaves room for Web Push in v1.1 (see
  "Follow-ups").
- **Interrupting a turn.**
- **Live token streaming.** The phone shows finished transcript items and a "Working…" line.
- **Attachments, diffs, syntax highlighting, search, and settings on the phone.**
- **Switching a remote session's profile, or forking it.**
- **A terminal on the phone.**
- **A direct or peer-to-peer path.** v1 uses the relay only. "Rejected alternatives" records why,
  and when to look again.
- **A native iOS or Android app.**
- **Waking a sleeping laptop.** A laptop that is asleep or offline shows as offline.

## Overview

Three parties take part:

- **The phone** runs three pieces of code:
  - the **loader**, a static page served from a dedicated GitHub org. It pairs, holds the keys,
    and runs the encryption.
  - the **runner**, a static page on the same origin. The loader opens it in a sandboxed iframe.
  - the **app bundle**, the actual UI. The laptop sends it over the encrypted channel, and the
    runner starts it.
- **The relay** is a Cloudflare Worker with one Durable Object class. It pairs two WebSockets in a
  room and passes frames between them. It knows nothing about TBD.
- **The laptop** runs a new daemon subsystem, `PhoneBridge`. It holds a WebSocket per paired phone,
  runs the encryption, sends the app bundle, and turns phone requests into TBD actions.

Laptop and phone both dial out to the relay, so NAT on either end does not matter. The laptop
connects to every paired phone's room while the flag is on. A phone connects when the user opens
the page.

## 1. Trust model

- **Trusted fully: the laptop.** It runs the agents. Anyone who controls it already controls
  everything this feature reaches.
- **Trusted with the keys: the loader origin.** Whoever can change the loader's code can steal the
  phone's keys. This is the largest remaining risk, and section 9 lists its controls.
- **Trusted for local access: the phone's lock screen.** A thief with an unlocked phone has full
  control until the user revokes that phone on the laptop.
- **Not trusted: the relay, Cloudflare, the network, and the user's Cloudflare account.** They can
  delay or drop traffic. They cannot read it, inject into it or replay it.
- **Not trusted: one laptop's app code, toward another laptop's keys.** A phone paired with laptops
  A and B runs each laptop's app bundle in its own sandboxed frame. Laptop A's code never sees laptop
  B's keys or traffic.

What each attacker can do:

- **The relay operator, Cloudflare, or the network** – see timing, message sizes, IP addresses and
  room IDs, and drop or delay frames. Nothing else.
- **Someone who learns the relay URL** – can use up the Workers Free plan's daily quota, which stops
  phone control until the quota resets. The Free plan cannot incur charges. They cannot reach a
  session: room IDs are 32 random bytes, and a handshake fails without a paired key.
- **Someone who photographs the pairing QR code** within its 5-minute life – can start a pairing,
  but the laptop shows a 6-digit code that must match the user's phone before the user clicks Allow.
- **A thief with an unlocked phone** – full control until revoked.
- **A compromised second laptop** – cannot read keys for the phone's other laptops.
- **Whoever controls the loader org** – can ship a loader that steals keys.

## 2. Pairing and keys

Research: `transports.md` section 7, `phone-clients.md` sections 1.3–1.5.

**Keys.**

- **Laptop:** one long-term X25519 key pair, made with CryptoKit on first use. The private key is
  stored in `~/tbd/phone/laptop.key`, mode 0600. Its path helper lives in `TBDConstants`, honors
  `TBD_HOME`, and is an instance member that tests can inject. TBD keeps its other secrets in
  owner-only files the same way (`ModelProfileKeychain` stores tokens under `~/tbd/claude-tokens/`).
- **Phone:** one X25519 key pair per paired laptop, made with Web Crypto (iOS 17 and later). WebKit
  bug 312279 loses a non-extractable X25519 key stored in IndexedDB, while non-extractable AES-GCM
  keys survive. So the loader stores each private key wrapped by a non-extractable AES-GCM key. This
  gives up nothing real: any code on the loader origin could use a stored key anyway.
- **The laptop stores only each phone's public key.** It keeps no per-phone secret.

**Pairing, once per phone per laptop.**

1. In TBD's Settings the user chooses "Pair a Phone…". The daemon makes a pairing offer: a new
   32-byte room ID, a 32-byte one-time pairing secret, and an expiry 5 minutes out. The offer lives
   in memory only.
2. TBD shows a QR code. It encodes the loader URL, and after the `#` it carries: a format version,
   the relay URL, the room ID, the pairing secret, the laptop's public key, the laptop's name, and
   the expiry. The part after `#` is never sent to any server. The sheet also shows the same link as
   text for pasting.
3. The phone scans the code with the loader's in-page scanner, or opens the link. It makes its key
   pair and runs `Noise_IKpsk2_25519_AESGCM_SHA256` as the initiator, with the laptop's key as the
   known responder key and the pairing secret as the PSK. The prologue is `tbd-phone/1` followed by
   the room ID.
4. Both screens show a 6-digit code derived from the handshake hash. The laptop asks "Allow
   '<phone name>' to control this laptop? Code 123 456". The phone shows "Check this code on your
   laptop: 123 456". The user names the phone before the handshake, starting from a name taken
   from the browser, such as "iPhone". The name travels encrypted in the first handshake message.
5. On Allow, the daemon stores the phone's public key in a `phone_device` row, with the room ID as
   that phone's permanent room. It then discards the offer. A QR code works once. On Deny or
   expiry, the daemon discards the offer and the phone shows why.

**Every later connection.** The phone runs `Noise_IK_25519_AESGCM_SHA256` with the same prologue.
The laptop accepts the handshake only when the phone's static key matches a non-revoked
`phone_device` row for that room. Fresh ephemeral keys give each connection new keys and forward
secrecy.

**Every message.** After the handshake, each direction has its own AES-GCM key and Noise's 64-bit
message counter. The WebSocket delivers in order, so a frame that arrives out of order or twice
fails to decrypt and ends the connection. A recorded frame cannot be replayed into a new
connection, because each connection has new keys.

**Revoking.** Settings lists each paired phone with Revoke. Revoke deletes the row and closes that
phone's socket. If the phone is connected at that moment, the laptop first sends `revoked`, and the
phone shows "This phone was removed from <laptop>" with Forget. A phone that was not connected sees
the laptop as offline from then on. The master "Phone control" switch closes every socket. On the
phone, Forget deletes that laptop's keys and cached bundles.

## 3. The relay

Research: `transports.md` sections 1 and "Ranking for TBD".

**Where it lives.** `relay/cloudflare/`, a self-contained folder with its own `package.json`,
Wrangler config and tests. Cloudflare's Deploy button needs the relay isolated in its own folder.
The folder's README carries the button.

**Setup.**

- The user guide `docs/phone-control.md` carries the Deploy button. The button clones the relay
  into the user's GitHub account, builds it with Workers Builds, creates its Durable Object, and
  gives it a free `<name>.<subdomain>.workers.dev` address. The user needs a Cloudflare account and
  a GitHub account. No domain is needed.
- The app gets a menu item, "Set Up Phone Relay…", also reachable from the Settings pane. It
  explains the steps, opens the Deploy page, asks for the relay URL, and checks it with
  `GET /v1/info`.

**Shape.** One Worker and one Durable Object class, `Room`, using SQLite-backed storage, which the
Free plan requires. There is one room per laptop–phone pair. The relay stores nothing: no tables,
no content, no logs of content. It uses the WebSocket Hibernation API, so an idle room costs no
Durable Object time.

**API v1.** This is a stable contract. TBD supports it for good.

- **Every HTTP response carries `Access-Control-Allow-Origin: *`,** refusals included, so a page on
  another origin, such as the loader, reads the real status rather than an opaque CORS error. The
  relay sets no cookies and reads no credentials, so this exposes nothing. CORS does not govern the
  WebSocket upgrade.
- **`GET /v1/info`** – returns `{"name":"tbd-relay","version":"<semver>","api":[1]}` with
  `Content-Type: application/json` and `Cache-Control: no-store`.
- **`GET /v1/rooms/<roomID>?role=laptop|phone`** – opens a WebSocket. A room ID is 43 base64url
  characters (32 bytes). Each role has one socket per room. A new socket for a role closes the old
  one with code 4000 and reason `replaced`.
- **`GET /v1/rooms/<roomID>/presence`** – returns `{"laptop":true}` while the room has an open
  laptop socket and `{"laptop":false}` otherwise, with `Content-Type: application/json` and
  `Cache-Control: no-store`. The room ID rule is the same. It opens no socket and displaces no one,
  so the loader's laptops list asks it whether each paired laptop is online: joining the room as a
  phone would close another tab's phone socket with code 4000.
- **HTTP status codes.** A path that is not `/`, `/v1/info`, `/v1/rooms/<roomID>` or
  `/v1/rooms/<roomID>/presence` gets 404, and a malformed room ID is checked first, whatever the
  method. A method other than GET gets 405 with `Allow: GET`. A room URL without exactly one `role`
  parameter equal to `laptop` or `phone` gets 400. A room URL without `Upgrade: websocket` gets 426.
  `GET /` answers 200 with a one-line text page and is not part of the API.
- **Forwarded frames are binary,** at most 65,536 bytes, and pass to the other role unchanged. When
  the other role is not connected, the relay drops the frame. It never queues. A larger frame is
  not forwarded: the relay closes the sender with code 1009 and reason `frame too large`, and the
  other role gets `peer-left` at once. A socket the relay is closing sends nothing more, so a
  replaced socket's last frames never reach the new session.
- **Text frames from clients are never forwarded,** so no client can forge a relay signal. The one
  exception is the keepalive below, which the runtime answers.
- **Relay signals are text,** so they cannot be confused with forwarded frames.
  - `peer-joined` goes to both sockets when a socket joins and the other role has an open socket.
    It always means a new peer socket, so the receiver resets its channel: any Noise session with
    the previous peer socket is over.
  - `peer-absent` goes to a joining phone when no laptop socket is open. A laptop that joins an
    empty room gets no signal.
  - `peer-left` goes to the other role when a socket closes or errors and no open socket of its
    role remains. A socket the relay closes signals nothing more when its close completes: one
    closed with 4000 because a new one replaced it causes no `peer-left`, and one closed with 1009
    caused its `peer-left` when the relay closed it. So a peer that joins after the relay closed a
    socket never hears that socket leave. A `peer-left` can repeat in rare races, so receivers
    treat it as idempotent.
- **Keepalive** uses Cloudflare's WebSocket auto-response: the text frame `ping` gets the answer
  `pong`, and a keepalive never wakes the Durable Object. Both sides send one every 30 seconds.

**Versions and updates.**

- New TBD features never change the relay, because they live inside the encrypted frames.
- A future relay API v2 lives beside v1, at `/v2/`, in the same Worker.
- When `/v1/info` reports an older version than the one in the TBD release, TBD shows "Relay update
  available" with the steps. This is information only, never a block.
- Updating means syncing the user's GitHub copy from TBD's repo, after which Workers Builds
  redeploys it.

**Laptop side.** The daemon sends a descriptive `User-Agent`, because Cloudflare's Browser
Integrity Check on `workers.dev` blocks some default ones. Reconnects back off from 1 second,
doubling to 60 seconds, with jitter.

## 4. Protocol layers

Two layers carry a compatibility promise. The others change freely with each TBD release.

### 4.1 Relay frames

The relay API v1 in section 3. Stable.

### 4.2 The secure channel

The Noise handshakes and transport messages in section 2. A Noise message is at most 65,535 bytes,
which matches the relay's 64 KiB frame limit. The handshake prologue carries the channel version
(`tbd-phone/1`), so a future channel version cannot be confused with this one. Both the loader and
the daemon implement this layer.

### 4.3 The loader protocol

This is the contract between the loader, which is always the newest version on the loader org, and
whatever TBD release the laptop runs. It is stable. Messages are JSON, inside the secure channel.

- **`hello`** (phone to laptop) – the loader's version and the list of loader-protocol versions it
  speaks.
- **`welcome`** (laptop to phone) – the TBD version, the chosen loader-protocol version, and the app
  bundle's SHA-256 and size. If no common version exists, the laptop sends `incompatible` with
  which side is too old.
- **`bundle.get`** (phone to laptop) – sent when the loader has no cached bundle with that hash.
  The laptop answers with the bundle in chunks, compressed with raw deflate. The loader inflates
  it with `DecompressionStream("deflate-raw")`. The bundle is static code, so compressing it leaks
  nothing.
- **`app`** (both ways) – an opaque message for the app frame. The loader passes it through
  without reading it.
- **`revoked`** (laptop to phone) – see section 2.

**Version rule.** Each side states its version and the oldest version it accepts. On a mismatch the
phone shows "Update TBD on this laptop" or "Reload this page". The loader keeps support for every
loader-protocol version that any TBD release has shipped, because laptops lag behind the loader.

### 4.4 The app protocol

The app bundle and the daemon come from the same TBD build, so this layer has no compatibility
burden. Messages are JSON requests, replies and events, carried in `app` messages. Every request
carries a `requestID`. A reply carries either a result or an error with a code and a plain message.

Requests:

- **`sessions.subscribe`** – returns a snapshot and then sends `sessions.changed` events. The
  snapshot lists repos and worktrees in sidebar order, and each session with: a session reference,
  its kind (Claude, Codex or remote), its worktree or remote grouping, its tab name, its status, the
  time of its last status change, its profile name, and its capabilities (transcript, send, answer,
  switch profile, fork, model).
- **`transcript.open`** – returns the first page (section 7), then sends `transcript.append`,
  `transcript.update` and `transcript.reset` events for that session. One transcript is open per
  phone at a time. Opening another closes the first.
- **`transcript.page`** – returns the page before a cursor.
- **`transcript.detail`** – returns one part of one item in chunks: a tool call's input or result,
  the rest of a long message, or a subagent's items.
- **`transcript.close`**.
- **`message.send`** – sends text to a session, waking it first if it is parked.
- **`prompt.answer`** – answers an open prompt by its ID.
- **`profiles.list`** – the user's model profiles: ID, name, kind, and which is the default. Never
  a token or other secret.
- **`session.switchProfile`** – restarts a local Claude session under another profile in the same
  tab.
- **`session.fork`** – copies a local Claude session's conversation into a new tab, optionally
  under another profile. The reply carries the new session's reference.
- **`session.setModel`** – sends `/model <name>` to the session through the send path.
- **`worktree.create`** – a repo and a first message. The reply carries the new session's
  reference.
- **`remote.providers`** – registered providers, with their `create_params`.
- **`remote.create`** – a provider and the filled form.

**Open prompts** for the open session arrive as `prompt.changed` events. Each carries the prompt ID,
its kind (question or permission), the tool name, a summary of the input, and the questions with
their options, or the permission's suggested rules.

**No double actions.** The daemon keeps each request ID and its result for 10 minutes. A repeat of
a known request ID returns the stored result and does nothing again. So a resend after a reconnect
is safe.

**Fixtures.** Every app-protocol message has a JSON fixture under `phone/protocol/`. Swift tests
decode and re-encode each one, and TypeScript tests do the same, so the two sides cannot drift.

## 5. The daemon bridge

A new subsystem, `Sources/TBDDaemon/PhoneBridge/`. It runs only while `phone_control_enabled` is on
and a relay URL is set. Turning the flag off stops it and closes every socket.

Its units, each with one job:

- **`RelayLink`** – one WebSocket per paired phone's room, through `URLSessionWebSocketTask`.
  Handles reconnect, keepalive, and the relay's text signals.
- **`SecureChannel`** – the Noise handshakes and transport messages, built on CryptoKit. Pure logic
  with no I/O, tested against published vectors.
- **`PairingService`** – makes offers, runs the pairing handshake, computes the confirmation code,
  and waits for the user's Allow or Deny from the app.
- **`DeviceStore`** – the `phone_device` table and the laptop key file.
- **`LoaderHandler`** – `hello`, `welcome`, and bundle delivery. The bundle ships inside the TBD
  install, and its hash is computed once at start.
- **`PhoneAppService`** – the app protocol. It calls the same internal functions the RPC handlers
  call, with no trip through the socket.
- **`TranscriptFeed`** – the open transcript: shaping, paging, and live updates (section 7).

**Authority.** The socket's rules do not change. `prompt.answer`, `remote.answer`, and sends
without the `<tbd-dispatch/>` marker stay limited to the TBD app at the socket edge, and no socket
method gains phone authority. The bridge acts from inside the daemon, and its authority comes only
from a verified pairing. The implementation splits each such RPC handler into the socket-edge check
and a core function beneath it, and the bridge calls the core function. It never copies the
handler's logic.

**Actions map to existing paths:**

- **Status** – `session.states` facts plus the open prompts in `PendingPromptStore`.
- **Send** – the send path the transcript composer uses (`ComposerSendCoordinator`'s options: the
  message as parts, submitted, marker suppressed, gated on awaiting input), so the daemon applies
  the same gating. A parked session is woken with the message, as the composer does with
  `terminal.wake`. A refusal returns its reason.
- **Answer** – the core of `prompt.answer`, with the answer shapes `PromptAnswer` supports, which
  are the choices the laptop's prompt card offers. A prompt that is no longer open returns "already
  answered".
- **Switch profile and fork** – `terminal.swapProfile` in `inPlace` and `fork` modes.
- **Model** – `/model <name>` through the send path.
- **New worktree** – the core of `worktree.create`, with the first message and TBD's defaults for
  everything else.
- **Remote sessions** – the core functions behind `remote.sessions`, `remote.transcriptSync`,
  `remote.transcriptLoadEarlier`, `remote.sendMessage`, `remote.answer` and `remote.create`.

**Record.** Every phone action is logged through `os.Logger` (subsystem `com.tbd.daemon`, category
`phone-bridge`, level `.notice`) with the phone's name, the action and its target. The log never
carries message text or answers. Pairing, Allow, Deny and Revoke are logged the same way.

**Laptop-side RPCs** are app-only, so no other local process can approve a pairing: `phone.status`,
`phone.pairStart`, `phone.pairAllow`, `phone.pairDeny`, `phone.devices`, `phone.revoke`,
`config.setPhoneControlEnabled`, `config.setPhoneRelayURL` and `config.setPhoneLoaderURL`.

## 6. Sessions the phone can reach

- **Local Claude sessions** – everything in this spec.
- **Codex sessions** – listed with their status, which comes from OSC 7501 like Claude's. Opening
  one shows "Codex transcripts arrive in a later TBD release". No actions.
- **Remote-provider sessions** – listed, with status from the provider's session list and open
  prompts from its `pending_prompt`. Each action depends on the provider's capabilities:
  - **Transcript** – from the daemon's remote transcript cache, where the provider declares
    `transcript.read`. The bridge counts as a viewer, so opening the transcript on the phone starts
    its sync, the same as opening the laptop pane. Scrolling past the cached part uses
    `remote.transcriptLoadEarlier`.
  - **Send** – where the provider declares `send` with `send-submit`.
  - **Answer** – where the provider declares `answer`.
  - **Model** – where the provider declares `send-submit`.
  - **Create** – from the "New" sheet. TBD fills `repo` and `prompt`. Any other required field is
    shown as a form built from the provider's `create_params`.
  - A missing capability shows that action as unavailable, with its reason.
- **Hidden** – shell tabs, note tabs, and archived worktrees.

**Status chips** map the daemon's session states:

- **Waiting for you** – awaiting input, or an open prompt.
- **Working.**
- **Idle** – idle or done.
- **Parked.**
- **Rate limited.**
- **Error** – error or needs auth, with the reason.
- **Exited** – gone.
- **Unknown** – no state is known. Sessions on the tmux transport read this way today.

## 7. Long and large transcripts

TBD already has the two building blocks. `TranscriptParser.parseTail` reads a transcript from its
end in chunks of about 1 MB, without parsing the whole file. `IncrementalTranscript` parses only
appended lines and patches a tool row when its result arrives later. Both run on the laptop's own
disk, so none of this reading crosses the network.

**Shaping: the laptop sends summary items.** Tool output makes up most of a transcript's bytes, and
the phone does not show it until tapped.

- **Messages** – your messages and assistant text. Text over 4 KB arrives cut, with "Show more",
  which fetches the rest through `transcript.detail`.
- **Tool calls** – one summary row: the tool name, a short target such as a command or a file
  name, and the status. The input and result arrive only on tap.
- **File edits** (Edit, Write, MultiEdit) – the file name and line counts, such as `+12 −3`,
  counted on the laptop. Nothing more is shown on the phone.
- **Subagents** – one row with the agent type and its item count. Its items arrive on tap.
- **Thinking, system reminders and hook output** – sent only while "Show details" is on.
- **Slash commands** – a small row. **Messages from other sessions** – a bubble labeled with the
  sender.

**Pages.**

- **The first page** holds the items back to and including the 4th-last message, where a message is
  your message or a block of assistant text. The tool rows between those messages come along. A
  page is capped at 16 KB. A typical first page is 5–10 KB, one frame.
- **Older pages** load only when the user scrolls within about two screens of the top, so a steady
  scroll never waits. Each holds the next 20 messages and the rows between them, at most 64 KB,
  which is one frame. Twenty messages fill several phone screens. A larger page would mostly carry
  history the user never reaches, and the virtual list renders only what is on screen anyway. A
  page is asked for with a cursor, which is a byte offset into the transcript file.
- **One new parser function** is needed: parse the window that ends before a byte offset. A tool
  call near a page's end can have its result in the newer, already loaded range. The daemon joins it
  from the result index it keeps for the open transcript.
- **Live updates** – new lines are parsed incrementally from the last offset. A new item arrives as
  `transcript.append`. A result for an existing tool row arrives as `transcript.update`, by the
  item's ID.
- **Reconnect** – items have stable IDs, and every event carries a sequence number. A reconnecting
  phone sends the last number it saw and gets only what changed.
- **Reset** – `/clear`, a resume, or a session rollover sends `transcript.reset`, and the phone
  starts over at the new tail.

**Large details.** A detail arrives in chunks that each fit one frame, and the user can cancel it.
Above 1 MB the phone shows the first part and "Too large for the phone. Open on the laptop."

**Fewer round trips.** As soon as the channel is up, the app sends `sessions.subscribe` and, when
the user was last in a session, `transcript.open`, without waiting for either reply.

**Rendering on the phone.**

- The transcript list uses TanStack Virtual, so only rows near the screen exist in the page. It
  measures rows of any height, and holds the user's place when older rows load above.
- Markdown renders only for rows near the screen.
- While the user is at the bottom, new items keep the view at the bottom. Otherwise a "New
  messages ↓" pill appears.

**Parse state on the laptop.** The daemon keeps parse state for one open transcript per phone, and
drops it on `transcript.close` or 2 minutes after a disconnect.

**No compression of transcript data.** Shaping removes most of the bytes. Compressing before
encrypting would also let message sizes reveal content. The relay sees sizes, and tool output can
contain text an outsider chose, such as a fetched web page. That is the pattern behind the BREACH
attack.

**Targets.** A synthetic fixture holds a 30 MB transcript with about 20,000 items.

- The daemon produces the first page in under 200 ms. An automated test checks this.
- The phone shows the first screen within 2 seconds over the relay on a cellular link. This is an
  on-device check.
- Scrolling up through 1,000 items stays smooth on a recent iPhone. This is an on-device check.

## 8. Phone UI

This section fixes what each screen shows and does. How the screens look and respond is fixed by
the reviewed mocks in [`docs/design/phone-control/`](../design/phone-control/README.md):
`phone-control-mocks.html`, one self-contained page that runs every screen and state below in a
browser, and a screenshot of each state in light and dark mode at phone size. Its README lists the
states and how to open each one.

The phone UI is built to the mocks, not designed again from this section's words (see "Build
order"). It copies the mocks' colour tokens, sizes, spacing, glyphs and UI text as they are. Where
this section and the mocks differ on how a screen looks or what a tap does, the mocks win, and the
PR that finds the difference updates this section to match. A change to what a screen shows or
does updates this section and the mocks together. A change to how it looks updates the mocks and
their screenshots.

The look follows the TBD laptop sidebar: compact one-line rows, small text, and the sidebar's
status symbols (an amber hand for Waiting for you, dots for Working, a moon for Parked, a red
octagon for Error, an hourglass for Rate limited) at the end of each row.

### 8.1 Loader screens

The loader's screens hold the keys, so they come from the loader origin, not from a laptop.

- **Laptops** – one row per paired laptop: name, online or offline, and last connected. "Pair a
  laptop" at the top. Forget on each row, with a confirmation. A hint suggests adding the page to
  the Home Screen (see 8.3). With one laptop paired, this screen is skipped.
- **Pair** – a camera view scans the QR code. "Paste link" is the fallback. Then a field to name
  the phone, prefilled from the browser, then "Check this code on your laptop: 123 456" and a wait
  for Allow.
- **Errors, in plain words:**
  - "Laptop offline"
  - "Update TBD on this laptop"
  - "Reload this page"
  - "This phone was removed from <laptop>", with Forget
  - "Can't reach the relay"
- **Header strip** – a thin strip owned by the loader, outside the app frame. It shows the
  laptop's name with a dropdown caret. Tapping the name opens a menu of the paired laptops, each
  with online or offline and a check on the current one, then "Pair a laptop" and "Manage
  laptops", which opens the Laptops screen. While the channel is down, the strip shows
  "Reconnecting…". The loader draws the strip and its menu, so app code cannot fake which laptop
  the user is on.

### 8.2 App screens

These come from the laptop's bundle.

- **Sessions.**
  - Repos as groups, with one row per worktree within each.
  - Newest first, at both levels. Within a repo, the worktree with the most recent status change
    comes first. The repos are ordered by their most recently changed worktree. The laptop sidebar
    keeps a stable order; the phone does not, so whatever just changed is at the top of the
    screen.
  - A row shows the worktree's name, the time since the newest status change among its sessions,
    and a status symbol at its end. The symbol has a text label for screen readers.
  - A worktree with several sessions shows a count, such as "(3)". Its symbol is the most urgent
    of its sessions, in this order: Waiting for you, Error, Rate limited, Working, Idle, Parked,
    Exited, Unknown.
  - Tapping a row opens the session that shows that status. Ties go to the most recently active
    session.
  - Remote sessions sit in the group the laptop sidebar gives them, one row each, with a "remote"
    badge.
  - Each repo's header row has a "+" that opens the New sheet for that repo. Tapping the repo's
    name collapses or expands its rows. The list updates live.
- **Session.**
  - **Header** – back and the worktree's name, with a line below: the status in words, the time
    since the last status change, the account and the model. A remote session shows its provider
    in place of the account. Error and Rate limited show their reason in a band under the header,
    and Exited and Unknown say what they mean in the same band.
    Then a "Show details" switch, and a menu with Switch account, Fork, and Model where the
    session supports them.
  - **Account and model menus** – where the session supports Switch account, the account name in
    the header opens a menu of profiles, with a check on the current one. Picking another asks
    the Switch account question below, in the menu. Where the session supports Model, the model
    name opens a menu with the Model list below, and a pick applies at once.
  - **Tab strip** – shown when the worktree has more than one session. One tab per session, each
    with a status dot. Switching tabs opens that session's transcript.
  - **Transcript** – section 7's items, newest at the bottom. A "Working…" line with the elapsed
    time shows while the agent works.
  - **Prompt card** – pinned above the composer while a prompt is open.
    - A question shows its options as buttons, or as checkboxes for multi-select, plus free text
      where the laptop allows it. Several questions step through one at a time, then a review
      step lists the answers before they are sent.
    - A permission shows the tool, its full target with wrapping, and every choice the laptop
      offers, including rules such as "don't ask again", and Deny. Deny takes an optional
      message telling Claude what to do instead.
    - The card can be hidden to a one-line strip and shown again, so the transcript behind it can
      be read.
    - After answering, the card shows "Answered", or "Already answered on the laptop". The
      transcript then keeps a receipt line: "Answered on this phone: <answer>", or "Answered on the
      laptop".
  - **Composer** – multi-line text and Send. On a parked session the button reads "Send and wake".
    A refusal shows its reason. Text only.
- **Switch account** – a profile list, then the question "Restart this session under
  <profile>?" with three answers: Restart, "Fork into a new tab" (the Fork action below, under
  that profile, which leaves this session running), and Cancel. The question says when a running
  turn would stop.
- **Fork** – a profile list, with the current profile first. The fork opens as a new tab, and the
  phone switches to it.
- **Model** – `default`, `opus`, `sonnet` and `haiku`, plus a field for any other name. The list is a
  constant in the app bundle, so it updates with TBD releases.
- **New sheet** – opened from a repo's "+", so the repo is already chosen and the sheet names it.
  Two choices:
  - **Local worktree** – type the first message, then Create. TBD uses its defaults for
    everything else. The new session opens when it is ready.
  - **Remote session** – pick a provider, type the first message, and fill any extra required
    fields. Field types are text, multi-line text, on/off, number, and a choice list. The repo
    from the "+" is the `repo` that TBD fills (section 6).

### 8.3 General rules

- Built for phones. The safe-area insets are honored, and the composer stays above the keyboard.
  The loader forwards both measurements into the frame, because inside it they can read wrong.
- Follows the system's dark or light mode, forwarded by the loader.
- Send, prompt choices, menu items and sheet rows are at least 44 points tall. List rows, tabs and
  header buttons follow the compact laptop-sidebar size instead, so more of the list fits on one
  screen. Composer text is 16 px, so focusing it does not zoom the page.
- Semantic HTML with labeled controls, so screen readers work.
- Works in a Safari tab. Adding the page to the Home Screen is optional. It stops Safari from
  clearing the stored keys after 7 days without a visit, and v1.1's push alerts will need it.
- Links in a transcript open through the loader in a new tab. The app never renders a raw `href`.

## 9. Phone code: structure, framework and libraries

Research: `phone-app-stack.md`.

**Folders.**

- `phone/loader/` – the loader and the runner. Plain JavaScript ES modules with JSDoc types, served
  exactly as committed, with no build step. `tsc --noEmit` checks the types in CI.
- `phone/app/` – the app bundle's sources. TypeScript and React.
- `phone/protocol/` – the app-protocol fixtures (section 4.4).
- `phone/test-vectors/` – the Noise vectors and TBD's framing vectors, read by Swift and
  JavaScript tests.

**Running the bundle in isolation.**

- The loader opens `runner.html` from its own origin in `<iframe sandbox="allow-scripts">`, with
  no other sandbox keywords. The frame therefore has an opaque origin and no access to the loader's
  storage.
- The loader posts the bundle's text, its SHA-256, and one end of a `MessageChannel` to the frame.
  It checks `event.source` and a nonce first.
- The runner checks the hash, creates a `blob:` URL inside the frame, and starts the bundle as one
  classic script.
- The runner's security policy, set by its own `<meta>` tag:
  - names the loader's origin explicitly, never `'self'`, because WebKit changed what `'self'`
    means in a sandboxed document twice in 2026;
  - allows scripts only from that origin and from `blob:`;
  - sets `connect-src 'none'`, so the frame has no network and reaches the laptop only through its
    message port;
  - enforces Trusted Types with one policy, for the runner, so app code cannot write HTML strings.
- The loader treats a second `load` event on the frame as a fault and tears the frame down. A
  sandboxed frame can still navigate itself away, so this closes that hole.
- `srcdoc` is not used. A `srcdoc` frame inherits the loader's policy, which blocks the bundle.

**The app bundle.**

- **React 19.3 with TypeScript.** The React ecosystem is available, within the frame's limits: no
  styles injected at runtime, no network, no `eval`, no HTML strings. CSS-in-JS libraries that inject
  styles at runtime are therefore out. Static CSS, CSS modules, or a build-time CSS tool work. A
  library that fetches data works through a function that asks over the message port.
- **Build.** esbuild, pinned to an exact version, bundles the sources and production React into one
  minified JavaScript file. CSS is embedded as text and applied with `adoptedStyleSheets`. The file
  is committed under `Sources/TBDDaemon/Resources/phone-app/` and copied into the TBD install as a
  SwiftPM resource. Building TBD only copies it, so it never needs Node. `SessionMod/` already
  works this way. The committed file is marked `linguist-generated=true`. Reviewers read the
  sources, and CI proves the file matches them.
- **Libraries,** each pinned:
  - **react, react-dom 19.3.x** – the UI.
  - **marked 18.1.x** – markdown, tokenizer only. The app maps tokens to React elements, so no HTML
    string is ever made, raw HTML in a transcript cannot run, and no sanitizer is needed.
  - **@tanstack/react-virtual 3.x** – the transcript list.
- **Size.** About 60–80 KB gzipped in total. It downloads once per TBD version, compressed, and the
  loader caches it by hash. The loader keeps the newest two bundles per laptop.

**The loader's libraries.** **jsQR 1.4.0** decodes QR codes where `BarcodeDetector` is missing,
which includes iPhone Safari. It loads only on the pairing screen. jsQR has had no commits since
2021. It is small and does one job, and the advisory check below watches it.

**Vendoring.** The loader's third-party files are committed with their upstream licenses and a
`vendor.lock` of registry integrity values and per-file SHA-256s. A shell script (`curl`, `tar`,
`shasum`) updates them. CI verifies the checksums. A scheduled job checks every pinned version, in
the loader and in the app's lockfile, against the OSV advisory database.

**Review.** A CODEOWNERS entry requires the maintainer's review for `phone/loader/**` and
`relay/**`. Merging to `main` deploys the loader, and the loader holds the keys.

## 10. Laptop UI

- **Settings pane, "Phone"** (SwiftUI):
  - the "Phone control" toggle, which is the flag;
  - the relay URL with its status: connected, unreachable, or "Relay update available";
  - "Set Up Phone Relay…";
  - "Pair a Phone…", which opens a sheet with the QR code, the link as text, and a 5-minute
    countdown, then the Allow or Deny step with the code;
  - paired phones: name, date paired, last seen, and Revoke;
  - an advanced field for the loader URL, which is empty for the default.
- **App menu item** "Set Up Phone Relay…".
- **Status-bar chip** "Phone connected", shown while any phone is connected, so the user always
  sees when a phone is in.

## 11. Storage

One `.sql` migration, the GRDB record changes, and the `TBDShared` model changes, in one commit.

- **New `config` columns, with no SQL default,** so "unset" stays its own state:
  - `phone_control_enabled INTEGER` – resolved as `?? Config.phoneControlEnabledDefault`, which is
    `false`.
  - `phone_relay_url TEXT` – NULL means not set up.
  - `phone_loader_url TEXT` – NULL resolves to `Config.phoneLoaderURLDefault`, the loader org's URL.
- **New table `phone_device`:** `id` (text, primary key), `name`, `public_key` (blob), `room_id`,
  `paired_at`, and `last_seen_at`. Revoke deletes the row. The shared model's fields are optional or
  have defaults, so older rows and payloads still decode.
- **File:** `~/tbd/phone/laptop.key`, mode 0600 (section 2).

The loader org's name is chosen when the maintainer creates it. `Config.phoneLoaderURLDefault`
records it.

## 12. Who reclaims orphans

This feature adds no kind of durable resource that needs a sweep:

- **The laptop key file** – one per install, so it cannot be orphaned.
- **`phone_device` rows** – deleted by Revoke.
- **Pairing offers** – in memory only, expiring on an injected clock.
- **Relay rooms** – the relay stores nothing. A revoked phone's room simply never sees the laptop
  again, and an idle room costs nothing.
- **Worktrees and remote sessions created from the phone, and remote transcript caches** – created
  through existing paths, which `OrphanGC` and the worktree reconcile already cover.
- **Bundles cached on the phone** – the loader prunes them as it writes, keeping the newest two per
  laptop.

## 13. Clocks and dates

Every timer takes an injected `any Clock<Duration>` as its last initializer parameter: the pairing
offer's expiry, reconnect backoff, keepalive, the request-ID memory, and the parse-state grace
period. `paired_at` and `last_seen_at` come through the date seam.

The starting values are named constants in one place:

- **Pairing offer life** – 5 minutes.
- **First page** – back to the 4th-last message, at most 16 KB.
- **Older pages** – 20 messages, at most 64 KB, fetched within two screens of the top.
- **Message preview** – 4 KB.
- **Detail limit** – 1 MB.
- **Request-ID memory** – 10 minutes.
- **Parse-state grace after disconnect** – 2 minutes.
- **Keepalive** – 30 seconds.
- **Reconnect backoff** – 1 second, doubling to 60 seconds, with jitter.
- **Cached bundles per laptop** – 2.

## 14. Testing

**Swift**, through `scripts/test.sh`:

- `SecureChannel` against cacophony's published vectors for `Noise_IKpsk2_25519_AESGCM_SHA256` and
  `Noise_IK_25519_AESGCM_SHA256`, and against TBD's framing vectors in `phone/test-vectors/`.
- Pairing: expiry, single use, Allow, Deny, and a second scan of a used code.
- The handshake refuses an unknown or revoked phone key.
- Replay: a duplicated or reordered frame ends the connection.
- Request IDs: a repeat returns the stored result and acts once.
- The flag, both branches. Off: no relay sockets, pairing RPCs refuse, and no phone action reaches
  a session. On: the full path works against an in-process fake relay.
- Each action against its existing core path, including "already answered" and a refused send.
- Shaping and paging against the 30 MB fixture, including the 200 ms first-page target, the joined
  tool results at page edges, and `transcript.reset` on a rollover.
- Every fixture in `phone/protocol/` decodes and re-encodes.
- Laptop-side RPCs refuse any caller except the app.
- Tests use `TBD_HOME` fencing and injected clocks, per `Tests/CLAUDE.md`.

**Relay**, in `relay/cloudflare/`: Vitest with Cloudflare's Workers pool. Room pairing,
replacement of a role's socket, `peer-*` signals, dropped frames when the peer is absent, the frame
size limit, malformed room IDs, and keepalive auto-response.

**Phone code:**

- `node:test` on a pinned Node for pure logic: channel framing, the loader protocol, key wrapping,
  and the app's view-model code.
- Playwright with WebKit (an iPhone profile) and Chromium (a Pixel profile). It runs the real
  loader and runner against a scripted fake laptop. It covers pairing, bundle delivery and caching,
  one test for each sandbox and security-policy case, the second-`load` fault, link handling, and
  the main app screens. There is no fake DOM.
- The same Noise and framing vectors run in Node and inside Playwright's WebKit.

**On-device checks before building on the stack,** on iOS 17, 18 and 26, in a Safari tab and as a
Home Screen app, and on Android Chrome:

- The runner loads under the explicit-origin policy. A classic `blob:` script runs. Inline script,
  `new Function`, inline style, remote images and `fetch` stay blocked. `adoptedStyleSheets`
  applies.
- Trusted Types makes HTML-string writes throw inside the frame.
- A message port and a 300 KB string pass through `postMessage`.
- The composer stays above the keyboard with the forwarded viewport values. Safe-area insets match
  on a notched iPhone in both orientations.
- A link tap is intercepted. A forced self-navigation fires a second `load`, which the loader
  catches.
- Leaving the page and returning rebuilds the connection and the frame without a visible flash.
- Wrapped X25519 keys survive an IndexedDB round trip.
- jsQR reads the laptop's code in normal room light. Android uses `BarcodeDetector`.
- Focusing the composer does not zoom the page.
- The first screen appears within 2 seconds on a cellular link, and scrolling up through 1,000
  items stays smooth.

## 15. CI

Research: `ci-layout.md`.

- **The `Phone` workflow, `phone.yml`,** tests the relay, the loader and the phone app on Linux, so
  it takes none of the macOS runners the Swift suite competes for:
  - it runs on pushes to `main`, on dispatch, and on every pull request, with no branch filter, so a
    stacked phone PR whose base is another PR's branch gets its own run. It has no path filter,
    because a workflow that a path filter keeps from starting never reports, and a required check
    that never reports blocks the merge. The `changes` job is the path filter;
  - its concurrency group is its own, apart from `test.yml`'s, and is keyed on the pull request's
    number, or on the ref for any other event. Only a pull request's newer push cancels its older
    run. A run for any other event, such as a push to `main`, waits for the one in progress, since a
    cancelled run fails `Phone checks`;
  - a `changes` job runs the classifier, `scripts/ci/phone-parts-needed.sh`, modelled on
    `scripts/ci/swift-suite-needed.sh`. It outputs `relay`, `loader` and `phone_app`. It answers
    `true` for all three on any event but a pull request, and runs every part for any path it does
    not recognize and whenever it cannot compute the diff;
  - a `harness` job, with no `if:`, runs the classifier's harness and the bundle check's harness.
    The classifier's harness also pins the wiring of both phone workflows line by line;
  - the `relay`, `loader` and `phone-app` jobs are each skipped only on the classifier's explicit
    `false`, so a failed gate runs every part rather than none. The `phone-app` job runs the app's
    tests, rebuilds the bundle with `npm run build:app`, and fails if the result differs from the
    committed bundle under `Sources/`. While `phone/package.json` names no `build:app` script, it
    passes only if no bundle is committed;
  - an always-running `Phone checks` job passes when the harness job passed and each part either
    succeeded or was skipped by the classifier's `false`. A cancelled part, or one skipped for any
    other reason, fails it. It is the one context branch protection requires, so exactly one job
    across `.github/workflows/` carries that name. An admin adds it as a required check after the
    workflow lands.
- **Inputs that run more than one part:** `phone/protocol/**` and `phone/test-vectors/**` run the
  Swift suite, the loader and the phone app, and not the relay, which is a self-contained package. A change to `phone.yml`, or to a script under `scripts/`
  named for the phone (the classifier, the bundle check and their harnesses), runs every part. The
  rest of `phone/` outside `loader/` and `app/` is the workspace's shared tooling, such as
  `phone/package.json`, its lockfile, `.nvmrc` and `tsconfig.json`, and runs the loader and the app.
- **The Swift gate's rule:** the Swift suite skips `relay/**` and every path under `phone/` except
  `phone/protocol/**` and `phone/test-vectors/**`. Every path under those two runs it, Markdown
  included, because Swift tests read them. The committed app bundle lives under `Sources/`, so a
  change to it runs the Swift suite. The rule lives in `scripts/ci/swift-suite-needed.sh`, and
  `test.yml` carries nothing phone-specific, because the release workflow, the flake fixer and the
  remote verification valve all read its result.
- **Loader deploy, `phone-loader-deploy.yml`:**
  - runs on pushes to `main` that touch `phone/loader/**` or the workflow itself, and on dispatch.
    No pull request event can start it;
  - a `verify` job runs `npm ci`, `npm run typecheck` and `npm test` in `phone/`. It does not run
    `vectors:check`, which only `phone.yml`'s `loader` job runs. A PR that edits only this workflow
    runs no phone part, so the classifier's harness pins `verify`'s Node setup and working directory
    to the `loader` job's, and requires each of its npm commands to be one the `loader` job runs;
  - a `dispatch` job runs only after `verify` passed, only while the repository variable
    `PHONE_LOADER_DEPLOY_ENABLED` is `true`, and only from `main`, in an environment whose
    deployment branches admit only `main`;
  - that job mints a GitHub App token scoped to the loader repo, whose one permission is Actions:
    write, and asks the loader repo's deploy workflow to publish this commit;
  - the loader repo's workflow checks that the commit is on `main` and that its loader is still the
    newest, then publishes with GitHub's Pages deploy action. A leaked token can start, cancel,
    re-run or disable the loader repo's workflow runs, but cannot change what is served.

## 16. Build order

The parts with no UI come first, so work can start before the phone's visual design is settled.

1. **Secure channel** – the Swift and JavaScript Noise code, the test vectors, and the app-protocol
   fixtures.
2. **Relay and CI** – `relay/cloudflare/`, `phone.yml` with its classifier, and the Swift gate's
   skip rule.
3. **Daemon bridge and laptop UI** – the migration and flag, pairing, devices, the relay link, the
   loader handler, the app protocol with every action and the transcript feed, the Settings pane,
   the menu item and the status-bar chip. Tests drive the app protocol directly, with no phone UI.
4. **Loader and runner** – pairing, the laptop list, keys, the channel, bundle delivery and the
   sandboxed frame. Their screens are built to the Loader group of the reviewed mocks. A minimal
   app bundle lets the whole path be tested from end to end before step 6.
5. **Mock review** – visual mocks of the phone screens in section 8, reviewed with the maintainer
   before any step builds a screen. It can run alongside steps 1 to 3. The reviewed mocks and their
   screenshots are in `docs/design/phone-control/`.
6. **Phone app UI** – the screens in section 8, built to the reviewed mocks.

Steps 4 and 6 build to the mocks, not to a reading of section 8. Each PR that builds or changes a
phone screen shows, for every state it touches, a screenshot of the built screen beside the mock's
screenshot of that state, in light and dark mode at the same size. A visible difference needs a
stated reason, and the maintainer reviews the pairs.

## 17. Rollout

- **The flag.** `phone_control_enabled` is off by default, and the Settings toggle turns it on. The
  maintainer soaks it on their own machines.
- **Graduation.** Flip `Config.phoneControlEnabledDefault` to `true`, a one-line change, because the
  column has no SQL default. An explicit choice survives the flip. Even with the flag on, nothing
  connects until the user sets up a relay and pairs a phone.
- **One-time maintainer setup, outside this repo:** create the loader org and its Pages repo with
  the deploy workflow, create the GitHub App for deploys, and set the repository variable.
- **Docs:** `docs/phone-control.md` (setup, the Deploy button, pairing, revoking, self-hosting the
  loader from a fork), and `relay/cloudflare/README.md`.

## 18. Theory placement

Run against `docs/theory-placement.md`:

- **Compiled, because user-land cannot do it well:** the transport, the encryption, pairing, the
  authority that turns a verified pairing into actions, the record of those actions, and transcript
  shaping. These are mechanism, a security boundary, and the integrity of the record.
- **No compiled theories of "when" or "whether".** v1 takes no action on its own: no alerts, no
  automatic answers, no automatic wakes. Every action starts with a user's tap.
- **Presentation defaults** – the status order, the page sizes, the model alias list – ship in the
  app bundle. They change with a TBD release, and none of them acts on a session.
- **The next theory this exposes:** when to alert. v1.1's push alerts must not compile that
  decision. The daemon will expose the facts (state changes, open prompts), and a user-editable
  rule under `~/tbd/` will decide what to push.

## 19. Rejected alternatives

- **Turning on Claude Code's Remote Control as the whole answer** – TBD could add
  `--remote-control <name>` to the sessions it launches, and the Claude app would then cover
  transcript, send, answer and push for Claude. It needs a paid claude.ai login, so API-key,
  Bedrock and proxy users cannot use it. It does not cover Codex or remote-provider sessions.
  Anthropic stores the transcript while the session is connected, and a mode change from the phone
  can drop a TBD session out of bypass mode with no way back. It may still be worth offering as a
  separate toggle for Claude subscribers. (`vendor-remote-control.md`)
- **A relay the maintainer hosts** – the simplest setup for users, and how Orca does it, but TBD is
  multi-tenant open source and will not depend on a backend the maintainer runs. (`orca.md`)
- **Peer-to-peer over WebRTC** – it still needs a meeting point and, for phones on cellular, a TURN
  relay. Public meeting points are unreliable: 2 of Trystero's 5 default trackers were dead when
  probed, and public MQTT brokers are for testing only. About 40% of carrier networks use the kind
  of NAT that cannot reach a normal home router, and iOS drops the connection whenever the page
  leaves the foreground. The laptop side needs a large native library. Look again when setup proves
  to be the real barrier, when IPv6 direct connections are measured to work, or when WebTransport is
  practical on the phone. (`p2p.md`)
- **Tailscale or another VPN** – the phone must run the VPN app, and iOS allows one VPN at a time.
  (`transports.md`)
- **Same Wi-Fi only** – useless away from home, which is the whole point.
- **Cloudflare Tunnel** – quick tunnels change URL on every run, named tunnels need a domain, and
  Cloudflare sees plaintext. (`transports.md`)
- **The relay serving the phone page** – whoever controls the relay's account could change the
  code and read the keys. (`phone-clients.md`)
- **A static app that supports a range of laptop versions** – workable, and Orca's model, but the
  page would carry old code paths for every TBD release still in use. Sending the app from the
  laptop removes that burden and leaves only the small loader protocol to keep stable.
- **Hosting the loader at `cheapsteak.github.io`** – every Pages site on that account shares one
  origin, and with it the stored keys. (`phone-clients.md`)
- **Each user hosting the loader from a fork** – every user would have to set up Pages and sync
  updates. Users who want this can still do it through the loader URL setting.
- **A native iOS app** – push needs a paid Apple developer account and a central push gateway, and
  App Review is a risk. (`phone-clients.md`)
- **A chat bot (Telegram, Slack, Discord)** – no client to build, but the chat platform sees every
  transcript. (`third-party-tools.md`)
- **A separate user-land bridge process** – it would need a new socket identity allowed to answer
  prompts, which is the security-critical part spread over two processes, plus something to keep it
  running.
- **The bridge inside the TBD app** – phone control would work only while the app is open, and the
  UI process would host a network service.
- **The macOS Keychain for the laptop key** – TBD's binaries are rebuilt and re-signed on update,
  and the Keychain ties access to the code signature. TBD already keeps secrets as owner-only files.
- **A per-device secret after pairing** – Noise `IK` already proves both static keys. A secret
  would add storage and a leak path without adding protection.
- **A `srcdoc` frame for the app** – it inherits the loader's security policy, which blocks the
  bundle. (`phone-app-stack.md`)
- **Preact with htm** – its appeal is running with no build step. The bundle is a committed build
  anyway, so React's ecosystem costs users nothing, and Preact's smaller size matters little for a
  download made once per TBD version.
- **Compressing transcript data** – size would reveal content to the relay (the BREACH pattern).
- **Face ID unlock through a passkey** – stronger against a thief with an unlocked phone. The bar
  for v1 is the phone's own lock screen plus revoke on the laptop, which keeps the loader simpler.
- **Per-repo opt-in** – narrower reach for a stolen phone. Phone control covers every repo, as the
  app does, and the master switch and per-phone revoke bound the risk.

## 20. Follow-ups

- **Codex transcripts and actions (v1.1)** – their own spec. TBD has no Codex transcript surface
  today.
- **Push alerts (v1.1)** – Web Push sent by the laptop itself, encrypted to the phone (RFC 8291), so
  neither Apple, Google nor the relay can read it. It needs the Home Screen install and pairing
  inside the installed app. When to alert is a user-land rule (section 18).
- **Interrupt** – needs a reliable mechanism. A raw Escape key does different things in different
  states, and the provider contract has no interrupt verb.
- **Remote profile switching and forking** – needs a TBD caller for the contract's `set-profile`
  verb.
- **A direct path** – see the triggers in "Rejected alternatives".
- **Plan approval** – how an `ExitPlanMode` request reaches `PendingPromptStore` is unverified. If
  it arrives as a permission prompt, the card shows the plan text from the tool input. The
  implementation checks this first.

## References

All under `docs/research/2026-11-07-phone-control/`:

- `orca.md` – how Orca connects its phone app.
- `vendor-remote-control.md` – Claude Code Remote Control, channels, Codex, Cursor and Copilot.
- `third-party-tools.md` – Happy, Omnara, VibeTunnel, chat bots and push services.
- `transports.md` – Cloudflare Workers, Tunnel, Tailscale, WebRTC, Apple services, and the
  encryption scheme.
- `p2p.md` – peer-to-peer options and when only the laptop's network is good.
- `phone-clients.md` – PWA, native app and chat-app clients.
- `phone-app-stack.md` – frame isolation, framework, libraries and tests, with a WebKit test run.
- `ci-layout.md` – today's CI and the proposed layout.
