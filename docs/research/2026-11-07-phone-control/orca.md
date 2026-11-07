# Orca (stablyai/orca): phone control research

Orca is an open-source (MIT) desktop "agent development environment" that runs coding agents in parallel git worktrees. It ships a native iOS and Android companion app (beta). The phone reaches the desktop through a hosted relay that both sides dial out to, through a direct LAN or Tailscale address, or both. Relay pairing needs an Orca account sign-in. Traffic over the relay is wrapped in an application-layer end-to-end encryption scheme (X25519, HKDF, NaCl secretbox) with per-device signing keys. The relay server code is public under MIT, but the production deployment config is private and the hosted service is the supported path. Self-hosting the relay is not documented. accessed 2026-11-07.

Source revision read: `5bd03f75f506152da30fd5beed94fb5e5b40bee8` (shallow clone of `main`). Permalinks below use that SHA.

## Which "Orca"

Several unrelated GitHub projects share the name (forks and look-alikes such as `D1DX/orca` and `zaridan/orca` appear in search). The agent and worktree manager is [stablyai/orca](https://github.com/stablyai/orca), site [onorca.dev](https://www.onorca.dev). This report covers only that one. Star counts quoted by aggregators disagree, so none are used here.

## Surfaces

- **Native apps** – iOS (App Store) and Android (APK) React Native app, listed as beta. See the [mobile docs](https://www.onorca.dev/docs/mobile) and [README](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/README.md). Source: [`mobile/`](https://github.com/stablyai/orca/tree/5bd03f75f506152da30fd5beed94fb5e5b40bee8/mobile).
- **Web client** – the desktop tree has a browser client with the same E2EE code (`src/renderer/src/web/web-e2ee.ts`, `web-runtime-client.ts`) and a bundled mobile web bundle (`src/main/runtime/bundled-mobile-web-bundle.ts`). Its user-facing role is unverified.
- **No chat bot or PWA found.**

## Transport

- **Relay (preferred)** – "Phones and desktops never talk to each other directly: each opens an outbound WebSocket to a relay cell, the relay pairs the two sessions, and it splices frames between them." A director assigns hosts to regional cells. Source: [`cloud/README.md`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/cloud/README.md). The docs say it needs only outbound port 443 and no port forwarding. Hosts are `relay.onorca.dev` and `*.relay.onorca.dev` ([mobile docs, Firewalls](https://www.onorca.dev/docs/mobile)).
- **LAN / Tailscale (optional fast path)** – the desktop runs a WebSocket RPC server on port 6768 ([`mobile/README.md`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/mobile/README.md)). A saved host's address can be edited, for example to switch from home LAN to Tailscale, without re-pairing. The code has a Tailscale hint helper (`src/shared/remote-runtime/remote-runtime-tailscale-hint.ts`).
- **Region placement** – the relay moves a host between regions by measured latency, and keeps open connections alive during moves ([plan](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/docs/relay-region-correction/RELAY-REGION-CORRECTION-PLAN.md)). This is heavy operational machinery that a small project would not need.
- **Background** – the mobile app suspends its connection 30 seconds after it leaves the foreground (same plan, "For mobile"). Push covers the gap.

## Pairing

- The desktop shows a one-time pairing code (or a deep link). The phone pastes it. Codes expire after a few minutes. Source: [mobile docs, Pairing](https://www.onorca.dev/docs/mobile). A QR code is described in the dev README; the user docs mention code entry and deep link.
- A relay pairing offer is a versioned object carrying the director URL, cell URL, assignment epoch, relay host ID, an invite token and the desktop public key, with an invite lifetime capped at 10 minutes. Source: [`mobile-relay-pairing-offer.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/src/shared/remote-runtime/pairing/mobile-relay-pairing-offer.ts).
- Pairing mints a per-phone device token. Relay pairing requires desktop and phone to be signed into the same Orca account ([mobile docs, Troubleshooting](https://www.onorca.dev/docs/mobile)).

## Auth and encryption

- **E2EE over the relay** – the handshake carries a `transport: 'direct' | 'relay'` field, so the same encrypted session runs over both paths. The client sends `e2ee_hello` with an ephemeral X25519 public key and a nonce. The desktop answers `e2ee_ready`. Source: [`mobile-e2ee-v2-contract.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/src/shared/remote-runtime/e2ee/mobile-e2ee-v2-contract.ts).
- **Key schedule** – HKDF-SHA256 over the shared secret, salted with both nonces and bound to a transcript hash. It yields one key per direction plus a session ID. Source: [`paired-e2ee-v2-key-schedule.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/src/shared/remote-runtime/e2ee/paired-e2ee-v2-key-schedule.ts). Frames are sealed with NaCl secretbox (`tweetnacl`; native overrides on the phone because Hermes JS is slow) per [`paired-e2ee-primitives.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/src/shared/remote-runtime/e2ee/paired-e2ee-primitives.ts).
- **Device keys** – each device signs the handshake transcript with an Ed25519 key (`tweetnacl` signatures), with a domain-separated message `orca-device-proof/v1 \0 purpose \0 transcriptHash` for purposes `auth`, `redeem`, `register`. Source: [`device-key-proof.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/src/shared/remote-runtime/pairing/device-key-proof.ts).
- **Relay sees ciphertext** – inferred, not stated in a doc. The relay splices frames, and the E2EE handshake terminates at the phone and the desktop. I found no relay code that decrypts payloads. I did not audit the relay for metadata leakage. Treat "relay sees only ciphertext" as likely but unverified.
- **Relay auth** – the relay validates account JWTs against a JWKS issuer (`ORCA_RELAY_AUTH_ISSUER`, `ORCA_RELAY_JWKS_URL` in [`relay.blackbox.test.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/cloud/apps/relay/src/relay.blackbox.test.ts)).
- **Revocation** – the desktop exposes `mobile:revokeDevice` and `mobile:revokeRuntimeAccess` ([`src/main/ipc/mobile.ts`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/src/main/ipc/mobile.ts)). The phone shows "pairing invalid" after the desktop clears paired devices and offers re-pair or remove ([docs](https://www.onorca.dev/docs/mobile)). The desktop's long-term E2EE key is kept on disk, and a comment in `e2ee-keypair.ts` warns that regenerating it would unpair every device.
- **Security review** – a [2026-10-21 relay security review](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/cloud/docs/relay-security-2026-10-21.md) covers scans and advisories. I did not read it in depth.

## What the phone shows and does

From the [mobile docs](https://www.onorca.dev/docs/mobile):

- **Status** – every worktree with its agent and a status of working, done or waiting on input, across several hosts.
- **Transcript** – a "Chat UI" for Claude, Codex and others: transcript, composer, permission and question prompts, image attachments, `@` file mentions, slash commands, model picker. The default is the raw terminal until the user opts in. The terminal scrollback view also exists.
- **Send a message** – yes, including photo, file and dictation.
- **Approve and answer** – the Chat UI shows permission and question prompts. The page does not describe a dedicated approve control or an interrupt button. Interrupt is unverified.
- **Start sessions** – yes: create a workspace from a task source and start an agent, on a chosen host.
- **Other** – quick commands, file tree, source control (stage, commit), browser view, account switcher with rate-limit state.
- **Push** – a separate push gateway holds the APNs key and sends through APNs and FCM. The desktop authenticates to it with its X25519 key, registers each paired phone's push token, and asks it to push. Logging is counters only, but notification titles and bodies do pass through the gateway ([`cloud/README.md`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/cloud/README.md), "Mobile push gateway"). Whether titles are redacted is unverified.

## Open source, self-hosting, cost, accounts

- **License** – MIT, copyright Lovecast Inc ([`LICENSE`](https://github.com/stablyai/orca/blob/5bd03f75f506152da30fd5beed94fb5e5b40bee8/LICENSE)).
- **Relay source** – public in [`cloud/`](https://github.com/stablyai/orca/tree/5bd03f75f506152da30fd5beed94fb5e5b40bee8/cloud): relay, wire contract and push gateway. It runs on PostgreSQL in production and SQLite for dev. Only `ORCA_RELAY_ASSIGNMENT_SIGNING_KEY` is required locally. Production Terraform, runbooks and deploy workflows live in a private repo, `stablyai/orca-cloud`.
- **Self-hosting** – no documented path to point the apps at your own relay. The pairing offer carries relay URLs, so it may be possible, but the sign-in (JWKS issuer) is tied to Orca's login. Unverified. The documented self-host story is a remote "Orca server" for agents, not a relay.
- **Cost** – the docs state no price. Orca is described as free and open source. Agents run on the user's own subscriptions.
- **Account** – required for Relay. Not required for direct LAN or Tailscale.

## Lessons for TBD

What they got right:

- **Outbound-only dials** from both sides remove NAT and port-forwarding setup.
- **E2EE inside the transport**, with the same handshake for direct and relay paths, so the relay is not trusted with content.
- **Per-device signing keys**, bound to the handshake transcript with a purpose label, give revocation per device.
- **Short-lived, single-use invites** (10 minute cap).
- **Direct address as an optional fast path** beside the relay, editable without re-pairing. Fits Tailscale users well.
- **Versioned protocol with a hard block** on mismatched client and desktop, so old apps fail clearly.
- **Chat UI as a transcript view** over the desktop-owned session. Same scope TBD wants.
- **Push through a gateway** that only the desktop can call, so phones hold no cloud credential.

What looks weak or costly:

- **Hosted dependence and account** – relay and sign-in run on the maintainer's domain. That is the exact coupling TBD wants to avoid.
- **Large surface** – directors, cells, region migration, a push gateway, a fence broker. Heavy for a volunteer project.
- **Hand-rolled E2EE** (custom handshake, secretbox framing, JS crypto on Hermes). It is documented in code and tested, but it needs expert review. A Noise-style or established protocol would be easier to audit.
- **Long-lived desktop key on disk**, with a warning that regeneration unpairs all devices.
- **Interrupt and explicit approve** are not documented on the phone.
- **Push content** passes through the gateway. TBD would need a plan for notification text.
- **Unclear self-host story** for the relay.

## Unverified

- Whether the relay can read any payload or only metadata.
- Web client's user-facing role.
- Interrupt support on the phone.
- Whether a third party can run the relay and have the apps use it.
- Pricing beyond "free and open source".
- Push payload redaction.
