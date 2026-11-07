# On-device checks for the phone loader

Playwright cannot test everything. Apple's WebKit on a real phone behaves differently from the
Linux build. These checks run by hand.

## When

- Before release of any change under `phone/loader/`.
- Before building on the stack (spec section 14).

## Devices

- iOS 17, 18 and 26. Test each in a Safari tab and as a Home Screen app.
- Android Chrome.

## Setup

This needs plans 1 to 3 merged.

- Deploy the branch's loader to a test Pages origin from a fork. Follow
  `docs/phone-control-loader-repo.md` with the fork's own variables. The deploy runs
  `phone/scripts/stage-loader.sh`, so the device sees exactly what users will see.
- Point TBD's loader URL setting at that origin.
- On the laptop, copy the probe bundle over the shipped one for the session. Never commit it.
  The padding makes the bundle text cross `postMessage` at 300 KB.

  ```sh
  { cat phone/loader/test/fixtures/probe-app.js; printf '/*%0300000d*/\n' 0; } > Sources/TBDDaemon/Resources/phone-app/app.js
  scripts/restart.sh
  ```

- Restore the shipped bundle when done.

  ```sh
  git checkout -- Sources/TBDDaemon/Resources/phone-app/app.js
  scripts/restart.sh
  ```

## Checks

- [ ] The runner loads under the explicit-origin policy. A classic `blob:` script runs. Inline
      script, `new Function`, inline style, remote images and `fetch` stay blocked.
      `adoptedStyleSheets` applies.
- [ ] Trusted Types makes HTML-string writes throw inside the frame (iOS 26 and Android; iOS 17
      and 18 report "not enforced", which is expected).
- [ ] A message port and a 300 KB string pass through `postMessage`.
- [ ] The composer stays above the keyboard with the forwarded viewport values. Safe-area insets
      match on a notched iPhone in both orientations.
- [ ] While pinch-zoomed, the forwarded `layout` and `safeArea` values still match the device.
      The frame's insets do not drift. `readEnv` measures `layout` with `innerWidth` and
      `innerHeight`. Record what iOS Safari reports for them while zoomed.
- [ ] A link tap is intercepted. A forced self-navigation fires a second `load`, which the loader
      catches.
- [ ] Leaving the page and returning rebuilds the connection and the frame without a visible
      flash.
- [ ] Wrapped X25519 keys survive an IndexedDB round trip. Pair, then force-quit Safari or the
      Home Screen app, restart the phone, and reopen the next day. Connect without pairing. Do
      this in both a Safari tab and the Home Screen app. Playwright's Linux WebKit does not
      reproduce Apple WebKit's IndexedDB `CryptoKey` storage, where WebKit bug 312279 lives.
- [ ] jsQR reads the laptop's code in normal room light. Android uses `BarcodeDetector`.
- [ ] Focusing the composer does not zoom the page.
- [ ] The first screen appears within 2 seconds on a cellular link, and scrolling up through
      1,000 items stays smooth. This needs the real app bundle. Run it after plan 6.

## Also record

- What the frame's own `visualViewport` reports while the keyboard is up.
- `env(safe-area-inset-*)` inside the frame, against the forwarded values.

The probe page shows both.

## Record results

Write one line per device and mode in the release PR's description.
