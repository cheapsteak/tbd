# TBD relay

## What this is

A tiny relay that lets TBD on a laptop reach TBD on a phone across any network.

- It forwards encrypted bytes. It cannot read them.
- It stores nothing and keeps no logs.
- It runs on Cloudflare's Workers Free plan. The Free plan has no usage charges. Past its daily limit, requests fail until the limit resets at 00:00 UTC.

## Deploy it

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/cheapsteak/tbd/tree/main/relay/cloudflare)

1. Make a free Cloudflare account. Have a GitHub account too.
2. Press the button above.
3. Sign in to Cloudflare. Connect GitHub when asked.
4. Keep the suggested names. The Worker name becomes part of the relay's address.
5. Press **Create and Deploy**. Wait for the build to finish.
6. Copy the address. It looks like `https://tbd-relay.<your-subdomain>.workers.dev`.
7. Open the address in a browser. It should say "TBD relay".
8. Paste the address into TBD's phone relay setup.

The button copies this folder into a new repository in your GitHub account. Cloudflare builds and deploys from that repository with Workers Builds, which deploys again each time you push to its production branch (usually `main`).

## Keep the address to yourself

Anyone who knows the address can send requests to it. Enough requests use up the free plan's daily allowance. Phone control then pauses until the allowance resets at 00:00 UTC. They cannot read or send anything: all traffic is encrypted end to end between your laptop and your phone.

## Update it

When TBD says "Relay update available", copy this folder from TBD's repository into your copy.

1. Clone the repository the button made in your GitHub account.
2. Inside the clone, run:

   ```sh
   curl -L https://codeload.github.com/cheapsteak/tbd/tar.gz/main | tar -xz --strip-components=3 tbd-main/relay/cloudflare
   ```

3. If you renamed the Worker when you deployed, keep your own `name` line in `wrangler.jsonc`. Run `git diff wrangler.jsonc` and put your name back if it changed.
4. Run `git add -A`, commit, and push to the production branch (usually `main`). Cloudflare deploys the new version.

## Deploy from the command line instead

```sh
npm ci
npx wrangler deploy
```

Wrangler opens a browser so you can log in to Cloudflare.

## API v1

This contract is stable. TBD supports it for good.

- **Any origin can read every HTTP response.** Each one carries `access-control-allow-origin: *`, refusals included, so a page on another origin, like the phone loader, sees the real status. The relay sets no cookies and reads no credentials, so this exposes nothing. CORS does not apply to the WebSocket upgrade.
- **`GET /`** – answers 200 with a one-line text page. It is not part of the API.
- **`GET /v1/info`** – answers `{"name":"tbd-relay","version":"1.0.0","api":[1]}` with `content-type: application/json` and `cache-control: no-store`.
- **`GET /v1/rooms/<roomID>?role=laptop|phone`** – opens a WebSocket.
  - A room ID is 43 base64url characters (`A-Z a-z 0-9 - _`), which is 32 bytes without padding.
  - A room has two roles, `laptop` and `phone`. Each role has one socket. A new socket for a role closes the old one with code 4000 and reason `replaced`.
- **`GET /v1/rooms/<roomID>/presence`** – answers `{"laptop":true}` while the room has an open laptop socket, and `{"laptop":false}` otherwise.
  - It sends `content-type: application/json` and `cache-control: no-store`.
  - It opens no socket and displaces no one. The role and `Upgrade` header play no part.
- **Status codes**
  - 404 – the path is not one of the routes above, or the room ID is malformed. This is checked first, whatever the method.
  - 405 – the method is not GET. The response carries `Allow: GET`.
  - 400 – a room URL without exactly one `role` parameter that equals `laptop` or `phone`.
  - 426 – a room URL without `Upgrade: websocket`. The response carries `Upgrade: websocket`.
- **Frames**
  - Binary frames of up to 65,536 bytes are forwarded unchanged to the other role.
  - If the other role has no open socket, the relay drops the frame. It never queues.
  - A binary frame over 65,536 bytes is not forwarded. The relay closes the sender with code 1009 and reason `frame too large`. The other role gets `peer-left`.
  - Text frames from clients are never forwarded, so a client cannot forge a relay signal.
  - A socket the relay is closing sends nothing more. The relay drops its frames.
- **Signals** – the relay sends these as text frames.
  - `peer-joined` – sent to both sockets when a socket joins and the other role has an open socket. It always means a new peer socket. The old session with the previous peer is over, so the receiver resets its channel.
  - `peer-absent` – sent to a joining phone when no laptop socket is open. A laptop that joins an empty room gets no signal.
  - `peer-left` – sent to the other role when a socket closes or errors and no open socket of its role remains. A socket closed with 4000 because a new one replaced it causes no `peer-left`. A `peer-left` can repeat in rare races, so receivers treat it as idempotent.
- **Keepalive** – the text frame `ping` gets the answer `pong` from the runtime, without waking the room. Clients send one every 30 seconds.

## Develop

```sh
npm ci
npm test
npm run typecheck
npm run check
```
