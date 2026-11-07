# Third-party tools and chat-app approaches to phone control

Sources accessed 2026-11-07. Source code was read at the commits linked below, and none of it was run.

## Summary

Almost every tool that works through NAT uses the same transport: the laptop opens an outbound connection to something on the public internet, and the phone talks to that same thing. Only the third party in the middle changes: a dedicated relay (Happy, HAPI's tunnel, Omnara), a vendor API (Claude Code Remote Control, Codex), a chat platform (Telegram long polling, Slack Socket Mode, the Discord Gateway), or a push service (ntfy). Tools that serve a local web page instead (VibeTunnel, CloudCLI) hand the reachability problem to Tailscale, ngrok or Cloudflare Tunnel. Happy is the only widely used project with application-layer end-to-end encryption. Its design is worth copying: the account key is born on the phone, a QR code pairs the laptop, and each session gets its own data key. Its relay still sees a lot of metadata, though. Its pushes carry session titles in plaintext. Its pairing endpoint hands out a long-lived bearer token to anyone who presents the public key shown in the QR code. Push to iOS needs APNs credentials, which belong to whoever publishes the app. Self-hosted setups therefore reuse the publisher's push relay, and the better ones send either content-free pushes (ntfy) or encrypted pushes (HAPI). Chat bots need no relay and no app, and their buttons map well onto Claude's prompts. In return, the chat platform sees the whole transcript, and one Telegram bot token supports only one poller. Two projects show what to avoid. Omnara shut down its Claude Code wrapper because screen-scraping the TUI could not keep up with Claude Code releases. Claude-Code-Remote scrapes the screen and auto-selects "Yes, and don't ask again" on permission prompts. First-party options now exist for Claude Code (Remote Control and channels) and for the Codex desktop app. They are covered in depth in [vendor-remote-control.md](vendor-remote-control.md) and only briefly here.

## How to read this report

- **Primary sources** – each key claim links to the code at a pinned commit or to the vendor's own documentation.
- **Our reading** – some security observations come from reading code, not from running it. These are labelled "our reading".
- **Unverified** – claims we could not confirm against a primary source are labelled "unverified".

Pinned commits:

- `slopus/happy` at [`490c33a`](https://github.com/slopus/happy/tree/490c33a60fc9265a2a606886cfec026ea25e570d)
- `omnara-ai/omnara` at [`01ecca9`](https://github.com/omnara-ai/omnara/tree/01ecca98c6dc9d1f0b30472dd0b868c4b9ec9987) (current), and the legacy wrapper at [`500a82a`](https://github.com/omnara-ai/omnara/tree/500a82ad85ba35d0a478810bb00e944ba93071b1)
- `amantus-ai/vibetunnel` at [`f78324f`](https://github.com/amantus-ai/vibetunnel/tree/f78324f5a6f5617711581cf5b119651094b2d9bc)
- `siteboon/claudecodeui` at [`2053f3d`](https://github.com/siteboon/claudecodeui/tree/2053f3d7a086fd44f7fe373c913da487629b0a95)
- `JessyTsui/Claude-Code-Remote` at [`cd172b2`](https://github.com/JessyTsui/Claude-Code-Remote/tree/cd172b2f3361ccb60d7e691dcca768980a2eb13d)
- `anthropics/claude-plugins-official` at [`0412be7`](https://github.com/anthropics/claude-plugins-official/tree/0412be76f50ab4f4f8abff3753efa9269fbbca5b)
- `tiann/hapi` at [`ee1e6ae`](https://github.com/tiann/hapi/tree/ee1e6ae7c2ffffad8859b5c671ac32e41eecf7d2)

## 1. Happy (happy.engineering)

Happy is an MIT-licensed mobile app (iOS, Android, web) with a CLI and a relay server. It has about 24.5k GitHub stars. The CLI, the server, the native apps and a push Worker now live in one monorepo, [`slopus/happy`](https://github.com/slopus/happy/tree/490c33a60fc9265a2a606886cfec026ea25e570d). The older `slopus/happy-cli` and `slopus/happy-server` repositories stopped receiving pushes in February 2026.

### How the phone reaches the laptop

- **Both ends dial out to the relay.** Happy uses one Socket.IO endpoint, `/v1/updates`. The CLI holds a session-scoped socket and a machine-scoped socket, and the app holds a user-scoped socket ([realtime-sync-and-rpc.md](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/docs/realtime-sync-and-rpc.md?plain=1#L13-L36)).
- **Control traffic is RPC over the same socket.** A handler registers a method in a room named `rpc:<userId>:<method>`. A caller emits `rpc-call`, and the server forwards it to the socket that owns the room ([realtime-sync-and-rpc.md](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/docs/realtime-sync-and-rpc.md?plain=1#L50-L58)).
- **RPC payloads are encrypted, and method names are not.** The handler decrypts the params and encrypts the result with the session's key ([RpcHandlerManager.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/rpc/RpcHandlerManager.ts#L78-L88)).
- **The hosted relay is free.** Happy runs it. The push notification code defaults to `https://api.cluster-fluster.com` ([pushNotifications.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/pushNotifications.ts#L79)).

### Pairing and key exchange

The account is created on the phone, and the laptop is paired to it with a QR code.

- **The account key is born on the phone.** The app creates a random 32-byte secret ([AuthService.swift](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-ios/Sources/HappyCore/Auth/AuthService.swift#L18-L36)). From it the app derives an Ed25519 signing key pair, used to sign in, and a separate "content" X25519 key pair, derived with a key tree ([AccountKeys.swift](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-ios/Sources/HappyCrypto/AccountKeys.swift#L21-L30)).
- **Signing in proves possession of the key.** The app signs a random challenge. The server checks the signature and upserts an account keyed by the public key ([authRoutes.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server/sources/app/api/routes/authRoutes.ts#L9-L39)). The client picks the challenge, not the server.
- **The terminal makes a throwaway key pair.** `happy` creates an ephemeral X25519 key pair with tweetnacl, posts the public key to `/v1/auth/request`, and shows `happy://terminal?<base64url public key>` as a QR code ([auth.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/ui/auth.ts#L27-L44), [L102](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/ui/auth.ts#L102)).
- **The phone answers with the public half only.** The phone seals `0x00 || content public key` to the terminal's public key and posts it to `/v1/auth/response`. The terminal never receives the master secret ([AccountKeys.swift](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-ios/Sources/HappyCrypto/AccountKeys.swift#L59-L72)). Linking another of the user's own phones is a separate flow, and that flow does hand over the master secret.
- **The terminal collects the answer by polling.** It polls `/v1/auth/request` once a second. When the phone has answered, the server returns a bearer token and the sealed answer. The terminal decrypts the answer and makes a random local machine key ([auth.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/ui/auth.ts#L160-L215)).
- **A browser flow does the same job.** It puts the same public key in a web URL instead of a QR code ([auth.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/ui/auth.ts#L115-L140)).

### Encryption

- **Library** – tweetnacl (NaCl `box` and `secretbox`) plus Node's AES-256-GCM. libsodium is not used. One helper reproduces libsodium's key derivation by hand ([encryption.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/encryption.ts#L55-L79)).
- **Current scheme ("dataKey")** – each session and machine gets a random AES-256-GCM key. The key is wrapped to the account's content public key with an ephemeral-key `box`, and the server stores the wrapped key. Wire layout: `version(1) | nonce(12) | ciphertext | tag(16)` ([encryption.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/encryption.ts#L154-L174), [encryption.md](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/docs/encryption.md)).
- **Legacy scheme** – XSalsa20-Poly1305 `secretbox` under the shared 32-byte master secret ([encryption.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/encryption.ts#L87-L112)). The new iOS app refuses to open legacy records ([AccountKeys.swift](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-ios/Sources/HappyCrypto/AccountKeys.swift#L6-L8)).
- **Blast radius** – a stolen laptop exposes its own sessions' data keys. It does not expose the master secret or other machines' sessions ([Happy security page](https://happy.engineering/docs/security)).

### What the relay stores and sees

- **Encrypted** – session metadata, agent state (including pending permission requests), messages, machine metadata, artifacts and key-value values ([encryption.md](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/docs/encryption.md)).
- **Plaintext** – the account public key, session IDs, a random tag, sequence numbers, `active` and `lastActiveAt` ([schema.prisma](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server/prisma/schema.prisma#L95-L113)); token counts and cost per session ([types.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server/sources/storage/types.ts#L10-L20)); push tokens; RPC method names; and message timing and sizes.
- **Encrypted with a server key** – GitHub OAuth tokens and stored vendor API tokens. The server can decrypt these ([encryption.md](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/docs/encryption.md)).

### How the CLI wraps Claude Code

Happy runs one of two modes and switches between them ([loop.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/claude/loop.ts#L80-L110)).

- **Local mode** – the normal interactive `claude` runs in the terminal. A scanner tails the JSONL transcript and mirrors each entry to the relay ([claudeLocalLauncher.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/claude/claudeLocalLauncher.ts#L15-L29)).
- **Remote mode** – when a message arrives from the phone, Happy stops the local `claude` and continues the session through the Claude Agent SDK ([claudeLocalLauncher.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/claude/claudeLocalLauncher.ts#L84-L92)). The phone therefore never answers the TUI's own dialog. It takes the session over instead.
- **Permission prompts** – in remote mode, the SDK's `canUseTool` callback ([query.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/claude/sdk/query.ts#L73-L77)) records the request in encrypted agent state. The phone answers through a `permission` RPC carrying the request ID, approve or deny, an optional mode change and an optional tool allowlist. A response with an unknown ID is ignored ([permissionHandler.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/claude/utils/permissionHandler.ts#L376-L393)).

### What the phone shows and can do

The app shows a session list, a chat view of the transcript, and permission requests. It can send messages, approve or deny prompts (once, or for the whole session), change the permission mode, abort, and spawn or stop sessions on a paired machine. The CLI also gives the phone `bash`, `readFile`, `writeFile`, `listDirectory` and `ripgrep` RPCs ([registerCommonHandlers.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/modules/common/registerCommonHandlers.ts#L176)). So anyone holding the content key can run commands on the laptop.

### Push notifications

- **The text is fixed and goes out in plaintext.** The CLI sends one of three titles: "It's ready!", "Permission request" or "Clarification needed". The body is the session summary or the project folder name ([pushNotifications.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/pushNotifications.ts#L46-L72)). It posts them to `/v1/sessions/:id/push-event`, and the server suppresses the push when the user is active elsewhere ([pushNotifications.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-cli/src/api/pushNotifications.ts#L249-L290)). Happy's self-hosting guide confirms that the kind and title travel in plaintext through Expo to Apple or Google ([self-hosting guide](https://happy.engineering/docs/guides/self-hosting/)).
- **Delivery is moving to a Cloudflare Worker.** Happy's own Worker is replacing Expo's push service. Sending needs no credentials. An unguessable `HappyPushToken[…]` of about 131 bits is the capability, so any self-hosted Happy server can use the shared Worker ([happy-push-server README](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-push-server/README.md?plain=1#L29)). The README calls its trust model the same as Expo's: "anyone who knows an install's `deviceId` and `appId` can re-point its `HappyPushToken[…]` token" ([L59](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-push-server/README.md?plain=1#L59)).

### Self-hosting, cost and setup effort

- **Self-hosting** – `npm install -g happy happy-server-self-host`, then `happy server`, runs the relay with embedded PGlite and local file storage ([happy-server-self-host README](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server-self-host/README.md)). The guide also offers a Docker image. It asks for a `HANDY_MASTER_SECRET`, recommends HTTPS behind a reverse proxy, and points the phone at the server through a hidden developer setting when the user is already signed in ([self-hosting guide](https://happy.engineering/docs/guides/self-hosting/)). The phone and the laptop must both reach the server, so self-hosting in practice means a public HTTPS host or a tailnet.
- **Cost** – the app, the CLI and the hosted relay are free. Voice is paid and runs through ElevenLabs ([paid-voice.md](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/docs/paid-voice.md)).
- **Effort** – low on the hosted relay: run `npm install -g happy`, run `happy claude`, and scan the QR code. Self-hosting is high effort for a non-expert, because it needs a reachable HTTPS server.

### Weaknesses we found (our reading, not tested)

- **The pairing value is a bearer credential that never expires.** `/v1/auth/request` is unauthenticated. Its only input is the terminal's public key, which is printed in the QR code and the URL. Once the phone approves, any caller presenting that public key gets a fresh account token, and the server never deletes the pairing row ([authRoutes.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server/sources/app/api/routes/authRoutes.ts#L41-L87), [schema.prisma](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server/prisma/schema.prisma#L59-L68)). The tokens come from a persistent generator with no expiry ([auth.ts](https://github.com/slopus/happy/blob/490c33a60fc9265a2a606886cfec026ea25e570d/packages/happy-server/sources/app/auth/auth.ts#L36-L45)). Anyone who saw the QR code, for example in a screen share or a demo video, could therefore get an API token for the account. The token would not decrypt anything. It would expose metadata and the account's push tokens, and it would allow destructive API calls.
- **The phone can do much more than chat.** The `bash` and file RPCs turn "control my agent" into "run commands on my laptop".
- **Pushes leak titles.** Folder names and session summaries reach Expo, Apple and Google in plaintext.

## 2. Omnara

Omnara has had two lives, and the first one ended for a reason that matters to TBD.

- **Legacy Omnara (July to November 2025)** – a Python package, `pip install omnara`, wrapped Claude Code and Codex. It reported to Omnara's hosted API, which kept data in Postgres and sent push, email and SMS notifications. A web dashboard and iOS and Android apps read from that API ([legacy README](https://github.com/omnara-ai/omnara/blob/500a82ad85ba35d0a478810bb00e944ba93071b1/README.md)).
  - **Transport** – outbound HTTPS from the laptop to `agent.omnara.com`, authenticated with an API key. An `omnara serve` mode exposed an endpoint so the dashboard could start sessions remotely (same README).
  - **Wrapping** – the wrapper ran `claude` in a PTY and tailed its JSONL log ([claude_wrapper_v3.py](https://github.com/omnara-ai/omnara/blob/500a82ad85ba35d0a478810bb00e944ba93071b1/src/integrations/cli_wrappers/claude_code/claude_wrapper_v3.py#L429)). It detected permission prompts by scanning the terminal buffer for "Do you want" ([L708-L766](https://github.com/omnara-ai/omnara/blob/500a82ad85ba35d0a478810bb00e944ba93071b1/src/integrations/cli_wrappers/claude_code/claude_wrapper_v3.py#L708-L766)).
  - **Encryption** – none beyond TLS. The architecture diagram shows the hosted API storing data and syncing it to devices. We found no end-to-end encryption in the legacy code.
  - **Why it ended** – the deprecation notice says: "This version was built as a wrapper around the Claude Code CLI, which became unfeasible to maintain with Claude Code's constant updates" ([legacy README L5](https://github.com/omnara-ai/omnara/blob/500a82ad85ba35d0a478810bb00e944ba93071b1/README.md?plain=1#L5)). Omnara offered paying customers refunds. The subscription prices are unverified.
- **Current Omnara (relaunched August 2026)** – an Apache-2.0 "open-source managed agent platform" written in Go. It is no longer a phone front end for Claude Code ([README](https://github.com/omnara-ai/omnara/blob/01ecca98c6dc9d1f0b30472dd0b868c4b9ec9987/README.md)).
  - **Transport** – the agent loop runs on Omnara's workers, which call the model themselves. A user's laptop is only a "machine" running the `omnarad` daemon, "which connects out to Omnara, so agents can run commands there without any inbound ports" ([README L193](https://github.com/omnara-ai/omnara/blob/01ecca98c6dc9d1f0b30472dd0b868c4b9ec9987/README.md?plain=1#L193), [connect.mdx](https://github.com/omnara-ai/omnara/blob/01ecca98c6dc9d1f0b30472dd0b868c4b9ec9987/docs/machines/connect.mdx?plain=1#L61)).
  - **Pairing** – a one-time machine token, pasted into the `omnarad` installer.
  - **Visibility** – the control plane holds every agent's event log in Postgres, so it sees everything.
  - **Hosting** – there is a hosted cloud, or you can self-host with Docker Compose. A public URL is needed for some features.
  - **Phone** – the dashboard, CLI, Slack, Discord and GitHub. Slack uses HTTP events with Socket Mode off ([slack.mdx](https://github.com/omnara-ai/omnara/blob/01ecca98c6dc9d1f0b30472dd0b868c4b9ec9987/docs/integrations/slack.mdx?plain=1#L69)). Whether a native mobile app still ships is unverified.

## 3. VibeTunnel

VibeTunnel is MIT-licensed, has about 4.7k stars, and saw its last push in August 2026. It is a macOS menu bar app plus a Node server that streams terminals to a browser ([README](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/README.md)). It shows a terminal, not a transcript.

- **How the phone reaches the laptop** – VibeTunnel has no relay of its own. The server listens on port 4020, and the README lists six ways to reach it ([README L182-L310](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/README.md?plain=1#L182-L310)):
  - **Tailscale** (recommended) – optionally Tailscale Serve for HTTPS inside the tailnet, or Funnel for public access.
  - **ngrok** – a public URL from the user's ngrok account.
  - **Local network** – direct access over the LAN.
  - **Cloudflare Quick Tunnel** – `cloudflared tunnel --url`.
  - **Pinggy** – another tunnel service.
  - **Pangolin** – a self-hosted tunnel, with its credentials kept in the Keychain.
- **Auth** – the default is the macOS account password, or PAM on Linux. The alternatives are an environment-variable password, Ed25519 keys from `~/.ssh/authorized_keys`, and "no auth". Browser sessions use JWTs ([README L397-L440](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/README.md?plain=1#L397-L440)). The README's one-shot example is `npx -y vibetunnel --no-auth --ngrok` ([L502](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/README.md?plain=1#L502)), which publishes an unauthenticated shell to the internet.
- **Encryption** – TLS from the tunnel or proxy only. Every tunnel provider that terminates TLS can see the terminal stream.
- **Phone** – a responsive web UI. The native iOS app "is still work in progress and not recommended for production use yet" ([L170](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/README.md?plain=1#L170)).
- **Push** – Web Push through a service worker, which needs HTTPS. The events come from terminal activity: command finished, command failed, bell ([push-notification.md](https://github.com/amantus-ai/vibetunnel/blob/f78324f5a6f5617711581cf5b119651094b2d9bc/docs/push-notification.md)).
- **Cost and effort** – free. Setup is easy on a LAN, and Tailscale needs an app on each device.

## 4. Other projects

The first-party options are summarised here. [vendor-remote-control.md](vendor-remote-control.md) covers them in depth.

- **Claude Code Remote Control** (Anthropic, first-party) – the local `claude` "registers with the Anthropic API and polls for work". It "makes outbound HTTPS requests only and never opens inbound ports" ([docs](https://code.claude.com/docs/en/remote-control)).
  - **Encryption** – TLS to Anthropic only, with "multiple short-lived credentials, each scoped to a single purpose".
  - **Phone** – the Claude app or claude.ai/code shows the conversation. It can send text and files, answer permission prompts and `AskUserQuestion`, and stop subagents.
  - **Push** – there are push toggles for "Claude decides" and "actions required". Pushes are skipped while the user types at the terminal, and `CLAUDE_CLIENT_PRESENCE_FILE` widens that suppression.
  - **Turning it on** – a session joins with `claude --remote-control`, or every session joins when `remoteControlAtStartup` is set.
  - **Requirements** – a Pro, Max, Ultra, Team or Enterprise login. API keys, Bedrock, Vertex, Foundry and a custom `ANTHROPIC_BASE_URL` are not supported. ZDR and HIPAA organisations cannot use it, and Team and Enterprise need an admin toggle.
- **Claude Code channels** (Anthropic, research preview) – MCP server plugins that push chat messages into a running session ([docs](https://code.claude.com/docs/en/channels)).
  - **Platforms** – the official set is Telegram, Discord and iMessage. The plugins need Bun.
  - **Pairing** – you message the bot, receive a code, and approve the code in the terminal. That adds you to a sender allowlist.
  - **Prompts** – a channel can relay permission prompts. The Telegram plugin sends `✅ Allow` and `❌ Deny` inline buttons with callback data `perm:allow:<id>`, and also accepts a typed `yes <id>` ([server.ts](https://github.com/anthropics/claude-plugins-official/blob/0412be76f50ab4f4f8abff3753efa9269fbbca5b/external_plugins/telegram/server.ts#L420-L450), [L928-L940](https://github.com/anthropics/claude-plugins-official/blob/0412be76f50ab4f4f8abff3753efa9269fbbca5b/external_plugins/telegram/server.ts#L928-L940)).
- **Codex remote control** (OpenAI, first-party) – the ChatGPT app pairs by QR code with a host that runs the ChatGPT desktop app. "Mobile setup starts from the app; you can't set it up from the Codex CLI or IDE extension." Traffic goes through "a secure relay layer" whose internals are not documented ([docs](https://learn.chatgpt.com/docs/remote-connections)). Because setup cannot start from the CLI, it does not cover Codex CLI sessions that TBD launches.
- **HAPI** (`tiann/hapi`, AGPL-3.0, about 5.4k stars) – a "local-first alternative to Happy". Each user runs a single-binary hub with SQLite on the laptop ([why-hapi.md](https://github.com/tiann/hapi/blob/ee1e6ae7c2ffffad8859b5c671ac32e41eecf7d2/docs/guide/why-hapi.md)).
  - **Transport** – `hapi hub --relay` uses tunwg (WireGuard plus TLS), and "the relay only forwards opaque packets". Users can instead expose the hub themselves through Cloudflare Tunnel or Tailscale.
  - **Clients** – a free PWA, paid native apps and a Telegram Mini App. The clients use REST plus server-sent events ([how-it-works.md](https://github.com/tiann/hapi/blob/ee1e6ae7c2ffffad8859b5c671ac32e41eecf7d2/docs/guide/how-it-works.md)).
  - **Push** – its push design is the best we found. Each phone generates a 32-byte `pushKey`. The hub encrypts the notification with AES-256-GCM, and a Notification Service Extension decrypts it on the phone. "Neither Apple nor the optional hapi push relay can read notification content" ([native-companion-contract.md](https://github.com/tiann/hapi/blob/ee1e6ae7c2ffffad8859b5c671ac32e41eecf7d2/docs/api/native-companion-contract.md?plain=1#L181-L245)).
- **Happier** (`happier-dev/happier`, MIT, about 2.2k stars) – an end-to-end encrypted relay in the style of Happy, with a one-command self-hosted relay. It says the relay sees "session ids, timestamps, turn status and usage metadata" ([README](https://github.com/happier-dev/happier/blob/f6f4032ffe21310f83a652c0c7dc07a205e66ee8/README.md)). Not reviewed further.
- **CloudCLI, formerly Claude Code UI** (`siteboon/claudecodeui`, AGPL-3.0, about 14.5k stars) – a web UI for Claude Code, Cursor CLI and Codex. It runs on the laptop, and permission prompts go through the Agent SDK's `canUseTool`. A hosted cloud starts at €7 a month ([README](https://github.com/siteboon/claudecodeui/blob/2053f3d7a086fd44f7fe373c913da487629b0a95/README.md?plain=1#L224)).
  - **Reaching it** – "Browser via `[yourip]:port`" on the local network. The server binds `0.0.0.0` over plain HTTP by default ([index.ts](https://github.com/siteboon/claudecodeui/blob/2053f3d7a086fd44f7fe373c913da487629b0a95/server/index.ts#L283)).
  - **Auth** – single-user username and password. The first visitor to register becomes the user ([auth.service.ts](https://github.com/siteboon/claudecodeui/blob/2053f3d7a086fd44f7fe373c913da487629b0a95/server/modules/auth/auth.service.ts#L51-L75)). On a shared network, someone else could claim the instance before its owner does (our reading). The JWT is also accepted as a query parameter for server-sent events, which tends to leak tokens into logs ([auth.middleware.ts](https://github.com/siteboon/claudecodeui/blob/2053f3d7a086fd44f7fe373c913da487629b0a95/server/modules/auth/auth.middleware.ts#L47-L48)).
- **Claude-Code-Remote** (`JessyTsui/Claude-Code-Remote`, MIT, about 1.3k stars, last push December 2025) – control through email (SMTP and IMAP), Telegram, Discord or LINE.
  - **Notifications** – Claude Code hooks send a notification when a turn completes or Claude is waiting.
  - **Transport** – Telegram runs as a webhook, so it needs a public URL: "use ngrok for local testing" ([README](https://github.com/JessyTsui/Claude-Code-Remote/blob/cd172b2f3361ccb60d7e691dcca768980a2eb13d/README.md?plain=1#L140-L151)).
  - **Injection** – replies are typed into the session with `tmux send-keys` or through a PTY.
  - **Prompt handling** – after injecting a command, it scrapes the screen. If it sees "Do you want to proceed?", it selects option 2, "Yes, and don't ask again" ([tmux-injector.js](https://github.com/JessyTsui/Claude-Code-Remote/blob/cd172b2f3361ccb60d7e691dcca768980a2eb13d/src/relay/tmux-injector.js#L175-L200)). A remote message therefore silently widens the session's permissions.
- **claude-code-telegram** (`overwirehq/claude-code-telegram`, about 2.8k stars, no license file) – a Telegram bot that drives Claude through the Agent SDK. It has a user-ID allowlist and an approved-directory sandbox ([README](https://github.com/overwirehq/claude-code-telegram/blob/164afc1b9d3cb8cc37abd3c930cfb897257c4af9/README.md)).
- **The do-it-yourself baseline** – an SSH client on the phone, plus Tailscale, plus tmux or mosh. It gives a terminal, not a transcript, and it needs no third-party relay.

## 5. Chat-bot approaches

All three platforms let the laptop connect outbound, so none needs a public URL. In all three, the platform stores and can read every message.

### Telegram bot

- **What the user does** – message @BotFather, run `/newbot`, and copy the token. No admin or company approval is involved ([channels docs](https://code.claude.com/docs/en/channels)).
- **Transport** – `getUpdates` long polling over outbound HTTPS. "This method will not work if an outgoing webhook is set up" ([Bot API](https://core.telegram.org/bots/api#getupdates)).
- **One poller per token** – "Telegram allows exactly one getUpdates consumer per token". A second poller gets 409 Conflict ([server.ts](https://github.com/anthropics/claude-plugins-official/blob/0412be76f50ab4f4f8abff3753efa9269fbbca5b/external_plugins/telegram/server.ts#L58-L61)). For TBD, the daemon would own the single poll loop and route updates to sessions itself. One bot per Claude session does not work.
- **What Telegram sees** – everything. Bot conversations are cloud chats, which "use client-server/server-client encryption and are stored encrypted in the Telegram Cloud". Only secret chats are end-to-end encrypted ([Telegram FAQ](https://telegram.org/faq)). The Bot API documents no secret-chat support.
- **Limits** – about 1 message per second per chat, 20 per minute in a group, and about 30 per second across all chats ([Bots FAQ](https://core.telegram.org/bots/faq)). A message holds 1 to 4096 characters ([Bot API](https://core.telegram.org/bots/api#sendmessage)). A live transcript must be batched, or edited in place.
- **Prompt buttons** – inline keyboards carry `callback_data` of 1 to 64 bytes, which is room for a short request ID. The bot must call `answerCallbackQuery` after each press, or the client shows a progress bar ([Bot API](https://core.telegram.org/bots/api#inlinekeyboardbutton)). Allow and Deny map to one button each, and each `AskUserQuestion` option can be its own button. A free-text answer can be a reply message. A Mini App can host a full web UI inside Telegram, but it needs an HTTPS URL. HAPI uses one.
- **Cost** – free.

### Slack app in Socket Mode

- **What the user does** – create an app, enable Socket Mode, and generate an app-level token with `connections:write`. Add bot scopes and install the app into a workspace ([connections:write](https://docs.slack.dev/reference/scopes/connections.write/)). By default members can install apps without approval, but "Workspace Owners can enable app approval" ([Slack help](https://slack.com/help/articles/222386767-Manage-app-approval-for-your-workspace)). In a company workspace, the user often needs an admin.
- **Transport** – `apps.connections.open` returns a WebSocket URL, and events and interactive payloads arrive over it. An app can hold up to 10 connections and must handle refreshes "once every few hours". Socket Mode apps are "not currently allowed in the public Slack Marketplace" ([Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode)). That is fine for a self-made app per user, but TBD could not ship one shared app.
- **What Slack sees** – everything. In an employer's workspace, the employer's admins and retention policies apply to the agent transcript.
- **Limits** – "no more than one message per second per channel" ([rate limits](https://docs.slack.dev/apis/web-api/rate-limits)). An interaction must be acknowledged within 3 seconds, and `response_url` can be used 5 times within 30 minutes ([interactivity](https://docs.slack.dev/interactivity/handling-user-interaction)).
- **Prompt buttons** – Block Kit buttons for Allow and Deny, select menus for multiple choice, and modals for free text. All of these map well.
- **Cost** – free on any plan. Setup takes the most clicks of the three.

### Discord bot

- **What the user does** – create an application in the Developer Portal and copy the bot token. Enable the privileged Message Content intent, then invite the bot to a server the user manages through an OAuth2 URL ([channels docs](https://code.claude.com/docs/en/channels)).
- **Transport** – an outbound Gateway WebSocket. Interactions arrive either over the Gateway or at an Interactions Endpoint URL, never both ([Discord docs](https://docs.discord.com/developers/interactions/receiving-and-responding)).
- **What Discord sees** – everything. Text "is not end-to-end encrypted". DAVE encryption covers only audio and video ([Discord blog](https://discord.com/blog/meet-dave-e2ee-for-audio-video)).
- **Limits** – 50 requests per second globally, and interaction endpoints are exempt ([rate limits](https://docs.discord.com/developers/topics/rate-limits)). The bot must answer an interaction within 3 seconds, and the interaction token stays valid for 15 minutes ([interactions](https://docs.discord.com/developers/interactions/receiving-and-responding)).
- **Prompt buttons** – buttons, select menus and modals, the same fit as Slack.
- **Cost** – free.

## 6. Push-only services

### ntfy

ntfy is dual-licensed Apache-2.0 and GPLv2, with about 35k stars. It runs at ntfy.sh, or you can self-host a single Go binary.

- **Transport** – the laptop publishes with an HTTP POST. A subscriber, the phone app or the laptop itself, holds an outbound stream (JSON, server-sent events or WebSocket). No public URL is needed on the laptop.
- **Two-way traffic is possible.** A notification can carry up to three action buttons. An `http` action "sends a HTTP request when the action button is tapped", with a configurable method, headers and body. Action buttons are marked as supported on Android, iOS and web ([publish docs source](https://github.com/binwiederhier/ntfy/blob/main/docs/publish.md?plain=1#L1160-L1163), [L2047-L2050](https://github.com/binwiederhier/ntfy/blob/main/docs/publish.md?plain=1#L2047-L2050)). A tap can POST "allow <id>" to a second topic that the laptop subscribes to. Any header in the action, such as an auth token, travels inside the notification, so the server sees it.
- **End-to-end encryption** – none. The issue requesting it ([ntfy#69](https://github.com/binwiederhier/ntfy/issues/69)) has been open since December 2021. Whoever runs the server sees titles, bodies and action URLs.
- **iOS and self-hosting** – a self-hosted server gets prompt iOS delivery by setting `upstream-base-url`. Each message then sends ntfy.sh a poll request that "contains only the message ID", and the phone fetches the content from the user's own server. Without it, delivery "can take hours" ([config docs](https://docs.ntfy.sh/config/)).
- **Auth and limits** – without an account, "the topic is essentially a password". Access tokens and ACLs exist. Messages are cached for 12 hours by default. On ntfy.sh, "the daily message limit is 250", and a message holds 4096 bytes, with longer ones sent as attachments ([publish docs](https://docs.ntfy.sh/publish/)). Paid ntfy.sh tiers raise these limits. The prices, about $5 to $12 a month in third-party listings, are unverified.
- **Effort** – low. Install the app, pick a long random topic, and POST to it.

### Pushover

- **One-way** – no action buttons. The back channels are a supplementary URL (up to 512 characters) and emergency-priority acknowledgement. The laptop can poll the acknowledgement through the receipts API, or receive it at a public callback URL ([API](https://pushover.net/api)).
- **Encryption** – the API page describes opt-in end-to-end encryption in app version 5.0 and later, with a 256-bit key stored on the device ([API](https://pushover.net/api), [support note](https://support.pushover.net/i244-implement-end-to-end-encryption)). How the key reaches the sender, and which cipher is used, is unverified.
- **Limits** – a message holds 1024 characters and a title 250. An account gets 10,000 messages a month for free across all its applications ([API](https://pushover.net/api)).
- **Cost** – $4.99 once per platform after a 30-day trial. Teams cost $5 per user per month ([pricing](https://pushover.net/pricing)).
- **iOS** – a native app, with push delivered over APNs.

### Web Push to a PWA

VibeTunnel and HAPI also use Web Push. On iOS it works only for a web app that the user added to the home screen, on iOS 16.4 or later ([WebKit](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)). It needs an HTTPS origin. The push service (Apple, Google or Mozilla) sees only the payload, and the payload can be encrypted end to end under the Web Push encryption standard.

## Patterns and lessons for TBD

### Transports that recur

- **The laptop always dials out.** Happy (Socket.IO), Remote Control (HTTPS polling), `omnarad`, HAPI (tunwg), Telegram (`getUpdates`), Slack (Socket Mode), Discord (Gateway) and ntfy (stream subscribe) all connect outbound from the laptop. Nothing that worked across NAT opened an inbound port, except through a tunnel product.
- **Serving a local page moves the problem rather than solving it.** VibeTunnel and CloudCLI push reachability onto Tailscale, ngrok or Cloudflare, and every one of those that terminates TLS can see the stream.
- **A relay can store, or only forward.** Happy and Happier store encrypted history on the relay. HAPI's relay forwards opaque WireGuard and TLS packets and keeps nothing. A per-user Cloudflare Worker could follow either model. Forward-only makes the Worker simpler and keeps the history on the laptop, but the phone sees nothing while the laptop sleeps.

### Pairing patterns

- **A QR code carries a public key.** Happy and HAPI's companion app do this. Remote Control and Codex use QR codes too, but there the code is just a link, and trust comes from the shared account. The QR code is an out-of-band channel, so the relay cannot swap keys.
- **Chat bots pair with a code.** The user messages the bot, receives a short code, and approves it in the terminal. The sender ID then joins an allowlist ([channels docs](https://code.claude.com/docs/en/channels)).
- **A one-time token is pasted into an installer.** Omnara's machine token works this way.

### Security mistakes to avoid

- **Treating a value shown on screen as a credential.** Happy releases a non-expiring account token to anyone who presents the public key from the QR code. The fix is to make the poller prove it holds the private key, for example by answering a server nonce, and to delete the pairing record after one use.
- **Auto-approving prompts after remote input.** Claude-Code-Remote picks "Yes, and don't ask again" for the user. A remote surface must answer only the prompt the user saw, and only with the choice the user tapped.
- **Screen-scraping the TUI.** Omnara's PTY wrapper scanned for "Do you want", and the project shut down because Claude Code kept changing. TBD's rule against TUI scraping matches this evidence. TBD should use the transcript JSONL, hooks and the mod API.
- **Unsafe defaults that are one flag away from the internet.** Examples are `--no-auth --ngrok`, plain HTTP on `0.0.0.0`, and first-visitor registration. The safe path should be the default, with no "quick share" shortcut around auth.
- **Giving the phone a shell.** Happy exposes `bash`, `readFile` and `writeFile` RPCs. TBD's verb set should stay narrow: read a transcript and status, send a message, answer a prompt by request ID, and interrupt.
- **Plaintext in pushes.** Happy sends folder names and summaries through Expo, Apple and Google. A push should carry nothing, an opaque ID (ntfy's poll request), or an encrypted envelope (HAPI's `pushKey`).
- **Forgetting who else reads the chat.** Every chat-bot bridge copies the transcript into Telegram, Slack or Discord. With Slack in an employer's workspace, that copy belongs to the employer. Anthropic's docs state a second risk directly: "Anyone who can reply through the channel can approve or deny tool use in your session."

### Ideas worth copying

- **Happy's key hierarchy.** The master secret lives only on phones. A laptop gets just the content public key, and each session gets its own data key, wrapped to that public key. A stolen laptop exposes only its own sessions.
- **Responses keyed by request ID.** Happy matches a permission answer to its pending request and drops unknown IDs. The Telegram plugin puts `perm:allow:<id>` in a 64-byte callback. Both make answers idempotent, so a duplicate or stale tap cannot approve the wrong prompt.
- **Presence-aware push.** Remote Control skips pushes while the user types at the terminal and honours a presence file. Happy's server suppresses pushes while the desktop is active. TBD already knows which tab is focused.
- **The publisher runs the push relay, which needs no credentials.** Only the app's publisher holds APNs keys, so self-hosted servers send through the publisher's relay (Happy's Worker, ntfy upstream, `push.hapi.run`). If TBD ever ships an iOS app, that relay is unavoidable. Making it content-blind keeps it cheap to trust.
- **One poller per bot token.** If TBD offers a Telegram bridge, the daemon should own the single `getUpdates` loop and route updates to sessions. It should never start a poller per session.
- **First-party paths for users who qualify.** For Claude sessions on a subscription login, Remote Control already gives transcript, prompt answering, interrupt and push with no relay at all. It covers only Claude, though: not Codex CLI, API keys, Bedrock or LLM gateways. TBD's own path is still needed for everyone else and for TBD-level status. See [vendor-remote-control.md](vendor-remote-control.md).
