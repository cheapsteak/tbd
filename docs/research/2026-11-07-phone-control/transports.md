# Phone control: self-hosted transport options

**Status:** Research only. Nothing built.
**Sources accessed:** 2026-11-07. Every price and limit below is as published
on that date. Placeholder names use `acme`.

## Summary

The best default transport for TBD phone control is a Cloudflare Worker with one
SQLite-backed Durable Object, deployed by each user to their own free account.
The laptop and the phone each dial out to it over a WebSocket, so NAT never
matters. The WebSocket Hibernation API means an idle pairing costs nothing. At
a few KB per turn, a busy day uses under 1% of the Workers Free plan. The free
`workers.dev` subdomain removes any need for a domain, and a "Deploy to
Cloudflare" button can install the relay from a public repository without a
CLI. The relay should be a dumb pipe that is never trusted. The laptop and the
phone run an end-to-end encrypted session on top of it, built only from
CryptoKit and Web Crypto. X25519, HKDF-SHA-256 and AES-GCM exist on both sides
from iOS 17 and Safari 17. Pairing uses a QR code that carries the relay URL, a
room ID, the laptop's public key and a one-time 256-bit secret, and the
handshake should follow Noise `IKpsk2` (the pattern WireGuard uses) rather than
an invented one. Tailscale Serve is the strongest second option. It has no
public endpoint, it is WireGuard end to end, and it roams cleanly, but it makes
the phone run the Tailscale VPN. Push notifications need no relay at all. The
laptop can send standard Web Push straight to Apple's push service, and that
needs no Apple Developer account. Cloudflare Tunnel needs a domain and
terminates TLS at Cloudflare. WebRTC still needs a meeting point, needs a relay
as a fallback, and adds a heavy native library. CloudKit and APNs need a paid
Apple Developer account and signed builds, which TBD does not have.

## What the channel must do

- **Traffic** – text messages and transcript events. A few KB per turn, bursty,
  mostly idle.
- **Reachability** – both ends sit behind NAT. The phone changes networks often.
- **Threat** – whoever can put a frame into the channel can make an agent run
  commands on the laptop. So the relay must be treated as hostile. Every frame
  needs authentication, not just encryption.
- **Hosting** – TBD is multi-tenant open source. The maintainer cannot run a
  shared backend. Each user may set up their own piece.

## Facts that hold for every option

### The laptop must be awake

- **No transport survives sleep.** TBD can hold an IOKit power assertion while
  phone control is on. `kIOPMAssertionTypePreventUserIdleSystemSleep` stops
  idle sleep, but Apple notes that "the system may still sleep for lid close,
  Apple menu, low battery, or other sleep reasons"
  ([Apple](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)).
  A closed lid on battery ends every option below.

### The phone app is suspended in the background

