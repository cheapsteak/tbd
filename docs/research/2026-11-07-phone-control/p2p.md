# Phone control: can peer-to-peer replace the deployed relay?

**Status:** Research only. Nothing built.
**Sources:** accessed 2026-11-07. Prices, limits, default lists and probe
results are as found on that date. Placeholder names use `acme`.

## Summary

Peer-to-peer cannot replace the relay that each user deploys. It can only sit
beside it. A WebRTC data channel still needs a meeting point to swap offers,
and on iOS it needs one on every app open, because iOS suspends a backgrounded
page and its connection dies. Libraries such as Trystero borrow public
infrastructure for that meeting point: BitTorrent WebSocket trackers, Nostr
relays and public MQTT brokers. That infrastructure is run by volunteers or
offered as a test service, carries no uptime promise, and is churning. On
2026-11-07, two of Trystero's five default trackers and four of its 29 default
Nostr relays did not answer from one vantage point. One relay operator's
server went down under Trystero traffic in August 2026. Every such server also
sees the IP address and online timing of each laptop. The direct path itself
fails often enough to matter. The best measurement found puts hole punching
at about 70%, and that is a conditional figure. About 40% of cellular
networks that use carrier-grade NAT used the symmetric kind in a 2016 study,
and that kind cannot be punched from the usual home router. So a working
product needs a TURN fallback. TURN needs an account with a provider and a
secret that cannot ship in an open-source client, which is the same per-user
setup the relay already costs. A laptop on good home Wi-Fi does not fix this
on its own. It helps only when the laptop is actually reachable: a router port
mapping, or IPv6 on both ends. Major US mobile carriers are 86 to 95%
IPv6-capable and the largest US home ISPs 68 to 87%, though some smaller
ones are far lower. IPv6 is the most promising part, but nobody has
measured it for this pairing. Even a reachable laptop needs WebRTC
or WebTransport in the browser, because an HTTPS page cannot open a plain
`ws://` socket to a bare address. The laptop also pays for WebRTC, with a
28 MB framework, a C++ library, or a hidden web view in the app. The
recommendation is to keep the deployed relay as the only transport for
version 1. Design the protocol so that a direct path can be added later as an
optimization, and revisit only on the conditions listed in the verdict.

The sibling reports are [transports.md](transports.md) (section 4 covers
WebRTC briefly, section 7 the end-to-end scheme) and
[phone-clients.md](phone-clients.md). This report does not repeat them.

## 1. Public signaling with nothing to deploy

### How Trystero does it

Trystero (by Dan Motzenbecker, MIT, version 0.26.0 at commit `acef9dd`) is the
best-known library for this. It hides the meeting point behind "strategies."
All of them work the same way.

