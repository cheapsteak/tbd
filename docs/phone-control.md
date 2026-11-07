# Phone control

## What this is

You can watch and drive TBD sessions from your phone. The phone talks to your laptop through a
relay that you deploy yourself on Cloudflare's free plan. Phone control is off by default.

## What you need

- TBD
- a free Cloudflare account
- a GitHub account
- a phone with a current browser

## Deploy the relay

1. Open the Deploy button link:
   `https://deploy.workers.cloudflare.com/?url=https://github.com/cheapsteak/tbd/tree/main/relay/cloudflare`.
   You can also reach it from "Set Up Phone Relay…" in the TBD app menu.
2. Sign in and deploy.
3. Copy the `workers.dev` address, for example `https://acme-relay.acme.workers.dev`.

When you open the address in a browser, you see a one-line page saying the relay runs.

## Connect TBD to the relay

1. Open Settings, then Phone, then click "Set Up Phone Relay…".
2. Paste the address and click "Check and Save".

TBD reads the relay's `/v1/info`. It refuses an address that is not a TBD relay, and one that does
not offer relay API 1. It tells you which.

- Addresses must start with `https://`.
- `http://localhost` and `http://127.0.0.1` are accepted only for a local test relay.
- An address is the server name and an optional port, with no path after it, because the pairing
  QR code carries only those.
- TBD checks the relay again every time it connects.

## Turn on phone control

Use the "Phone control" switch in Settings → Phone. With the switch off, TBD keeps no connection
to the relay.

## Pair a phone

1. Click "Pair a Phone…".
2. Scan the QR code with the phone's camera, or open the link on the phone.
3. Name the phone.
4. Check that the laptop shows your phone's name and the same 6-digit code as the phone, then click
   Allow.

The code works once and for 5 minutes. If the codes differ, click Deny. The laptop stores the
phone only after you click Allow.

## Remove a phone

- Open Settings → Phone and click Revoke next to the phone.
- A connected phone shows that it was removed and offers Forget. A phone that was not connected
  sees the laptop as offline from then on.
- Turning off "Phone control" closes every connection but keeps your paired phones.

## What others can see

- **The relay, Cloudflare and the network** see timing, message sizes, IP addresses and room IDs.
  They can drop or delay traffic. They cannot read, change or replay it.
- **Someone who learns the relay address** can use up the free plan's daily quota, which pauses
  phone control until it resets. The free plan cannot charge you. They cannot reach a session.
- **The page host** (the loader site) serves the phone page. It sees page loads, IP addresses and
  browsers. It never sees the part of the link after `#`, which carries the pairing secret.
  Whoever controls the loader's code could ship a page that steals phone keys. This is the largest
  remaining risk. The design spec lists the controls against it.
- **Someone who photographs the QR code** within 5 minutes can start a pairing. You will see a
  code that does not match your phone. Click Deny. Once you click Allow, your phone moves to a new
  private room that the QR code never showed, so the photo cannot be used later to disturb its
  connection.
- **Someone holding your unlocked phone** has full control until you revoke that phone on the
  laptop.

## Statuses and fixes

- **"Unreachable":** check the address and your network.
- **"Not usable":** deploy the relay again from the button.
- **"Relay update available":** sync your copy of the relay, as `relay/cloudflare/README.md`
  describes.
- **"Laptop offline" on the phone:** the laptop is asleep, TBD is not running, or "Phone control"
  is off.