- **Sockets die soon after the user leaves the app.** Apple's networking
  engineer puts it this way: "iOS will usually suspend the app shortly after
  moving it to the background"
  ([Apple Developer Forums](https://developer.apple.com/forums/thread/716118)).
  This applies to native apps and Home Screen web apps alike.
- **Consequence** – the phone client must reconnect on `visibilitychange` and
  treat any old socket as dead. Only a push notification can reach a phone
  that is not in the foreground.

### Push: Web Push needs no Apple account

- **No membership** – WebKit states: "You do not need to be a member of the
  Apple Developer Program to use it"
  ([WebKit, Web Push for iOS](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)).
- **Platform floor** – iOS and iPadOS 16.4, and only for web apps saved to the
  Home Screen ([same post](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/);
  [MDN compat data for `PushManager`](https://github.com/mdn/browser-compat-data/blob/main/api/PushManager.json)).
  The permission request must come from a user tap.
- **Every push must show a notification.** "Violations of the
  `userVisibleOnly` promise will result in a push subscription being revoked"
  ([WebKit, Meet Web Push](https://webkit.org/blog/12945/meet-web-push/)). So
  there are no silent wake-ups.
- **Endpoint host** – WebKit tells servers to "allow URLs from any subdomain of
  push.apple.com" ([Meet Web Push](https://webkit.org/blog/12945/meet-web-push/)).
  The host `web.push.apple.com` is the one commonly seen in subscriptions.
  That exact host is **unverified** against an Apple page in this pass; the
  subscription's endpoint URL is authoritative anyway.
- **What Apple sees** – the payload is encrypted to the browser with ECDH
  P-256, HKDF and AES-128-GCM ([RFC 8291](https://www.rfc-editor.org/rfc/rfc8291)).
  The push service still sees timing, size, and which sender talks to which
  subscription. The sender signs a VAPID token
  ([RFC 8292](https://www.rfc-editor.org/rfc/rfc8292)).
- **The laptop can send pushes itself.** It already makes outbound HTTPS calls.
  CryptoKit has P-256 signing, P-256 key agreement, HKDF and AES-GCM, which is
  everything RFC 8291 and RFC 8292 need. No relay is involved, so this push
  path is the same for every transport below.
- **Native APNs is a different story.** It needs a paid Apple Developer
  Program membership (see section 5). The sender also needs the APNs key of the
  team that signed the app, and an open-source project cannot ship that key.
  ntfy shows the cost: a self-hosted ntfy server must forward "poll_request"
  messages to the main ntfy.sh server so that iOS instant notifications work
  ([ntfy config docs](https://docs.ntfy.sh/config/)).

### The phone client is probably a web app, and its origin is a trust root

- **HTTPS only** – Web Crypto is "available only in secure contexts (HTTPS)"
  ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto)).
  Service workers and Web Push have the same rule.
- **Whoever serves the JavaScript controls the keys.** End-to-end encryption
  protects against a relay that only forwards frames. It does not protect
  against the origin that serves the client code, because that origin can ship
  code that reads the keys. If the Worker serves the web app, the user's
  Cloudflare account joins the trust base. If the laptop serves it (the
  Tailscale option), the trust base is the laptop, which is trusted anyway.
- **Key storage** – a non-extractable `CryptoKey` can live in IndexedDB.
  Safari's seven-day storage cap does not hit Home Screen web apps the same
  way: "Web applications added to the home screen are not part of Safari and
  thus have their own counter of days of use," and WebKit does "not expect the
  first-party in such a web application to have its website data deleted"
  ([WebKit](https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/)).
  Re-pairing should still be cheap, because storage can be lost.

## 1. Cloudflare Workers + Durable Objects relay

### How it works

- **Shape** – the laptop and the phone each open `wss://` to
  `https://acme-relay.acme.workers.dev/<room>`. The Worker sends the request to
  the Durable Object named by the room ID. The object accepts both sockets and
  forwards each frame to the other side. Both ends dial out, so NAT does not
  matter.
- **Hibernation** – the object accepts sockets with `ctx.acceptWebSocket(ws)`
  instead of `ws.accept()`. It can then leave memory while clients stay
  connected. "Billable Duration (GB-s) charges do not accrue during
  hibernation." On wake-up, in-memory state is reset and the constructor runs
  again. Per-socket attachments of up to 16,384 bytes survive
  ([Cloudflare, WebSockets best practices](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)).
  One object can hold up to 32,768 hibernatable sockets
  ([DurableObjectState API](https://developers.cloudflare.com/durable-objects/api/state/)).
- **Only server sockets hibernate.** "Outgoing WebSockets do not hibernate"
  ([best practices](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)).
  That is fine here, because both ends dial in.
- **Keepalives cost nothing.** Protocol pings get automatic pongs and are not
  charged. `setWebSocketAutoResponse()` answers an application-level ping
  string without waking the object. Auto-responses use no wall-clock time and
  are not charged ([pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)).
  Browser JavaScript cannot send protocol pings, so the web app uses an
  application-level ping with an auto-response. The laptop's
  `URLSessionWebSocketTask` can send protocol pings.
- **Free plan access** – SQLite-backed Durable Objects have been on the Workers
  Free plan since 2025-04-07
  ([changelog](https://developers.cloudflare.com/changelog/2025-04-07-durable-objects-free-tier/)).
  The Free plan offers only the SQLite backend
  ([pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)).

### Limits and prices

| Item | Workers Free | Workers Paid |
|---|---|---|
| Worker requests | 100,000/day | 10M/month included, then $0.30/M |
| Worker CPU per invocation | 10 ms | 30 s default, up to 5 min |
| Durable Object requests | 100,000/day | 1M/month included, then $0.15/M |
| Durable Object duration | 13,000 GB-s/day | 400,000 GB-s/month included, then $12.50/M GB-s |
| SQLite rows read | 5M/day | 25B/month included, then $0.001/M |
| SQLite rows written | 100,000/day | 50M/month included, then $1.00/M |
| Stored data | 5 GB total | 5 GB-month included, then $0.20/GB-month |
| Received WebSocket message size | 32 MiB | 32 MiB |
| Monthly minimum | $0 | $5 |

Sources: [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
[Workers limits](https://developers.cloudflare.com/workers/platform/limits/),
[Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/),
[Durable Objects limits](https://developers.cloudflare.com/durable-objects/platform/limits/).

- **How WebSocket traffic counts** – opening a connection is one request.
  Outgoing messages are not charged. Incoming protocol pings are not charged.
  Incoming messages are billed at 20:1, so 100 incoming messages count as 5
  requests. Auto-responses are not charged
  ([pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)).
- **Duration billing** – duration is billed for the full 128 MB of each object,
  whatever it actually uses. Idle objects that can hibernate are not billed.
  Pending outbound I/O can keep an object in memory, billed, for up to 15
  minutes ([pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)).
  So the relay object should make no outbound calls.
- **Running out** – daily limits reset at 00:00 UTC. On the Free plan, an
  operation past its limit fails
  ([pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)).
  A Worker past 100,000 requests a day returns error 1027
  ([limits](https://developers.cloudflare.com/workers/platform/limits/)).

### Cost at TBD's traffic

- **Even with no hibernation, one object fits.** 0.125 GB × 86,400 s =
  10,800 GB-s a day, under the 13,000 GB-s free allowance. Two objects awake
  all day would not fit. With hibernation, an idle pairing bills nothing. (This
  is arithmetic on the published numbers.)
- **A busy day is about 1% of the request quota.** Assume 300 turns of 30
  frames each from the laptop: 9,000 incoming messages, billed as 450
  requests. Add 1,000 phone frames (50 requests) and 200 reconnects (200
  Durable Object requests plus 200 Worker requests). That totals about 900 of
  100,000. (These traffic numbers are assumptions, not measurements.)
- **Storage is zero** if the relay stores nothing. It should store nothing: the
  laptop holds the transcript and can resend from any point on reconnect.
- **Result** – $0 on the Free plan. A user already on Workers Paid pays nothing
  extra beyond the $5 minimum.
- **Abuse** – a stranger who learns the URL can spend the daily quota and
  take the relay down until 00:00 UTC. That is a denial of service, not a
  breach, because frames are end-to-end encrypted. The Worker should reject a
  malformed room ID before it touches a Durable Object, and the URL should
  stay out of public places. Whether rejected requests still count against the
  Worker quota is **unverified**; assume they do.

### How small the relay can be

A complete relay is about 30 lines. This sketch has not been run.

```ts
import { DurableObject } from "cloudflare:workers";

export class Room extends DurableObject {
  async fetch(req: Request): Promise<Response> {
    const role = new URL(req.url).searchParams.get("role");
    if (role !== "laptop" && role !== "phone") return new Response(null, { status: 400 });
    const [client, server] = Object.values(new WebSocketPair());
    for (const old of this.ctx.getWebSockets(role)) old.close(4000, "replaced");
    this.ctx.acceptWebSocket(server, [role]);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws: WebSocket, msg: string | ArrayBuffer) {
    const peer = this.ctx.getTags(ws)[0] === "laptop" ? "phone" : "laptop";
    for (const p of this.ctx.getWebSockets(peer)) p.send(msg);
  }
}

export default {
  async fetch(req: Request, env: { ROOM: DurableObjectNamespace }) {
    const room = new URL(req.url).pathname.slice(1);
    if (!/^[A-Za-z0-9_-]{43}$/.test(room)) return new Response(null, { status: 404 });
    return env.ROOM.get(env.ROOM.idFromName(room)).fetch(req);
  },
};
```

- **What it does** – one laptop and one phone per room. A new connection
  replaces an old one of the same role. The room ID is 32 random bytes from
  the QR code. Nothing is stored and nothing is decrypted.
- **API names** – `acceptWebSocket`, `getWebSockets`, `getTags` and
  `setWebSocketAutoResponse` are all documented on the
  [DurableObjectState page](https://developers.cloudflare.com/durable-objects/api/state/).
  The binding and SQLite storage declaration go in the Wrangler config
  ([get started](https://developers.cloudflare.com/durable-objects/get-started/)).
- **Presence** – a few more lines can tell each side when the other connects
  or leaves. The laptop can then stream only while the phone is present.

### Setup for a non-expert

- **Accounts** – a Cloudflare account. Whether sign-up asks for a card is not
  stated on any Cloudflare page fetched for this report. It is widely reported
  that the Free plan needs no card; treat that as **unverified**. Workers Paid
  needs a payment method.
- **Path A, the Deploy button** – a README button links to
  `https://deploy.workers.cloudflare.com/?url=<repo URL>`. Cloudflare "clones
  your source repository into the user's GitHub/GitLab account," builds it with
  Workers Builds, and provisions Durable Objects automatically
  ([Deploy buttons](https://developers.cloudflare.com/workers/platform/deploy-buttons/)).
  So the user also needs a GitHub or GitLab account. The source repository
  must be public. "Cloudflare does not fully support monorepos," so the relay
  must sit fully isolated in its own subdirectory, and the button can point at
  that subdirectory (same page).
- **Path B, the CLI** – install Node.js, run
  `npm create cloudflare@latest -- tbd-relay`, then `npx wrangler deploy`.
  Wrangler opens a browser to log in, and prompts for a `workers.dev`
  subdomain if the account has none
  ([get started](https://developers.cloudflare.com/workers/get-started/guide/)).
- **Path C, TBD deploys it** – the Workers Script Upload API takes a multipart
  upload whose metadata names the main module, the bindings (including
  `durable_object_namespace`) and the Durable Object migrations
  ([multipart upload metadata](https://developers.cloudflare.com/workers/configuration/multipart-upload-metadata/)).
  TBD could upload the relay with an API token the user creates, with no Node.js
  and no Git account. This is feasible on paper and **untested**. Whether a
  brand-new account needs a separate step to claim its `workers.dev` subdomain
  through the API is **unverified**.
- **Domain** – none needed. Each Worker gets
  `<worker>.<subdomain>.workers.dev`, which "is treated as a Free website" for
  "personal or hobby projects." Cloudflare recommends a route or custom domain
  for production ([workers.dev](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/)).
- **User-Agent gotcha** – Browser Integrity Check runs on every `workers.dev`
  request and cannot be turned off there. Some clients with a default library
  User-Agent get error 1010 before the Worker runs
  ([workers.dev](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/)).
  The laptop client should send a descriptive User-Agent.
- **Last steps** – paste the relay URL into TBD, scan the QR code on the phone,
  add the web app to the Home Screen, and allow notifications.

### Latency

- **Placement** – "a Durable Object is instantiated in a data center close to
  where the initial `get()` request is made," and objects "do not currently
  change locations after they are created"
  ([data location](https://developers.cloudflare.com/durable-objects/reference/data-location/)).
  If the laptop opens the room first, the object sits near the laptop.
- **Path** – phone, nearest Cloudflare location, the object, the laptop's
  nearest location, laptop. Within one region this should add tens of
  milliseconds. That figure is an estimate, **not measured**. Location hints
  exist for users who travel.

### What the operator can see

- **Cloudflare** – the Worker runs on Cloudflare, so Cloudflare sees every
  frame as the Worker sees it. With end-to-end encryption that is ciphertext
  plus metadata: both IP addresses, connection times, frame sizes and timing,
  the room ID and User-Agents. Without it, Cloudflare and anyone holding the
  user's Cloudflare credentials could read every frame and inject commands.
- **The user's Cloudflare account becomes a control point.** Anyone with access
  to it can change the Worker. With end-to-end encryption and a client that the
  Worker does not serve, a changed Worker can only drop, delay or count frames.

### Push

- **From the laptop** – Web Push straight to Apple, as described above.
- **From the relay (optional)** – the Worker could push "laptop went offline"
  when the laptop socket closes. That puts the VAPID private key in the Worker.
  It is optional and not needed for a first version.

### Failure modes

- **Laptop sleep** – the laptop socket closes. The relay can tell the phone
  the laptop is offline.
- **Phone in the background** – the socket dies within seconds. The client
  reconnects on return.
- **Idle disconnect** – Cloudflare will "close a WebSocket connection when no
  data is transmitted in either direction" for an unstated period, and
  recommends a keepalive ([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).
  Auto-response pings keep the socket open for free.
- **Network change** – a phone moving from Wi-Fi to cellular loses its TCP
  connection. The client reconnects and reruns the cheap handshake.
- **Cloudflare restarts** – server restarts during code releases terminate
  WebSockets ([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).
  Runtime updates give existing connections up to 20 minutes
  ([limits](https://developers.cloudflare.com/workers/platform/limits/)). A
  forced code update to the relay disconnects hibernated sockets
  ([best practices](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)).
- **Quota exhaustion** – the relay fails until 00:00 UTC.

## 2. Cloudflare Tunnel

### Quick tunnels

- **What they are** – `cloudflared` creates a temporary `trycloudflare.com` URL
  for a local service. "You do not need a Cloudflare account or domain"
  ([TryCloudflare](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)).
- **Limits** – "Quick Tunnels are for testing and development." They have "no
  uptime guarantee," allow 200 in-flight requests, and do not support
  Server-Sent Events. The hostname changes on every run and "stops working when
  you stop the `cloudflared` process" (same page). WebSocket support is not
  stated there and is **unverified**.
- **Fit for TBD** – every daemon restart changes the URL, which breaks the
  pairing unless a second channel carries the new one. Good for a demo, not
  for the product.

### Named tunnels

- **Prerequisites** – a Cloudflare account and "A domain on Cloudflare," which
  is "required to publish applications"
  ([Tunnel setup](https://developers.cloudflare.com/tunnel/setup/)). A domain
  costs a yearly registration fee (not priced here).
- **Install** – `brew install cloudflared`
  ([downloads](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)),
  then install it as a service with a tunnel token. The connector is
  outbound-only and needs egress on port 7844
  ([overview](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/),
  [setup](https://developers.cloudflare.com/tunnel/setup/)).
- **Cloudflare Access** – the Zero Trust Free plan covers "Teams under 50
  users" at $0 ([plans](https://www.cloudflare.com/plans/sase-zero-trust.md)).
  Onboarding asks for payment details even on the free plan: "this step is
  still needed but you will not be charged"
  ([Zero Trust setup](https://developers.cloudflare.com/cloudflare-one/setup/)).
  Email one-time PINs expire after 10 minutes
  ([one-time PIN](https://developers.cloudflare.com/cloudflare-one/identity/one-time-pin/)).
  Access suits a browser client, which holds the Access cookie. Whether
  creating a tunnel purely from the CLI avoids Zero Trust onboarding is
  **unverified**.
- **What Cloudflare sees** – Cloudflare handles the visitor-to-Cloudflare and
  Cloudflare-to-origin legs as two separate connections
  ([SSL modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)),
  so it reads plaintext HTTP at its edge. End-to-end encryption is still needed
  to keep content from Cloudflare.
- **Exposure** – the laptop now runs an HTTP server that the internet can reach
  through the tunnel. Access in front narrows that. The end-to-end handshake
  remains the real gate.
- **Cost** – the tunnel is free. The domain is not.
- **Latency** – phone, Cloudflare, the connector's location, laptop. Similar
  to the Worker relay.
- **Push** – Web Push from the laptop.
- **Failure modes** – laptop sleep takes the connector down, and the phone gets
  an error from Cloudflare. Idle WebSocket timeouts and release restarts apply
  as in section 1. How fast `cloudflared` recovers after a laptop network
  change is **unverified**.
- **Verdict** – more setup than the Worker (a domain, plus Zero Trust
  onboarding with payment details) and no gain for this traffic.

## 3. Tailscale

### Serve: tailnet-only, no public exposure

- **How it works** – Serve shares a local service with other devices on the
  user's tailnet. It is not public, and it "requires you to enable HTTPS
  certificates in your tailnet" ([Serve](https://tailscale.com/kb/1312/serve)).
  The phone reaches the laptop at `https://laptop.acme-tailnet.ts.net` with no
  public endpoint at all.
- **Encryption** – "Tailscale node connections are end-to-end encrypted," and
  the private key "never, ever leaves its node." The coordination server
  "just exchanges a few tiny encryption keys and sets policies" and carries
  "virtually no traffic"
  ([How Tailscale works](https://tailscale.com/blog/how-tailscale-works)).
  When a direct path fails, a DERP relay "blindly forwards already-encrypted
  traffic from one device to another"
  ([DERP](https://tailscale.com/kb/1232/derp-servers)).
- **Control-plane risk** – a malicious or compromised coordination server
  could add nodes to the tailnet. Tailnet Lock requires new node keys to be
  signed by a trusted key, and it is available on the Personal plan
  ([Tailnet Lock](https://tailscale.com/kb/1226/tailnet-lock)).
- **Certificate Transparency** – HTTPS certificates come from Let's Encrypt,
  and machine names land in the public CT log. Tailscale warns: "Do not enable
  the HTTPS feature if any of your machine names contain sensitive
  information." A randomized tailnet DNS name is available
  ([Enabling HTTPS](https://tailscale.com/kb/1153/enabling-https)).
- **Roaming** – WireGuard peers "send encrypted data to the most recent IP
  endpoint for which they authentically decrypted data"
  ([WireGuard](https://www.wireguard.com/)). A phone moving between networks
  keeps its tailnet address, and the tunnel follows. Whether a WebSocket inside
  the tunnel survives a switch is **unverified**; plan for a reconnect anyway.
- **Plan** – Personal is $0, "Up to 6 users," "Unlimited user devices"
  ([pricing](https://tailscale.com/pricing)). No card requirement is stated.
- **Phone requirement** – the Tailscale iOS app, iOS 15 or later, approval of
  a VPN configuration, and sign-up through a supported SSO identity provider
  ([Install on iOS](https://tailscale.com/kb/1020/install-ios)). iOS runs only
  one VPN at a time, so Tailscale cannot stay on next to a work VPN
  ([Tailscale FAQ](https://tailscale.com/kb/1105/other-vpns)).
- **Mac requirement** – one of three macOS variants. The Standalone variant is
  the recommended one, and the App Store and Standalone variants must not be
  installed together ([macOS variants](https://tailscale.com/kb/1065/macos-variants)).

**Setup for a non-expert:**

1. Create a Tailscale account with an SSO provider.
2. Install Tailscale on the Mac and sign in.
3. Install the Tailscale iOS app, approve the VPN prompt, sign in to the same
   tailnet.
4. Enable MagicDNS and HTTPS certificates in the admin console.
5. Let TBD run `tailscale serve` for its phone endpoint.
6. Open the URL on the phone, add it to the Home Screen, and pair with the QR
   code.

- **Cost** – $0.
- **Latency** – the lowest of any option when a direct path exists. DERP adds a
  relay hop when it does not.
- **What the operator sees** – node metadata (names, keys, endpoint addresses),
  not traffic.
- **Push** – the web app, served over HTTPS from the `ts.net` name, can
  subscribe to Web Push, and the laptop sends pushes directly. A notification
  arrives even with the VPN off. Opening the app then needs the VPN on.
- **Failure modes** – laptop sleep. The phone VPN being off. Another VPN taking
  the phone's single VPN slot. The user being signed out of Tailscale.

### Funnel: public, TLS ends on the laptop

- **How it works** – Funnel gives a local service a public URL under the
  tailnet's `ts.net` name, through Funnel relay servers and a TCP proxy. "The
  Funnel relay server cannot decrypt data sent over this proxy." The device
  "terminates the TLS connection" itself
  ([Funnel](https://tailscale.com/kb/1223/funnel)).
- **Limits** – ports 443, 8443 and 10000 only. Traffic "is subject to
  non-configurable bandwidth limits." Funnel needs MagicDNS, HTTPS
  certificates and a `funnel` node attribute in the policy file. It is
  available on all plans and is in beta (same page).
- **macOS support is unclear.** The Funnel docs say both "To use Funnel on
  macOS, you must use one of the open source variants" and "You can only use
  Funnel to share ports if you installed Tailscale for macOS from the App Store
  or as a Standalone variant system extension"
  ([Funnel docs](https://tailscale.com/docs/features/tailscale-funnel.md)).
  The variants table lists Funnel as unsupported on App Store and Standalone
  ([macOS variants](https://tailscale.com/kb/1065/macos-variants)). Which is
  current is **unverified**.
- **Fit for TBD** – the phone needs no VPN, and Tailscale cannot read the
  traffic. But the laptop endpoint is on the public internet, so the
  end-to-end handshake is the only gate. Beta status and the doc conflict make
  it a fallback, not a default.

### Keep the end-to-end layer on Tailscale too

- **Defense in depth** – any device in the tailnet can reach a Serve endpoint
  unless ACLs restrict it.
- **One protocol** – the same encrypted session can run relayed or direct. The
  Orca report in this folder ([orca.md](orca.md)) describes exactly that: one
  E2EE handshake with a `transport: 'direct' | 'relay'` field.

## 4. WebRTC data channels

- **Signaling still needs a meeting point.** Both peers must swap offers and
  ICE candidates through something they can both reach. That is the Worker
  relay again, so WebRTC adds to a relay rather than replacing it.
- **Direct paths fail often enough to need TURN.** Public numbers are old and
  mostly from vendors. Commonly cited figures say 10 to 25% of sessions need a
  TURN relay; none of those figures was traced to a primary dataset here, so
  treat them as **unverified**. One engineer's measurement of about 100,000
  calls found 1.9% failed outright, and 60% of failures had no TURN candidate
  on one or both sides
  ([a WebRTC engineer's post](https://medium.com/@fippo/67b185e49765)). A phone on
  cellular behind carrier NAT is a hard case. No figure was found for that
  pairing.
- **TURN is a relay too.** Cloudflare Realtime TURN costs $0.05 per GB outbound
  unless used with its SFU
  ([Cloudflare Realtime TURN](https://developers.cloudflare.com/realtime/turn/)).
  Metered's Open Relay offers 20 GB of free TURN a month
  ([Metered](https://www.metered.ca/tools/openrelay/)). Google's public STUN
  servers are widely used but have no published terms that this pass could
  find (**unverified**).
- **Security still needs the same pairing crypto.** DTLS encrypts the data
  channel, but peers authenticate DTLS by fingerprints carried in the
  signaling. A hostile signaling relay can swap them and sit in the middle. So
  signaling must be authenticated end to end, which is the same work as the
  E2E layer in section 7.
- **macOS has no system WebRTC for native code.** Options are the unofficial
  `stasel/WebRTC` binaries of Google's library, built for macOS 12+ and iOS
  15+ with Swift Package Manager support
  ([stasel/WebRTC](https://github.com/stasel/WebRTC)), or `libdatachannel`, a
  C++ library under MPL 2.0 that needs a TLS backend
  ([libdatachannel](https://github.com/paullouisageneau/libdatachannel)).
  Either is a large new dependency. Hosting WebRTC in a hidden `WKWebView`
  might work but is **unverified**, and the daemon has no window.
- **Phone side** – Safari has supported `RTCDataChannel` since Safari 11
  ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/api/RTCDataChannel.json)).
  Suspension in the background kills it like any socket. A network change
  needs an ICE restart.
- **Cost, latency, visibility** – free unless TURN is used. Lowest latency on
  a direct path. TURN and the signaling relay see ciphertext and metadata.
- **Verdict** – the payload is a few KB per turn, so the latency gain does not
  matter. The dependency and the moving parts are large. Not recommended.

## 5. Apple: CloudKit, APNs and Web Push

- **CloudKit and APNs need the paid program.** Apple's capability tables tick
  "iCloud: CloudKit" and "Push notifications" for the Apple Developer Program
  and Developer ID on macOS, and for the Apple Developer Program and Enterprise
  Program on iOS. The free "Apple Developer" column has no tick for either
  ([macOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-macos/),
  [iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)).
  The program costs $99 a year ([Apple Developer Program](https://developer.apple.com/programs/)).
- **An ad-hoc-signed app cannot use CloudKit.** "Every entitlement claimed by
  the app must be in the profile's allowlist." Only a short list of
  unrestricted entitlements, such as `get-task-allow` and application groups,
  work without a provisioning profile
  ([TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)).
  The iCloud entitlement is not on that list, and an ad-hoc signature has no
  profile. (This is an inference from TN3125 and the capability tables, not a
  test.)
- **The free tier does not help.** A free personal team gets 3 devices, 3 apps
  per device and must reprovision every 7 days
  ([compare memberships](https://developer.apple.com/support/compare-memberships/)),
  and it gets no CloudKit or push anyway.
- **Fit for TBD** – TBD is built from source on each Mac and, at the time of
  writing, carries no Developer ID signature or provisioning profile. CloudKit
  would need every user to pay $99 a year, or the maintainer to ship signed
  builds of both apps. If the maintainer ever does ship signed apps, note that
  CloudKit's private database lives in each user's iCloud, so it would not be a
  backend the maintainer hosts.
- **APNs** – the same membership rule, plus the key problem from the push
  section above.
- **Web Push** – confirmed: no Apple account, iOS 16.4+, Home Screen web apps
  only ([WebKit](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)).

## 6. Other relays a user could bring

- **ntfy.sh** – topics work over JSON stream, SSE or WebSocket
  ([subscribe API](https://docs.ntfy.sh/subscribe/api/)). Messages over 4,096
  bytes become attachments, messages are cached 12 hours, and "the topic is
  essentially a password." The free ntfy.sh daily message limit is 250
  ([publish docs](https://docs.ntfy.sh/publish/)). Supporter costs $5 a month
  for 2,500 messages a day ([ntfy.sh](https://ntfy.sh/)). The free cap is too
  low to stream transcripts. It is fine for notifications.
- **Public MQTT broker** – HiveMQ's public broker "is public and shared, so it
  is not intended for private or production data," with no uptime promise
  ([HiveMQ](https://www.hivemq.com/mqtt/public-mqtt-broker/)). With end-to-end
  encryption it would carry frames, but with no guarantees.
- **Firebase Realtime Database** – the Spark plan allows 100 simultaneous
  connections, 1 GB stored and 10 GB downloaded a month, with "No payment
  method needed" ([Firebase pricing](https://firebase.google.com/pricing)). It
  works, but adds a Google account and SDK for no gain over a Worker.
- **Supabase Realtime** – the Free plan allows 200 concurrent connections and 2
  million messages a month, but "Free projects are paused after 1 week of
  inactivity" ([Supabase pricing](https://supabase.com/pricing)). That is a poor
  fit for a mostly idle channel.
- **ngrok** – the Free plan gives one assigned dev domain, 1 GB of data
  transfer, 20,000 HTTP requests a month, and shows an interstitial page on
  browser traffic. A TCP address needs a verified card. Paid plans start at $10
  a month ([ngrok pricing](https://ngrok.com/pricing)). The interstitial would
  get in the way of a web app; whether a client can skip it is **unverified**.
  TLS terminates at ngrok by default (**unverified** in this pass).
- **Deno Deploy** – the Free plan gives 1 million requests and 20 GiB of egress
  a month ([Deno Deploy pricing](https://deno.com/deploy/pricing)). The same
  relay could be ported to it. WebSocket limits and any equivalent of
  hibernation are **unverified**.
- **A small VPS** – DigitalOcean's cheapest Droplet is $4 a month with 512 MiB
  of RAM ([DigitalOcean](https://www.digitalocean.com/pricing/droplets)). It runs
  the relay as one small process behind TLS, and TLS ends on the user's own
  machine. It costs the user upkeep: OS updates, TLS renewal, and a domain or
  fixed IP.

## 7. End-to-end encryption with only built-in crypto

### What both platforms ship

| Primitive | CryptoKit (macOS / iOS) | Web Crypto in Safari (macOS and iOS) |
|---|---|---|
| X25519 key agreement | 10.15 / 13 | 17 |
| Ed25519 signatures | 10.15 / 13 | 17 |
| P-256 ECDH | 10.15 / 13 | 11 |
| HKDF | 11 / 14 | 11 |
| AES-GCM | 10.15 / 13 | 7 |
| ChaCha20-Poly1305 | 10.15 / 13 | none |
| HPKE | 14 / 17 | none |

Sources: Apple's CryptoKit pages for
[Curve25519.KeyAgreement](https://developer.apple.com/documentation/cryptokit/curve25519/keyagreement),
[Curve25519.Signing](https://developer.apple.com/documentation/cryptokit/curve25519/signing),
[P256.KeyAgreement](https://developer.apple.com/documentation/cryptokit/p256/keyagreement),
[HKDF](https://developer.apple.com/documentation/cryptokit/hkdf),
[AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm),
[ChaChaPoly](https://developer.apple.com/documentation/cryptokit/chachapoly) and
[HPKE](https://developer.apple.com/documentation/cryptokit/hpke); MDN's
[SubtleCrypto compat data](https://github.com/mdn/browser-compat-data/blob/main/api/SubtleCrypto.json),
where iOS mirrors the Safari version. MDN's
[SubtleCrypto page](https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto)
has no ChaCha20-Poly1305 or HPKE.

- **X25519 and Ed25519 landed in Safari 17, so iOS 17 is the floor** for a
  25519-based design. The Web Push floor is iOS 16.4. A P-256 design reaches
  16.4, but the Noise spec defines only 25519 and 448 as DH functions
  ([Noise](https://noiseprotocol.org/noise.html)), so it would leave the spec.
- **The common AEAD is AES-GCM.** Web Crypto has no ChaCha20-Poly1305. Noise
  defines an `AESGCM` cipher, so `Noise_IKpsk2_25519_AESGCM_SHA256` can be
  built from Web Crypto (X25519, AES-GCM, SHA-256, HMAC) and from CryptoKit
  with no extra library.

### A minimal scheme

**Pairing, once per phone:**

1. The laptop holds a long-term X25519 key pair `L`, kept in the Keychain. It
   makes a room ID `R` and a pairing secret `P`, each 32 random bytes.
2. The laptop shows a QR code and joins room `R` on the relay. The QR code
   holds the relay URL, `R`, `P`, `L.pub` and an expiry a few minutes out, for
   example
   `tbd-pair:1?relay=https://acme-relay.acme.workers.dev&room=…&psk=…&key=…&exp=…`.
3. The phone makes its own long-term X25519 key pair `S` as a non-extractable
   `CryptoKey` in IndexedDB, then joins room `R`.
4. The phone runs `Noise_IKpsk2_25519_AESGCM_SHA256` as initiator with `psk =
   P`. Message 1 is `e, es, s, ss` and carries `S.pub` encrypted. Message 2 is
   `e, ee, se, psk`. This is WireGuard's pattern
   ([WireGuard protocol](https://www.wireguard.com/protocol/)).
5. The laptop stores `S.pub` as a paired device, derives a per-device PSK from
   the handshake hash, and deletes `P`. A QR code works once.

**Every later connection:**

6. The phone runs the same `IKpsk2` handshake with the per-device PSK. The
   laptop accepts only a paired `S.pub`. Fresh ephemeral keys give each
   connection new keys and forward secrecy.

**Every frame:**

7. The handshake yields one key per direction. Each frame is AES-GCM with the
   Noise nonce: 32 zero bits, then a 64-bit counter that starts at 0 and only
   goes up. WebSocket delivery is ordered, so the receiver expects exactly the
   next counter and drops the connection on anything else. That rejects
   replays and reordering within a connection. New keys per connection reject
   replays across connections.
8. The application adds its own sequence number inside the ciphertext, so a
   reconnecting phone can say "resend after event N." The relay stores nothing.

This is what "QR carries the relay URL, a secret and the laptop key; the phone
answers with its key; both derive a session key; frames carry counters" turns
into once it is made safe. Writing it by hand ends up rebuilding Noise `IK`, so
follow the spec. The Noise wiki keeps shared test vectors; their exact location
is **unverified** in this pass.

### Standards to follow

- **Noise** – `IK` when the initiator already knows the responder's static key
  and sends its own at once; `XK` when it sends its own key in a third message
  for better identity hiding; `KK` when both keys are known; `XX` when neither
  is. The `pskN` modifiers mix a pre-shared key into message N
  ([Noise spec](https://noiseprotocol.org/noise.html)).
- **PAKE, only for short codes** – a six-digit code instead of a QR code needs a
  password-authenticated key exchange. SPAKE2 is
  [RFC 9382](https://www.rfc-editor.org/rfc/rfc9382). CPace is still an
  Internet-Draft ([draft-irtf-cfrg-cpace](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/)).
  OPAQUE ([RFC 9807](https://datatracker.ietf.org/doc/draft-irtf-cfrg-opaque/))
  is a client-server protocol and fits this case poorly. Magic Wormhole uses
  SPAKE2 so that a malicious server gets "only a single guess" per code
  ([Magic Wormhole](https://magic-wormhole.readthedocs.io/en/latest/welcome.html)).
  Neither CryptoKit nor Web Crypto exposes the curve point arithmetic SPAKE2 or
  CPace need, so a PAKE means a library. A QR code with a 256-bit secret avoids
  the PAKE entirely.
- **HPKE** ([RFC 9180](https://www.rfc-editor.org/rfc/rfc9180)) is in CryptoKit
  but not in Web Crypto, so it cannot be the shared primitive.

### Pitfalls

- **A pairing secret used directly as the session key** gives no forward
  secrecy. A leaked QR code would then decrypt recorded traffic. Use fresh
  ephemeral keys per connection.
- **A low-entropy code without a PAKE** lets the relay brute-force it offline
  from one recorded handshake.
- **AES-GCM nonce reuse** breaks both secrecy and integrity
  ([NIST SP 800-38D](https://csrc.nist.gov/pubs/sp/800/38/d/final)). Never
  restart a counter under the same key. New keys per connection make this
  easy.
- **The first handshake message can be replayed.** Noise marks that payload as
  "vulnerable to replay" ([Noise spec](https://noiseprotocol.org/noise.html)).
  Never act on it. WireGuard puts a timestamp in it and drops any initiation
  that is not newer than the last
  ([WireGuard protocol](https://www.wireguard.com/protocol/)).
- **One key for both directions** allows reflection. Noise already splits them.
- **Key encodings differ.** Web Crypto exports a P-256 public key as a 65-byte
  point with a `0x04` prefix. CryptoKit's `x963Representation` matches that,
  while its `rawRepresentation` omits the prefix. X25519 keys are 32 raw bytes
  on both sides. Check with a cross-platform test.
- **Safari's Ed25519 signatures are randomized**, not deterministic as in RFC
  8032 ([MDN compat note](https://github.com/mdn/browser-compat-data/blob/main/api/SubtleCrypto.json)).
  They still verify anywhere. Do not depend on signatures being repeatable.
- **The web app's origin is a trust root** (see above).
- **Metadata leaks.** The relay sees frame sizes and timing, and so can tell
  when an agent is busy. Pad frames if that matters.
- **Revocation** – the laptop keeps the list of paired phone keys. Revoking one
  removes it. Rotating `L` un-pairs every phone.
- **A stolen, unlocked phone is a remote shell.** Crypto cannot fix that.
  Consider a confirmation step for risky actions. Options for that are out of
  scope here.

## Unverified items

- Whether Cloudflare sign-up for the Free plan asks for a card.
- Whether rejected requests count against the Workers Free daily quota.
- Whether TBD can create the `workers.dev` subdomain for a new account through
  the API alone.
- Relay latency figures (estimates only).
- WebSocket support through Quick Tunnels.
- Whether a CLI-created named tunnel avoids Zero Trust onboarding.
- `cloudflared` recovery speed after a laptop network change.
- Whether a WebSocket inside Tailscale survives a phone network switch.
- Which Tailscale doc is current on Funnel support for macOS variants.
- The exact Apple Web Push host (`web.push.apple.com`).
- TURN-needed rates for phone-on-cellular to home-laptop pairs.
- Google public STUN terms.
- WebRTC in a hidden `WKWebView`.
- ngrok interstitial bypass and TLS termination; Deno Deploy WebSocket limits.
- The location of the Noise test vectors.

## Ranking for TBD

1. **Cloudflare Worker + Durable Object relay, as the default.** It is the only
   option that needs nothing on the phone but a web page, nothing on the
   laptop but an outbound WebSocket, and no domain. It costs $0 at this
   traffic, with hibernation making idle pairings free. A Deploy button or a
   TBD-driven API upload keeps setup to an account and a click. The relay is
   30 lines and stores nothing, so there is little to maintain or audit. The
   costs are a Cloudflare account per user, and the fact that the web app's
   origin becomes a trust root if the Worker serves it. Document that, or
   serve the client from somewhere the user trusts more.
2. **Tailscale Serve, as the opt-in direct path.** It has the best security
   baseline: no public endpoint, WireGuard end to end, roaming, and the laptop
   itself serves the web app. It needs no relay code. It costs a phone VPN,
   which conflicts with work VPNs and must be on to use the app, plus a CT log
   entry for the machine name. Run the same end-to-end protocol over it, so the
   phone can switch transports without re-pairing.
3. **A user's own relay elsewhere (a $4 VPS or Deno Deploy).** Port the same
   dumb relay for users who will not use Cloudflare. The protocol does not
   change.
4. **Tailscale Funnel or a named Cloudflare Tunnel, not first-class.** Funnel is
   beta and its macOS support is documented both ways. A named tunnel needs a
   domain and Zero Trust onboarding, and exposes a laptop HTTP server for no
   gain over the Worker.
5. **Not recommended.** Quick Tunnels (the URL changes on every restart, no
   uptime guarantee; fine for a demo). WebRTC (still needs the relay and a TURN
   fallback, plus a large native library, for traffic too small to benefit).
   CloudKit and APNs (paid membership and signed builds). ntfy.sh, public MQTT
   and Supabase (rate caps, public topics, or pausing when idle).

Across every option, three design choices hold:

- **The transport is just a WebSocket URL plus a room.** The relay is a dumb
  pipe and the security lives end to end.
- **Push goes from the laptop to Apple** as standard Web Push, with no relay
  and no Apple account.
- **The phone client is a Home Screen web app on iOS 17 or later**, which gives
  it X25519, Web Push and AES-GCM with no library.