- **A room is a hash.** The topic is SHA-1 of `Trystero@<appId>@<roomId>`
  ([strategy.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/core/src/strategy.ts#L113-L117)).
  Anyone who knows the app ID and room ID can compute it and join.
- **Offers are encrypted, weakly by default.** The SDP is sealed with AES-GCM.
  The key is SHA-256 of `<password>:<appId>:<roomId>`
  ([crypto.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/core/src/crypto.ts#L27-L41)).
  With no password, the README admits that "a relay strategy operator can
  reverse engineer the key using the room and app IDs"
  ([README, Encryption](https://github.com/dmotz/trystero#encryption)).
- **Redundancy is the reliability plan.** Each strategy connects to several
  servers at once and needs only one to work. The author explains that "it's
  inevitable some of them will occasionally go down or deny connections to
  certain users"
  ([issue #78](https://github.com/dmotz/trystero/issues/78)).
- **Default STUN servers** – three Google hosts (`stun.l.google.com`,
  `stun1`, `stun2`, port 19302) and `stun.cloudflare.com:3478`
  ([peer.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/core/src/peer.ts#L713-L716)).
  No TURN server is configured by default. When a pair fails, the library tells
  the developer to "configure TURN servers"
  ([signal-handler.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/core/src/signal-handler.ts#L146-L154)).

### BitTorrent WebSocket trackers

- **How** – the room hash becomes a torrent `info_hash`. Peers "announce" to
  the tracker with full SDP offers attached, and the tracker forwards offers
  and answers between peers. Trystero announces every 10 seconds while active
  and every 120 seconds while dormant, to three trackers at once, with trickle
  ICE off ([torrent/index.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/torrent/src/index.ts#L48-L52)).
- **Default endpoints** – `open.ftorrent.com`, `tracker.webtorrent.dev`,
  `tracker.openwebtorrent.com`, `tracker.btorrent.xyz` and
  `tracker.files.fm:7073/announce`
  ([same file](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/torrent/src/index.ts#L446-L452)).
- **Reliability, in the author's words** – "there are unfortunately only 4
  public webtorrent trackers I'm aware of and all of them have spotty
  reliability," so he discourages this strategy
  ([issue #165](https://github.com/dmotz/trystero/issues/165), April 2026).
  An earlier report found that "the complete tracker list was failing"
  ([issue #45](https://github.com/dmotz/trystero/issues/45)).
- **Terms** – none of the trackers publishes terms that this pass found. The
  operator of `open.ftorrent.com` asked to be added to the default list and
  described the tracker as a "public commons" for exactly this use
  ([issue #186](https://github.com/dmotz/trystero/issues/186)). It runs
  Aquatic, and its public deployment guide states no rate limit and no IP
  logging policy ([zootella/ftorrent](https://github.com/zootella/ftorrent/tree/master/open)).

### Nostr relays

- **How** – each announcement is a signed Nostr event with a throwaway key.
  The event kind falls in the 20000 to 29999 range, which Nostr calls
  ephemeral: such events "are not expected to be stored by relays"
  ([NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md)). The
  topic hash travels in an `x` tag
  ([nostr/index.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/nostr/src/index.ts#L95-L141)).
- **Default endpoints** – 29 relays, of which each app uses five, chosen by a
  hash of its app ID
  ([same file](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/nostr/src/index.ts#L520-L550)).
  The list is rebuilt by a script that reads NIP-66 relay monitors and keeps
  only relays that advertise no auth, payment or proof-of-work requirement.
  The script itself says "This is not historical uptime"
  ([update-nostr-relays.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/scripts/update-nostr-relays.ts)).
- **Reliability** – the author calls Nostr the most robust choice, with
  "hundreds of active relays running"
  ([README](https://github.com/dmotz/trystero#which-strategy-should-i-choose)).
  The library now backs off when a relay answers `rate-limited:` and drops
  relays that answer `blocked:`, `auth-required:` or `pow:`
  ([nostr/index.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/nostr/src/index.ts#L384-L425)).
  NIP-01 defines those prefixes
  ([NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md)).
- **One relay fell over under this load.** In August 2026 the operator of a
  relay on the default list reported that it stopped serving at about 4,000
  events per second, and that 93% of incoming events matched Trystero's
  format. Peers kept announcing every 5.3 seconds to five relays, even after
  their connection was up. The author fixed it within two days: one
  announcement a minute, obeying rate limits, and a pruned list. The operator
  said they had "no objection to Nostr relays being used for peer
  bootstrapping"
  ([issue #192](https://github.com/dmotz/trystero/issues/192)).
- **Terms** – of the 25 default relays that answered a NIP-11 request on
  2026-11-07, two listed a terms-of-service link (one of them an unedited
  template placeholder) and one advertised restricted writes. The rest
  published only technical limits, such as a 128 KiB
  message cap and 20 subscriptions. (Probe described below.)

### Public MQTT brokers

- **How** – a topic per room on a public broker over WebSocket. Four brokers,
  all used at once
  ([mqtt/index.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/mqtt/src/index.ts#L12-L188)).
- **Default endpoints** – `broker.emqx.io:8084`, `public.cloud.shiftr.io`
  (credentials `public:public`), `broker.hivemq.com:8884` and
  `test.mosquitto.org:8081` (same file).
- **Terms** – all three operators that publish terms say the broker is for
  testing:
  - **EMQX** – "Prototype, learn, and test MQTT," and "All messages are visible
    to other users. Do not send sensitive data"
    ([EMQX public broker](https://www.emqx.com/en/mqtt/public-mqtt5-broker)).
  - **HiveMQ** – "The broker is public and shared, so it is not intended for
    private or production data"
    ([HiveMQ public broker](https://www.hivemq.com/mqtt/public-mqtt-broker/)).
  - **Mosquitto** – "please do not abuse or rely upon it for anything of
    importance," and it often runs unreleased code
    ([test.mosquitto.org](https://test.mosquitto.org/)).

### IPFS (actually Waku)

- **How** – the "ipfs" strategy runs a Waku light node and publishes to a
  Waku content topic. It bootstraps from Waku's default fleet
  ([ipfs/index.ts](https://github.com/dmotz/trystero/blob/acef9ddc15528f3d5476b64023c4c8d21ff8d5c9/packages/ipfs/src/index.ts#L41-L46)).
  A failure log in one issue shows those nodes under `status.im` hostnames
  ([issue #78](https://github.com/dmotz/trystero/issues/78)).
- **Reliability** – the author ranks it last of the public strategies "based
  on robustness" ([README](https://github.com/dmotz/trystero#which-strategy-should-i-choose)).

### Bring-your-own strategies

- **Supabase and Firebase** need the developer's own project and key. **ws-relay**
  is a server you run, and "there are no public default servers"
  ([README](https://github.com/dmotz/trystero#self-hosted-websocket-relay)).
  All three are a deployment, so they are no better than TBD's Worker.

### PeerJS's public server

- **How** – PeerJS defaults to a "PeerServer" at `0.peerjs.com:443`. Each peer
  registers an ID. Offers, answers and ICE candidates go to the server as
  plain JSON addressed to the other ID
  ([util.ts](https://github.com/peers/peerjs/blob/125f450c547887982ddecc86a6719f22e0f8f952/lib/util.ts#L38-L57),
  [negotiator.ts](https://github.com/peers/peerjs/blob/125f450c547887982ddecc86a6719f22e0f8f952/lib/negotiator.ts#L78-L87)).
  The server therefore sees both peers' candidate addresses.
- **It ships a shared TURN login.** The default config names
  `turn:eu-0.turn.peerjs.com` and `turn:us-0.turn.peerjs.com` with username
  `peerjs` and password `peerjsp` (same `util.ts`). Anyone can use it.
- **Terms** – the home page says only "Use our free cloud server or host your
  own PeerServer" ([peerjs.com](https://peerjs.com/)). No limits, terms or
  uptime promise were found.
- **Reliability** – users reported connection delays of six minutes and more
  in October 2025 while the status page showed green
  ([issue #1350](https://github.com/peers/peerjs/issues/1350)), an outage in
  April 2022 ([issue #941](https://github.com/peers/peerjs/issues/941)), and
  a laptop-to-phone pair that "works on wifi but fails over cellular" with the
  default servers ([issue #1287](https://github.com/peers/peerjs/issues/1287)).

### A point-in-time probe of the defaults

On 2026-11-07, from one vantage point, this pass tried a WebSocket upgrade
against each default tracker and broker, and a NIP-11 request against each
Nostr relay. This is one sample, not uptime.

| Strategy | Defaults | Answered | Failed |
|---|---|---|---|
| BitTorrent trackers | 5 | 3 | 2 |
| Nostr relays (NIP-11 over HTTPS) | 29 | 25 | 4 |
| MQTT brokers | 4 | 3 | 1 |
| PeerJS server | 1 | 1 | 0 |

- **Trackers** – `tracker.btorrent.xyz` resolves to `127.0.0.1` through both
  1.1.1.1 and 8.8.8.8, so it is dead. `tracker.files.fm:7073` returned
  HTTP 503.
- **Nostr** – two relays refused the connection, one returned 502 and one 503.
  A NIP-11 answer does not prove the WebSocket accepts Trystero events.
- **MQTT** – `test.mosquitto.org:8081` completed TLS but did not upgrade the
  socket within 10 seconds.

### Is this acceptable use, or abuse?

- **Trackers** – one operator explicitly welcomes it (issue #186). The others
  publish nothing. The use is a gray area, not a breach of any terms found.
- **Nostr** – ephemeral events exist for transient traffic, and the operator
  who was overloaded did not object to signaling as such (issue #192). The
  problem is volume. A well-behaved client is acceptable. A noisy one takes
  volunteer servers down.
- **MQTT brokers** – production use goes against the stated purpose of all
  three operators who state one. Using them for a shipped feature is the
  closest of the four to abuse.
- **PeerJS** – the project offers the server freely and states no rules, but
  it is a single hobby-scale server.
- **For TBD specifically** – TBD would point every user's laptop at the same
  small set of third-party servers, with no agreement and no recourse. Each
  laptop would also reconnect on every phone app open. That is free-riding on
  volunteer infrastructure that TBD cannot monitor or support.

### What each signaling path sees

- **Every path** – the IP address of every laptop and phone that connects, the
  time and rate of their messages, and a stable room identifier. Encrypting the
  SDP hides the ICE candidates, not the connecting addresses.
- **Trackers** – the `info_hash` (the room hash), a random `peer_id` per
  session, announce timing, and the SDP. Trystero encrypts the SDP; without a
  password the operator can decrypt it, as noted above.
- **Nostr relays** – a throwaway public key per page load, the event kind and
  topic tag, and the content. Announcements carry the peer ID in clear text
  (issue #192).
- **MQTT brokers** – the topic and every payload, readable by "other users"
  on EMQX's own account.
- **PeerJS** – the chosen peer IDs and the full SDP and candidates in clear
  text, including both sides' addresses.
- **STUN servers** (Google, Cloudflare) – every connecting address. Cloudflare
  says its STUN service "is free and unlimited"
  ([Cloudflare TURN FAQ](https://developers.cloudflare.com/realtime/turn/faq/)).
  No published terms for Google's STUN servers were found (**unverified**).

## 2. How often a direct path works: phone on cellular, laptop at home or work

No study found measures this exact pair. The evidence comes from three
directions.

### Primary data

- **Carrier-grade NAT is nearly universal on cellular.** Netalyzr data showed
  CGN in "over 92%" of cellular networks in all three populations studied
  ([Richter et al., IMC 2016, section 5](https://arxiv.org/abs/1605.05606)).
- **Cellular CGNs are often the hard kind.** The same study found "a large
  fraction of both restrictive (40% symmetric) and permissive (20% full cone)"
  mappings among cellular CGN networks, against 11% symmetric for non-cellular
  CGNs and under 2% for home routers (section 6.5). It concludes that
  symmetric mapping "rules out peer-to-peer connectivity, complicating modern
  protocols such as WebRTC" (section 7). The data is from 2014 to 2016.
- **Hole punching works about 70% of the time, conditionally.** A month-long
  campaign in December 2022 tracked 6.25 million libp2p hole punches across
  networks in 167 countries. It reports "70%±7.1%" success for the
  hole-punching stage. That figure excludes about 29% of attempts where the
  earlier relay or address discovery steps failed, so it is not an
  end-to-end rate. It has no cellular or IPv6 breakdown
  ([Trautwein et al.](https://arxiv.org/abs/2510.27500)).
- **By NAT class**, a later ProbeLab honeypot campaign found 82.9%
  success for port-restricted cone NATs and about 40% for symmetric NATs, and
  noted that true symmetric successes are "in doubt"
  ([ProbeLab](https://probelab.io/blog/can-libp2p-punch-through-nats/)).
  These peers run IPFS nodes, not phones in browsers.

### Vendor and engineer numbers

- **callstats.io (vendor), January 2015 to February 2016** – "22% of the
  conferences need some kind of TURN relay server," and about 9% needed TCP
  because UDP was blocked
  ([webrtcHacks](https://webrtchacks.com/usage-stats/)).
- **Tailscale (vendor), 2020** – an estimate, not a measurement, that the
  basic techniques get "a direct connection over 90% of the time." Tailscale
  adds port-guessing tricks that browsers do not use
  ([How NAT traversal works](https://tailscale.com/blog/how-nat-traversal-works)).
- **Commonly cited 10 to 25%** TURN rates are not traced to a primary dataset
  ([transports.md](transports.md) section 4).
- **Trystero in production** – one team reported that "about 60% of the
  connections within a room don't get established" across about 50 users. The
  thread never settled whether TURN fixed it
  ([issue #118](https://github.com/dmotz/trystero/issues/118)).

### IPv6

IPv6 removes NAT but not firewalls. Tailscale's summary: in an IPv6-only
world traversal "becomes much simpler," but "we're still stuck with stateful
firewalls," which both sides open by sending at the same time
([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)). Section 8
below has the carrier and ISP numbers. No study found measures how often
WebRTC actually uses an IPv6 pair between a phone and a laptop
(**unverified**).

### What this means for TBD

- **On IPv4 a meaningful share of attempts will fail without TURN.** That
  follows from the 2016 CGN data and the 70% conditional figure. A point
  estimate for TBD's pair would be invented, so this report gives none.
- **The failures cluster by network pair.** A user whose carrier and router
  do not mix fails every time, not now and then. Section 8 explains which
  pairs.

## 3. TURN fallback

### What it is

TURN is a relay server for WebRTC. When two peers cannot reach each other,
each sends its packets to the TURN server, which forwards them. The traffic
stays encrypted end to end, but it is no longer direct. RFC 8656 describes it
as a protocol "that allows the host to control the operation of the relay and
to exchange packets with its peers using the relay"
([RFC 8656](https://www.rfc-editor.org/rfc/rfc8656)). In practice TURN is a
deployed relay, run by someone, with credentials.

One property helps TBD. TURN permissions match the peer's IP address only:
"only addresses are compared and port numbers are not considered" (RFC 8656,
section 9). So if just the laptop takes a TURN allocation, a phone behind a
symmetric NAT can still reach it by dialing out, as long as the phone can send
UDP and its carrier keeps one public IP per phone. In that common case the
phone needs no TURN credentials.

### Cloudflare Realtime TURN

- **Price** – "$0.05 per GB of egress," and "The first 1,000 GB each month is
  free," shared with the SFU
  ([Realtime pricing](https://developers.cloudflare.com/realtime/pricing/)).
  TBD's traffic is a few MB a month, so the cost is $0. Whether a Free-plan
  account can create a TURN key is not stated (**unverified**).
- **Ports** – UDP 3478 or 443, TCP 3478 or 80, and TLS 5349 or 443
  ([Cloudflare TURN](https://developers.cloudflare.com/realtime/turn/)). TLS
  on 443 gets through most firewalls that allow web browsing.
- **Credentials** – a backend calls
  `rtc.live.cloudflare.com/v1/turn/keys/<key-id>/credentials/generate-ice-servers`
  with a bearer token and gets a short-lived username and password. Cloudflare
  says: "You should keep your TURN key on the server side (don't share it with
  the browser/app)"
  ([generate credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/)).
  Credentials last at most 48 hours, and relay addresses are IPv4 only
  ([TURN FAQ](https://developers.cloudflare.com/realtime/turn/faq/)).
- **Does it force a Worker?** No. The minting call can come from the laptop,
  which TBD already trusts. The token sits in the Keychain, and the laptop
  takes the allocation itself. But the user still needs a Cloudflare account,
  a TURN key and an API token. That is about the same setup as deploying the
  Worker relay.

### Metered

- **Open Relay** – the tool page offers "20 GB of free TURN Usage every
  month," needs a sign-up for an API key, and fetches `iceServers` from a REST
  call. It also documents a static-auth host whose shared secret is published
  on the page ([Open Relay](https://www.metered.ca/tools/openrelay/)).
- **Paid product page** – lists a free plan of "500 MB monthly TURN usage,"
  with "No credit card required" and auto-expiring credentials through an API
  ([Metered STUN/TURN](https://www.metered.ca/stun-turn)). The two pages
  disagree on the free allowance (**unverified** which applies).
- **Terms** – free plans "carry no SLA and no support obligation," may be
  suspended for breach of the acceptable use policy, and credentials must not
  be shared "beyond your own organisation and your authorised end users"
  ([Metered terms](https://www.metered.ca/terms)).
- **The old static host is gone.** `openrelay.metered.ca`, the host that older
  tutorials use with a fixed login, now resolves to `192.0.2.1`, a
  documentation-only address (DNS lookup on 2026-11-07). The retirement is an
  inference from that record.

### Self-hosted coturn

- **Shape** – a TURN server on a machine with a public IP and open UDP ports.
  Its "TURN REST API" mode takes a shared secret and accepts a username of
  `timestamp:userid` with password `base64(hmac(secret, username))`
  ([turnserver.conf](https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf),
  [draft-uberti-behave-turn-rest](https://datatracker.ietf.org/doc/html/draft-uberti-behave-turn-rest-00)).
  The laptop can hold the secret and mint logins itself.
- **Risk** – "Without access controls, an attacker with valid credentials can
  use your TURN server to reach internal networks," including "localhost
  services, and cloud metadata endpoints"
  ([Enable Security coturn guide](https://www.enablesecurity.com/blog/coturn-security-configuration-guide/)).
- **Fit** – this is a VPS to run and patch. It is more work than the Worker
  relay, and for TBD's traffic the relay could simply carry the data instead.

### Can TURN credentials ship in an open-source client?

No. A long-lived login in public code lets anyone relay through the account.
That spends the quota or runs up a bill, and the abuse is attributed to the
account owner. Cloudflare and Metered both tell customers to keep the secret
server-side or within their own users. PeerJS does ship a shared login, which
works only because the PeerJS project pays for and absorbs the abuse. The safe
pattern for TBD is that each user's laptop holds the user's own secret, mints
short-lived credentials, and uses them for its own allocation.

## 4. WebRTC on the laptop, with no browser

### A hidden `WKWebView`

- **The API exists in web views.** WebKit has said that "RTCPeerConnection and
  RTCDataChannel are available in any web view"
  ([WebKit, 2017](https://webkit.org/blog/7763/a-closer-look-into-webrtc)).
- **A web view with no window is suspended by default.**
  `WKPreferences.inactiveSchedulingPolicy` sets "how a web view that's not in
  a window handles tasks," and the default is `.suspend`. Setting `.none`
  keeps it running. It needs macOS 14, and TBD already requires macOS 15
  ([Apple](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)).
  A developer reported multi-second stalls from a hidden web view's content
  process before this knob existed
  ([Apple Developer Forums 671830](https://developer.apple.com/forums/thread/671830)).
- **App process: likely fine.** TBDApp is an unbundled executable that already
  hosts `WKWebView` for its markdown and web panes. A data channel driven
  through `evaluateJavaScript` and a script message handler should work there.
  This has not been tested (**unverified**).
- **Daemon: unknown.** The daemon links neither AppKit nor WebKit. Hosting a
  web view there means a main run loop and WebKit's helper processes in a
  non-app process. Whether that works is **unverified**. A small helper app
  is the safer shape.
- **Host candidates are hidden.** "Without access to capture devices, WebKit
  only exposes Server Reflexive and TURN ICE candidates" (WebKit, 2017).
  Newer releases send mDNS-obfuscated host candidates instead
  ([WebKit bug 233414](https://bugs.webkit.org/show_bug.cgi?id=233414)). A
  laptop using a web view would therefore hide its LAN address too. The
  same-Wi-Fi case should still work through mDNS, but this is **unverified**.
- **Coupling** – if the app hosts it, phone control dies when the app quits.
- **Cost** – no binary size, since WebKit ships with macOS. The laptop could
  even run the same JavaScript (for example Trystero) as the phone.

### Google's WebRTC via `stasel/WebRTC`

- **Size** – the M157 release (2026-11-05) is a 44 MB zip. Its macOS slice is
  a 28.1 MB universal dynamic framework (arm64 plus x86_64); the iOS device
  slice is 12.0 MB (measured from the release asset).
- **Support** – a Swift Package Manager binary target for macOS and iOS,
  rebuilt for each Chrome milestone
  ([stasel/WebRTC](https://github.com/stasel/WebRTC/releases/tag/157.0.0)).
  It is a third-party build of Google's library, so TBD would follow its
  release cadence for security fixes.
- **Fit** – most of the binary is audio and video code that TBD would never
  use.

### `libdatachannel`

- **What** – a C++ implementation of data channels, media transport and
  WebSockets, "with C bindings," built to avoid "Google's bloated reference
  library." Licensed MPL 2.0 since 0.18. It needs GnuTLS, Mbed TLS or OpenSSL,
  plus usrsctp and libjuice as submodules
  ([libdatachannel](https://github.com/paullouisageneau/libdatachannel)).
- **Swift interop** – through its C API
  ([DOC.md](https://github.com/paullouisageneau/libdatachannel/blob/master/DOC.md)).
  There is no official Swift package or prebuilt macOS binary, so TBD would
  build it from source with CMake. Its built size was not measured
  (**unverified**).
- **Fit** – the leanest native option, at the cost of a C++ build and a TLS
  library inside TBD's Swift package.

### Others

- **Pion** ([pion/webrtc](https://github.com/pion/webrtc), Go) and Rust stacks
  such as [str0m](https://github.com/algesten/str0m) also implement data
  channels. Each would add a second language toolchain to the build.

### Apple's Network framework

- **No ICE.** It offers UDP, TCP, TLS and QUIC connections and Bonjour
  discovery. No ICE, STUN or TURN API was found in its documentation in this
  pass (**unverified** as an absolute). A browser peer needs ICE, DTLS and
  SCTP, so Network framework alone cannot talk to it.

## 5. Security of P2P here

### What a hostile meeting point can do

- **Swap the fingerprints and sit in the middle.** DTLS on a data channel
  authenticates each side only by the certificate fingerprint in the SDP. RFC
  8827 says "the signaling server can potentially mount a man-in-the-middle
  attack," and that the defense needs "some mechanism for independently
  verifying keys" ([RFC 8827, section 9.1](https://www.rfc-editor.org/rfc/rfc8827)).
- **Browsers offer no built-in fix.** WebRTC identity providers
  (`peerIdentity`) exist only in Firefox, not in Chrome or Safari
  ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/api/RTCPeerConnection.json)).
- **Drop, delay, replay and count.** Even with encryption, the meeting point
  controls delivery and sees timing.

### Binding the connection to the paired keys

Three options, in order of preference:

1. **Run the Noise handshake inside the data channel.** Treat DTLS as an
   untrusted pipe. Once the channel opens, run the same Noise handshake the
   relay design uses ([transports.md](transports.md) section 7). Put both
   DTLS fingerprints, taken from the SDP each side actually applied, into the
   Noise prologue. A man in the middle then fails the handshake because the
   prologues differ, and it cannot complete Noise anyway without a paired
   key. libp2p's WebRTC Direct does exactly this: both sides set the Noise
   prologue to a prefix plus both fingerprints, and "On mismatch the final
   Noise handshake MUST fail"
   ([libp2p WebRTC Direct spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc-direct.md)).
   This keeps one protocol for relay and direct paths.
2. **Authenticate the signaling.** Encrypt and authenticate each offer and
   answer with a key derived from the pairing, and add a timestamp and a
   random ID so the receiver rejects stale or repeated messages. The meeting
   point then cannot swap fingerprints or read candidates. Do this as well as
   option 1, not instead of it.
3. **Pin certificates.** Each side makes a long-lived `RTCCertificate`
   (Safari 12.1 and later,
   [MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/api/RTCCertificate.json))
   and the two exchange fingerprints at pairing. This adds expiry and storage
   problems. Whether Safari can store an `RTCCertificate` in IndexedDB is
   **unverified**. Options 1 and 2 make it unnecessary.

### IP address exposure

- **To the phone** – the laptop's candidates reveal its LAN addresses and home
  public IP. The phone is a paired device, so this is acceptable.
- **To public meeting points and STUN servers** – every connection reveals the
  laptop's home or office IP and when the user is active. With public
  infrastructure, that goes to dozens of unrelated operators with no stated
  logging policy. The deployed relay exposes the same data to one party, the
  user's own Cloudflare account.
- **To strangers** – nobody without the room secret learns candidates, as long
  as signaling is encrypted with a real secret rather than Trystero's default
  key.

### Room names

- **Guessing** – a room derived from a 256-bit secret in the QR code cannot be
  guessed. A short or human-chosen room name can, and with Trystero's default
  key anyone who guesses it can also read the SDP.
- **Linkability** – a fixed room hash ties every session from one laptop
  together over months, across IP changes. Derive the room from the pairing
  secret and the current day, and listen on the previous day's room around
  midnight.
- **Flooding** – anyone who sees the hash on a tracker can spam it. With
  authenticated signaling the junk is dropped cheaply, but it still costs
  bandwidth and battery.

## 6. iOS Safari behavior

- **Support** – `RTCPeerConnection` and data channels since Safari 11, and
  `restartIce()` since Safari 14.1
  ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/api/RTCPeerConnection.json)).
- **Background kills the connection.** An Apple DTS engineer: "Once your app
  gets suspended, however, all low-level networking stops," and keeping a
  data-only channel alive is the same as asking to run indefinitely in the
  background ([Apple Developer Forums 799259](https://developer.apple.com/forums/thread/799259),
  September 2025). A developer reports that in iOS Safari WebRTC is
  "suspended as soon as the screen locks or Safari goes into the background,"
  with no Apple reply
  ([Apple Developer Forums 774239](https://developer.apple.com/forums/thread/774239)).
- **The laptop notices within about 30 seconds.** ICE consent checks run every
  4 to 6 seconds, and "Consent expires after 30 seconds"
  ([RFC 7675](https://www.rfc-editor.org/rfc/rfc7675)).
- **Coming back needs signaling again.** A dead connection needs a new peer
  connection or an ICE restart, and both need a fresh offer and answer through
  the meeting point. So P2P depends on the meeting point at every app open,
  not just at pairing. A network switch from Wi-Fi to cellular also needs an
  ICE restart.
- **Reconnect time** – Trystero's tracker strategy waits for full candidate
  gathering, and one user noted that connections "can take a few dozen
  seconds sometimes"
  ([issue #118](https://github.com/dmotz/trystero/issues/118)). No measured
  figure for Safari was found (**unverified**). A relay reconnect is one TLS
  WebSocket.
- **No background wake** – push must show a notification, so WebRTC cannot be
  pre-warmed in the background ([phone-clients.md](phone-clients.md) 1.1).
- **Android is similar.** Android cut a backgrounded tab off the network
  "within seconds" while `navigator.onLine` stayed true, which broke Trystero
  pairings until a restart ([issue #208](https://github.com/dmotz/trystero/issues/208)).

## 7. Other P2P stacks for a phone browser

- **libp2p** – browser-to-browser WebRTC runs its signaling over a relayed
  connection through a "CircuitRelayV2Peer" and uses STUN, with no TURN
  ([libp2p WebRTC spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc.md)).
  go-libp2p relays cap each relayed connection at 2 minutes and 128 KiB by
  default ([resources.go](https://github.com/libp2p/go-libp2p/blob/master/p2p/protocol/circuitv2/relay/resources.go)).
  WebRTC Direct and WebTransport skip signaling, but only toward a server that
  is publicly reachable ([WebRTC Direct spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc-direct.md)).
  So libp2p moves the meeting point to public relay nodes. It does not remove
  it.
- **iroh** – in the browser, "All connections from browsers to somewhere else
  need to flow via a relay server." Traffic stays end-to-end encrypted. The
  docs name WebTransport with certificate hashes and WebRTC as possible future
  work ([iroh docs](https://docs.iroh.computer/deployment/wasm-browser-support)).
  Relay only, today.
- **Holepunch and Hyperswarm** – no browser transport. The path for browsers
  is a WebSocket DHT relay whose README says "This project is still
  experimental. Do not use it in production"
  ([dht-relay](https://github.com/hyperswarm/dht-relay)). The issue for
  "Browser-based WebRTC support" has been open since 2020
  ([hyperswarm #62](https://github.com/holepunchto/hyperswarm/issues/62)).

None of these gives a phone browser a direct path without some reachable node
in the middle.

## 8. When only the laptop side needs to be good

The question is whether a laptop on stable home Wi-Fi is enough, whatever the
phone's network. On IPv4 behind a normal home router, it is not. It becomes
enough only when the laptop is truly reachable.

### Which NAT pairs fail

Two properties decide the outcome. **Mapping** is whether the NAT reuses one
public port for all destinations (endpoint-independent, a "cone" NAT) or picks
a new one per destination (endpoint-dependent, "symmetric"). **Filtering** is
which inbound packets it lets through: from anyone, from any port of an
address the inside host has sent to, or only from the exact address and port
it has sent to ([RFC 4787](https://www.rfc-editor.org/rfc/rfc4787)). Browsers
use plain ICE, and RFC 8445 has no port-prediction step. The rules below
follow from those definitions and from RFC 5128, which says hole punching
"works only when the traversing NAT is EIM-NAT"
([RFC 5128](https://www.rfc-editor.org/rfc/rfc5128)).

- **Cone and cone** – works, whatever the filtering. Each side's STUN-observed
  port is the port the other side will see, so sending at the same time opens
  both filters.
- **Home router with exact address-and-port filtering, phone behind a
  symmetric CGNAT** – fails without TURN. The phone's NAT sends to the laptop
  from a new port, not the one STUN saw. The router admits only the exact
  port the laptop has sent to, so it drops those packets. The laptop's packets
  to the STUN-seen port are dropped by the phone's NAT.
- **Home router with looser filtering (any port, or any port from an address
  already contacted), phone symmetric** – works. The router admits the phone's
  new port. This assumes the carrier keeps one public IP per phone, which RFC
  4787 recommends as "Paired" pooling.
- **Laptop with a public address or a port mapping** – works with any phone
  NAT. The phone only dials out.
- **Symmetric on both sides** – fails without TURN.
- **UDP blocked on either side** – fails without TURN over TCP or TLS.

The bad pair is the common one. Tailscale finds that "In the wild we're
overwhelmingly dealing only with IP-and-port endpoint-dependent firewalls"
([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)). In the
ProbeLab sample, 19.6% of classified peers were port-restricted cone and
another 42.5% had that strict filtering with an unresolved mapping. Only 8.3%
were directly reachable
([ProbeLab](https://probelab.io/blog/can-libp2p-punch-through-nats/)). And
about 40% of cellular CGN networks were symmetric in 2016 (section 2). So "good
home Wi-Fi" plus a phone on such a carrier is exactly the pair that fails.

### Making the laptop reachable with a port mapping

- **macOS has a built-in client.** `DNSServiceNATPortMappingCreate` in the
  `dnssd` API asks the gateway for a mapping. "The NAT should support either
  the NAT-PMP or the UPnP IGD for this API to create a successful mapping."
  It "currently supports IPv4 addresses/mappings only," and it renews the
  mapping until the process exits
  ([Apple](https://developer.apple.com/documentation/dnssd/dnsservicenatportmappingcreate(_:_:_:_:_:_:_:_:_:))).
- **Routers often do not answer.** In a 2011 to 2012 study of about 120,000
  homes, only 35% of gateways responded to UPnP overall: 54% of 2,209 homes in
  one dataset, 22% and 47% in two Netalyzr datasets. Reasons included no
  support, support switched off by default, and firewalls
  ([Probe and Pray, PAM 2012](https://hal.archives-ouvertes.fr/hal-00835395);
  [slides](https://www-old.caida.org/workshops/isma/1202/slides/aims1202_rteixeira.pdf)).
  No measurement of NAT-PMP or PCP availability was found.
- **They fail behind a second NAT.** These protocols only reach the nearest
  NAT, and "CGNAT ISPs tend to turn them off." Tailscale's advice: "You can't
  rely on these protocols being present"
  ([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)).
- **Security** – a mapping exposes a laptop listener to the whole internet.
  The paired Noise handshake must then be the only gate, as with Tailscale
  Funnel in [transports.md](transports.md).

### IPv6 on both ends

APNIC measures the share of users who can reach an IPv6-only object. The
per-network figures are APNIC's 30-day values as published on 2026-11-07. The
US and world rows are daily values for 2026-11-03
([APNIC, United States](https://stats.labs.apnic.net/ipv6/US);
[world](https://stats.labs.apnic.net/ipv6/XA)). The AT&T Mobility row rests on
a much smaller sample than the others.

| Network | IPv6-capable |
|---|---|
| Verizon wireless (AS6167) | 95.4% |
| T-Mobile USA (AS21928) | 94.5% |
| AT&T Mobility (AS20057) | 86.5% |
| AT&T (AS7018) | 87.0% |
| Comcast (AS7922) | 86.2% |
| Cox (AS22773) | 78.3% |
| Verizon wireline (AS701) | 69.4% |
| Charter (AS20115) | 67.9% |
| Frontier (AS5650) | 29.5% |
| CenturyLink (AS209) | 6.6% |
| Starlink (AS14593) | 88.2% |
| United States, all users | 64.1% |
| World, all users | 44.2% |

- **Phones are mostly ready.** Major US carriers are 86 to 95% IPv6-capable.
  Tailscale notes "Most v6-only networks today are mobile operators."
- **Homes vary by ISP.** The big cable companies and AT&T are high. Some DSL
  and fiber providers are far lower, down to 7%. Outside the US the world
  figure is 44%.
- **Home router firewalls block unsolicited inbound by default.** RFC 6092
  says inbound traffic is not forwarded "unless it has been solicited
  explicitly by interior transport endpoints." For routers installed without
  ISP management, it says UDP filtering "SHOULD be endpoint independent by
  DEFAULT," with idle state kept five minutes by default
  ([RFC 6092](https://www.rfc-editor.org/rfc/rfc6092)).
  How many routers follow that recommendation is **unverified**.
- **Hole punching through them should work.** There is no address
  translation, so the port each side sees is the real one. Simultaneous sends
  open both stateful firewalls
  ([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)).
  Whether carrier IPv6 firewalls behave the same is **unverified**.
- **Safari detail** – Safari hides host addresses, so the phone's IPv6 address
  reaches the laptop as a server-reflexive candidate from STUN. Google's and
  Cloudflare's STUN hosts both publish IPv6 addresses (DNS lookup on
  2026-11-07). WebKit fixed a bug that dropped that candidate when the host
  address was public and hidden
  ([WebKit bug 233414](https://bugs.webkit.org/show_bug.cgi?id=233414)).
- **Net effect** – IPv6 on both ends should make a direct path the normal case
  for most US phone-and-home pairs. Nobody has measured it for WebRTC between
  Safari and a laptop (**unverified**).

### Carrier-grade NAT on the home side

- **Fixed-line** – 17 to 18% of non-cellular eyeball networks used CGN in 2016
  ([Richter et al.](https://arxiv.org/abs/1605.05606)). Behind CGN the laptop
  has no public IPv4, and port mapping cannot help.
- **Satellite** – Starlink's default IPv4 policy is CGNAT, which "does not
  allow inbound traffic." Public IPv4 is optional for Priority plans. Every
  Starlink gets a delegated IPv6 /56, and its routers do not support port
  forwarding ([Starlink help](https://starlink.com/support/article/1192f3ef-2a17-31d9-261a-a59d215629f4);
  the page renders by JavaScript, so this text was read through a search
  index).
- **Fixed wireless** – 5G home internet is widely reported to use CGNAT with
  no port forwarding, but no official carrier page confirming it was found
  (**unverified**).

### Office or hotel Wi-Fi

- **UDP is often restricted.** About 9% of callstats.io conferences in 2015 to
  2016 needed TCP ([webrtcHacks](https://webrtchacks.com/usage-stats/)).
  Microsoft tells Teams admins to make sure the firewall "doesn't change the
  mapped Network Address Translation (NAT) addresses or ports for UDP," and
  warns that "Some VPNs might also not support UDP"
  ([Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/prepare-network)),
  which suggests many enterprise networks do both.
- **Inbound is never available.** The laptop gets no port mapping and often no
  IPv6 (**unverified** as a rate).
- **Hotels** – client isolation and captive portals are common, but no data
  was found (**unverified**).
- **A corporate VPN on the laptop** routes everything through the company, so
  any direct path depends on the VPN's policy.
- **Consequence** – on these networks WebRTC needs TURN over TLS on port 443.
  The relay's WebSocket on port 443 works anywhere web browsing works.

### A reachable laptop still needs WebRTC or WebTransport

Confirmed. The phone client is an HTTPS page, which it must be for Web Crypto,
service workers and push ([transports.md](transports.md)).

- **`ws://` is blocked.** Browsers block an insecure WebSocket from an HTTPS
  page. Chrome reports "This request has been blocked; this endpoint must be
  available over WSS"
  ([an example report](https://www.github.com/ratchetphp/Ratchet/issues/1043)).
  The W3C rule is that mixed content "that is not upgradeable … is considered
  to be blockable"
  ([Mixed Content](https://w3c.github.io/webappsec-mixed-content/)). Safari's
  exact behavior was not checked (**unverified**).
- **`wss://` needs a trusted certificate for the address.** Let's Encrypt now
  issues IP address certificates, valid for 160 hours
  ([Let's Encrypt](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)).
  But validation for an IP uses HTTP-01 on port 80 or TLS-ALPN-01 on port 443,
  not DNS ([challenge types](https://letsencrypt.org/docs/challenge-types/)).
  The laptop would need inbound ports 80 or 443 and a stable address. Home IPv6
  privacy addresses and changing prefixes make that fragile.
- **WebTransport is a newer option.** With `serverCertificateHashes`, a page
  can trust a self-signed certificate by hash. Safari supports both from 26.4
  ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/api/WebTransport.json)).
  The certificate must use ECDSA P-256 or similar, not RSA, and be valid for
  under two weeks ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/WebTransport/WebTransport)).
  The laptop would need an HTTP/3 WebTransport server, and Apple ships no
  such API (**unverified** for third-party Swift options).
- **WebRTC is the broad option.** It trusts a self-signed certificate through
  the SDP fingerprint. libp2p's WebRTC Direct even skips signaling toward a
  reachable server by building the SDP locally from a known address and
  certificate hash
  ([spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc-direct.md)).
  That relies on "SDP munging," which the WebRTC spec disallows but browsers
  tolerate
  ([libdatachannel #970](https://github.com/paullouisageneau/libdatachannel/issues/970)).
  Safari support for it is **unverified**.
- **Addresses still change.** A home IPv4 address or IPv6 prefix can change, so
  even a reachable laptop needs a way to tell the phone its new address. That
  is a meeting point again, or a domain name.

### Answer

A stable home connection is not enough on IPv4. The common home router
filters by exact address and port, and many cellular carriers use symmetric
NAT, so that pair fails without TURN. The laptop side alone is enough only
when the laptop is reachable. One way is a working port mapping. UPnP
answered in a fifth to a half of homes in 2011 to 2012 data, and a mapping
never helps behind CGNAT. The other way is IPv6 on both ends. That is likely
for most pairs of a major US carrier and a large US home ISP, but unmeasured.
Office and hotel networks are the worst case. Even when the laptop is
reachable, the phone still needs WebRTC or, on iOS 26.4 and later,
WebTransport, plus a way to learn the laptop's current address.

## Unverified items

- Terms for Google's public STUN servers.
- A measured direct-path rate for a phone on cellular to a laptop at home.
- How often WebRTC uses an IPv6 pair between Safari and a laptop, and how
  carrier IPv6 firewalls filter.
- How many home routers follow RFC 6092's endpoint-independent filtering
  default.
- NAT-PMP and PCP availability on home routers.
- Whether a Free-plan Cloudflare account can create a TURN key.
- Which Metered free allowance applies (20 GB or 500 MB).
- WebRTC in a hidden `WKWebView` in TBDApp, and any `WKWebView` in the daemon.
- Same-Wi-Fi connections when both sides hide host candidates behind mDNS.
- libdatachannel's built size on macOS.
- Whether Safari can store an `RTCCertificate` in IndexedDB.
- Safari's handling of `ws://` from an HTTPS page, and of SDP munging.
- Reconnect time after an iOS app resumes, through public meeting points.
- CGNAT on 5G home internet, from an official source.
- Swift options for a WebTransport server.

## Verdict for TBD

**P2P cannot replace the deployed relay. At most it can add to it.** Every
path to a working P2P connection runs through something a user or a third
party must operate:

- **A meeting point, on every app open.** iOS kills the connection whenever
  the app leaves the foreground, so each return needs a fresh offer and
  answer. Public trackers, Nostr relays and MQTT brokers can carry that, but
  they churn, they publish no uptime or terms (or forbid production use), one
  fell over under this exact load, and each one learns every laptop's IP and
  activity. TBD cannot support users on infrastructure it does not control.
- **A TURN fallback.** On IPv4, a common home router paired with a symmetric
  carrier NAT fails every time, and office networks often block UDP. TURN
  needs a per-user account and a secret that lives on the laptop. That is the
  same setup step the Worker relay costs, so P2P does not remove it.
- **A WebRTC stack on the laptop.** A 28 MB framework, a C++ library with a TLS
  dependency, or a hidden web view that ties phone control to the app.

**A well-connected laptop does not change this.** Good home Wi-Fi on IPv4
still fails against a symmetric carrier NAT. The laptop side alone is enough
only when the laptop is reachable, through a port mapping that many routers
do not offer or IPv6 on both ends, which is promising but unmeasured. Office
and hotel networks remain the worst case. And a reachable laptop still needs
WebRTC or WebTransport in the phone, plus a way to announce its changing
address (section 8).

For TBD's traffic, a few KB per turn, a direct path saves nothing that users
would notice. The relay is free at this volume. Once the relay exists, it is
also the best fallback, better than TURN, because it already carries the
encrypted protocol over port 443.

**What a "relay-optional" design would need**, if it is ever built:

1. **One protocol over any pipe.** The same Noise session and frame format
   over the relay WebSocket or a data channel, with a `transport` field, as
   [orca.md](orca.md) describes. This costs nothing now and keeps the door
   open.
2. **Signaling inside the encrypted protocol.** Offers and answers become
   ordinary encrypted frames. Over the relay that is free. In a no-relay mode
   they go to public meeting points, authenticated with a pairing-derived key,
   in a room that rotates daily.
3. **Noise inside the data channel**, with both DTLS fingerprints in the
   prologue, so a hostile meeting point cannot sit in the middle.
4. **TURN minted by the laptop**, from the user's own TURN account, used only
   for the laptop's allocation.
5. **A laptop WebRTC stack** (a helper app with a hidden `WKWebView`, or
   libdatachannel) and a phone client that tries direct first, then the
   relay.
6. **Honest failure reporting.** In a no-relay mode, some network pairs fail
   every time. The app must say so and offer the relay, not hang.

**Recommendation.** Ship version 1 with the deployed relay as the only
transport. Do only step 1 now: keep the protocol transport-agnostic. Do not
add WebRTC, public meeting points or TURN.

**Revisit P2P when any of these holds:**

- **Setup is the barrier.** Real users drop off at the relay deploy step. Then
  a zero-setup "try it now" mode over public meeting points may be worth its
  costs, with the relay as the documented fix when it fails.
- **Payloads grow.** Live terminal streaming, screen sharing or file transfer
  would make relay bandwidth and latency matter.
- **IPv6 on both ends is measured to work.** If Safari-to-laptop IPv6 data
  channels prove reliable on major carriers and home ISPs, a direct path
  becomes the normal case for many users.
- **Browsers gain a reachable-server path that fits.** WebTransport with
  certificate hashes (Safari 26.4) toward a laptop with a stable IPv6 address
  could remove both WebRTC and signaling for reachable laptops. This needs a
  WebTransport server in Swift and a way to publish the laptop's address.
- **A meeting point appears that TBD can rely on**, one with stated terms,
  capacity and an operator who agrees to this use.
