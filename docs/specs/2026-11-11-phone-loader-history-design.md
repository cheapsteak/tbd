# The phone's back button steps through worktrees

On a paired phone, the browser's back and forward step through the worktrees the user visited in
the phone app. That covers iOS Safari's toolbar buttons and edge swipe, and Android's system back.
Back from the sessions list leaves the page, as on any website.

The loader owns the browser history. The app asks the loader, over its existing port, to add or
rewrite an entry. The loader tells the app when the browser moves to an entry. Nothing changes on
the laptop or the relay.

Phone control already ships behind `phone_control_enabled`, off by default. This design adds no
flag of its own.

## User story

As a TBD user driving sessions from my phone, I want the phone's back button to return to the
worktree or list I came from, so that a back swipe does not throw me out of the app and make the
phone reconnect.

## Goals

- Back and forward move between the worktrees the user visited, and between them and the list.
- Back from the list leaves the page.
- The app frame never reloads when the user goes back or forward.
- The app's own back chevron agrees with the browser's back, so forward returns to the session.
- A tab that iOS reloaded, or a frame the loader replaced, returns to the screen its entry names.
- The loader stores nothing it cannot check, and never a URL from the app.

## Non-goals

- **Tabs as entries.** A tap on another tab of the same worktree rewrites the current entry.
- **Sheets and menus as entries.** Back closes an open sheet or menu as part of its move, but
  opening one adds no entry.
- **The loader's own screens as entries.** Pairing, the laptops list and the connection screens
  add no entries.
- **Changes on the laptop, the relay, or the app protocol.**

## Why the loader owns the history

The app runs in `<iframe sandbox="allow-scripts">`, so its origin is opaque. On WebKit, a back or
forward onto a history entry that the frame itself pushed fires the iframe element's `load` event
in the parent a second time. The frame's document does not reload. The loader treats any second
`load` as the frame navigating away (`AppFrame` in `phone/loader/frame.js`), and it destroys the
frame and shows "Reload this page". Chromium fires no extra `load`, so only WebKit shows the
fault. An end-to-end run of the app's own history entries on the WebKit iPhone project failed
every case with that fault.

A bare-frame probe compared the two owners. When the top page owns the entries, `popstate` fires
on the top page, and neither WebKit nor Chromium fires a `load` on the iframe. So the loader
pushes and rewrites the entries. The app keeps its ban on every History API and Navigation API
call (`phone/app/src-policy.test.js`).

## Overview

- The runner gives the app one new field on its handle: `tbdHost.history === 1`.
- The app decides which moves add an entry and which rewrite one, because only it knows the
  sessions list. It sends `push`, `replace` or `back` to the loader.
- The loader carries those out with `pushState`, `replaceState` and `history.back()`. It listens
  for `popstate` and sends the app a `route` message with the entry's screen.
- An entry holds the app's route as a string the loader never reads, plus the loader's own fields.

## 1. Version skew

The loader is always the newest version on Pages, but a phone can run a cached copy. A laptop can
run any TBD release. So both mixes happen.

- **A new app with an old loader.** The new app requires the new loader. At start it reads
  `tbdHost.history`, and if that field is not `1`, it throws before it draws anything. Every
  loader already treats a bundle that throws at start as a `script` fault: it removes the frame
  and shows "Reload this page" with a Reload button. A reload fetches the new loader. This needs
  no change to old loaders and none to the laptop.
- **A new loader with an old app.** An old app never sends `history` messages and ignores the
  `route` message. The loader then adds no entries, and back leaves the page, as before this
  design. The new loader keeps working with every TBD release.

`tbdHost.protocol` stays `1`. Old apps check for exactly `1`, so a new number would break them on
the new loader.

Pages caches the loader for a few minutes. A merge deploys the loader, and laptops get the new app
later with `tbd update`. So in practice the loader is new before any laptop sends the new app.

## 2. The port messages

From the app to the loader:

- `{t: 'history', op: 'push', state, move}` – add an entry after the current one.
- `{t: 'history', op: 'replace', state, move}` – rewrite the current entry.
- `{t: 'history', op: 'back', move}` – the app's back chevron.

From the loader to the app:

- `{t: 'route', state, move}` – show the screen `state` names. The loader sends it when a frame
  starts, after each `popstate` while a frame runs, and in answer to a `back` it handles itself.

The fields:

- **`state`** is the app's route as a string of at most 1,024 UTF-16 code units, or `null` for
  the sessions list. The loader never reads it. The app's encoding is its own business, so a
  later TBD release can change it.
- **`move`** is a non-negative safe integer. It counts the browser moves the loader has seen or
  started: each `popstate`, and each `back` it acts on. A `route` message carries the current
  count. The app echoes the count from the last `route` it received. The loader drops a `push`,
  `replace` or `back` whose `move` is not the current count.

The `move` check closes one race. The user swipes back just as the app sends a `push` for a tap.
Without the check, the loader would apply the push on top of the entry the swipe reached. With
it, the loader drops the push, and the app shows the screen of the entry the swipe reached, which
the `route` message names. The entry and the screen always agree, and the browser's move wins.

The loader rebuilds each app message from its known fields and drops anything else, as
`appPortMessage` does today:

- `op` must be one of the three names.
- `state` must be `null` or a string within the cap. A `back` carries none.
- `move` must be a non-negative safe integer.
- Other fields are ignored and never stored.

The app's end decodes `route` the same way in `host.ts`, and drops a malformed one.

## 3. History entries

Each entry the loader writes has this state:

```
{ tbdPhone: { v: 1, laptop, doc, step, app } }
```

- **`laptop`** – the ID of the laptop the entry was made for.
- **`doc`** – a random ID the loader picks once per page load. It tells this page load's entries
  from those of an earlier load, which the browser may keep after a reload.
- **`step`** – how many of this page load's entries come before this one. The entry a frame
  starts on has `step` 0, unless it was already this page load's entry.
- **`app`** – the app's `state` string, or `null` for the list.

No call to `pushState` or `replaceState` passes a URL, so the page's address never changes. The
title argument is the empty string.

The loader reads an entry's state as untrusted. An entry is "ours" only when it is a plain object
holding a plain-object `tbdPhone` with `v` equal to 1, string `laptop` and `doc`, a non-negative
safe-integer `step`, and an `app` that is `null` or a string within the cap. Any other entry is
not ours. That includes the page's first entry, which has no state, and an entry a pairing link's
fragment added.

## 4. The loader's rules

All History API calls the loader makes for the app live in one module, `phone/loader/history.js`.
`main.js` uses it, and so does the app's end-to-end test host, so those tests run the real code.
The loader's existing `replaceState` that clears a pairing link from the address stays in
`main.js`.

- **A frame starts.** The loader makes the current entry this laptop's:
  - it keeps the entry's `app` string when the entry is ours and was made for this laptop, and
    sets `null` otherwise;
  - it keeps `doc` and `step` when the entry is ours and from this page load, and sets this page
    load's `doc` and `step` 0 otherwise.

  Then it sends `route` with that string. This is how a tab that reloaded, a new bundle after a
  TBD update, and a retry after "Laptop offline" all return to the entry's screen.
- **`push`.** The loader adds an entry after the current one, for this laptop and this page load,
  with `step` one more than the current entry's and the app's string. The browser drops every
  entry forward of the current one, as a push always does.
- **`replace`.** The loader rewrites the current entry with the app's string. It keeps `step`.
- **`back`.** When the current entry is ours, from this page load, with `step` above 0, the entry
  before it is this page load's own, in this document. The loader counts a move and calls
  `history.back()`. The `popstate` that follows sends `route`. Otherwise the loader counts a
  move, rewrites the current entry to this laptop's list, and sends `route` with `null`. So the
  chevron never leaves the page and never reloads it.
- **`popstate` while a frame runs.** The loader counts a move.
  - When the entry is ours and for this laptop, it sends `route` with the entry's `app`.
  - Otherwise it rewrites the entry to this laptop's list and sends `route` with `null`, so the
    entry matches the screen. It keeps the entry's `doc` and `step` when the entry is ours and
    from this page load, and sets this page load's `doc` and `step` 0 otherwise.
- **`popstate` while a loader screen shows.** This covers the connection screens, the laptops
  list and pairing. The loader counts a move and does nothing else, so the screen stays. A frame
  that starts later opens the screen of the entry the browser is on then.
- **Back from the list.** The list's first entry is the one the loader's page loaded on, so the
  entry before it belongs to whatever page came before. The browser leaves the page.

What stays as it is:

- A pairing link opened while the page is open adds an entry with no state, and the loader
  removes the frame before it acts on the link.
- The `pageshow` listener still resumes only a page restored from the back-forward cache.
- The second-`load` fault still tears down a frame that navigates.

## 5. The app's rules

**Which moves add an entry.** The app sends `push` when the user moves to another worktree:

- from the list to a session;
- from a session to a session in another row (a remote session is a row of its own);
- a fork or create the user asked for that lands in another row (a pending open).

It sends `replace` for every other move that changes the screen:

- a move within one row, such as a tap on another tab, or a fork that opens beside its session;
- a move an event makes, such as the shown session leaving the list.

So back steps through worktrees, not tabs.

**The `route` message.** The app treats it as the user's move to that screen:

- It closes any menu and sheet, clears any pending open, and counts as the user's navigation
  (`nav`). A fork or create still in flight therefore never takes the user away afterwards.
- It shows the session when a row lists it, and the list for `null`.
- When the session list has not fully arrived, which is the case at start, it waits for it.
- When the full list does not hold the session, or the string does not decode, it shows the list
  and sends `replace` with `null`.
- When the screen already shows, only the menu and the sheet close.
- It sends no `push` or `replace` for the move itself.

**The back chevron.** The chevron sends `back` and changes nothing itself. The `route` message
that follows sets the screen. The chevron and the browser's back therefore agree, and the
browser's forward returns to the session the chevron left.

**The route string.** The app encodes its route as a string and decodes `route` messages as
untrusted. If a session route's string would exceed 1,024 code units, the app sends `null` in its
place, so that entry shows the list.

**What the app may call.** `host.ts` remains the only code that touches the raw port. The source
policy keeps banning every History API and Navigation API call in the app, with no exemption.

## 6. Trust

The app bundle is code from the laptop. The loader treats it as untrusted, as it treats every
other message on the port.

- The loader stores the app's string only after checking its type and length. It never passes the
  string to anything that interprets it, and hands it back only to an app frame for the same
  laptop.
- No URL from the app reaches the History API. The address bar never changes.
- History state is readable only by pages of the loader's own origin.
- An app could add many entries to trap the user. The loader adds an entry only when the app asks
  and only with a current `move`, and the browsers' own back-button protection still applies.
  The bundle's hash is checked before it runs, so the bundle is the one the laptop's TBD ships.

## 7. Risks and assumptions

- **Entries added without a recent tap.** Chromium and WebKit both skip, on the browser's back
  button, some entries a page adds without user activation. We expect a tap inside the frame to
  count for the top page, because both engines pass user activation up to ancestor frames, and
  most pushes follow a tap within milliseconds. A pending open can land seconds after its tap,
  and its entry might be skipped. Back would then pass over that worktree. The end-to-end tests
  add entries through real taps, and the device checks cover a fork.
- **Entries from before a reload.** After the page reloads, the browser keeps the entries from the
  earlier page load. In WebKit and Chromium under Playwright, a back onto one of them stays in
  the same page and fires `popstate`, and the loader shows that entry's screen with no
  reconnect. The chevron still steps back only within this page load's entries (section 4),
  because no standard promises that such a move stays in the same document.
- **A cached old loader.** A phone that holds an old loader when its laptop updates sees "Reload
  this page" once. The order of a normal rollout makes this rare (section 1).

## 8. Testing

Every end-to-end run includes the `webkit-iphone` Playwright project, not only Chromium, because
only WebKit fires the second `load`.

- **Loader unit tests** for `history.js`, over a fake History API:
  - the frame-start rules, across laptops and page loads;
  - `push`, `replace` and `back`, with and without an entry before;
  - a stale `move` is dropped;
  - malformed messages are dropped: wrong types, a string over the cap, a non-integer `move`; and
    extra fields are not stored;
  - no call passes a URL;
  - a `popstate` with no frame, and one onto another laptop's entry.
- **`frame.js` unit tests** for the new port messages, in and out.
- **App unit tests**:
  - `readHost` refuses a handle without `history: 1`;
  - `host.ts` decodes `route`;
  - the route string round-trips and decodes untrusted input safely;
  - the shell's rules, over a fake host: which moves push and which replace, the `route` message
    in each case, the chevron, and a restore that waits for the list.
- **The source policy test** bans every History API and Navigation API call in the app, with no
  exemption.
- **App end-to-end tests** (`phone/app/test/e2e/history.spec.js`). The test host uses the
  loader's real `history.js`. Taps are real clicks, and back and forward come from the top page
  (`page.goBack()`, `page.goForward()`, or `history.back()` when Playwright cannot wait on a
  same-document move). The cases:
  - open a worktree, back to the list, forward to it;
  - open worktree A, then worktree B: back to A, back to the list, forward to A;
  - a tab switch, then back: the list shows, not the earlier tab;
  - a sheet open during back closes;
  - the chevron, then forward;
  - a new bundle swapped in, then back shows the entry's screen;
  - a page reload on a session's entry opens that session.

  Each case checks that the frame never reloaded: no second-`load` fault, the frame still on the
  runner, one subscribe, and a draft typed in the composer still there.
- **Version skew, end to end.**
  - A runner without `history: 1` makes the new app fault at start, and the loader shows "Reload
    this page".
  - In the loader's own suite, a fixture bundle that never sends `history` messages adds no
    entries, and back leaves the page.

**Device checks**, on a paired iPhone and an Android phone:

- iOS Safari's back button and edge swipe from a worktree return to the list, and forward returns
  to the worktree with the composer draft intact.
- From the list, back leaves the page.
- From the Home Screen app, the edge swipe returns to the list without a reload.
- Android's system back, from a worktree and then from the list.
- Several tabs in one worktree: switch tabs, then back shows the list.
- The chevron, then the browser's forward.
- A fork into a new worktree, then back returns to the worktree it left.

## 9. Rollout

- No new flag. `phone_control_enabled`, off by default, is the switch for the whole feature.
- Merging deploys the loader to Pages. An old app on the new loader works as before this design.
- Each laptop gets the new app with `tbd update`. From then on its phones need the new loader,
  which Pages already serves.

## 10. Placement and cleanup

All new behavior runs on the phone, in the loader and the app bundle. The daemon gains nothing,
so the compiled-versus-user-land question does not arise.

History entries live in the browser's session history for the tab. TBD creates no file, process
or record that could outlive them, so no reconciler is involved.

## 11. Rejected alternatives

- **The app pushes entries inside its own frame.** WebKit fires a second `load` on the iframe when
  the browser moves onto such an entry, and the loader then destroys the frame. Exempting that
  `load` would weaken the check that catches a frame navigating away.
- **The loader decodes the app's route.** The loader would have to learn the app's session-ref
  format and keep accepting every old one, because laptops lag behind the loader. An opaque,
  bounded string gives the same safety: the loader only stores and returns it.
- **Entries hold only an index, and the app keeps the routes in memory.** A reload or a new frame
  would lose the routes, and the index would race with the browser's own moves.
- **A new `tbdHost.protocol` number.** Old apps accept only `1`, so a new number would break every
  older TBD on the new loader.
- **A hello message from the loader on the port.** The app could not tell an old loader from a
  slow message without a timeout, so it could not refuse an old loader cleanly.
- **A new app on an old loader falls back silently.** The app would have no back button and
  nothing to tell the user why. Requiring the new loader costs one reload.
- **Entries belong to one app run.** After a reload or a new bundle, each older entry would show
  the list, so the user could press back several times with nothing changing.
- **The loader skips stale entries itself.** Stepping through the history on the user's behalf is
  hard to make reliable across engines, and entries tied to the laptop make it unneeded.
- **The chevron moves to the list and adds an entry.** The browser's back would then return to the
  session the chevron left, so the two backs would disagree.
- **A flag of its own.** Phone control is already off by default. A second switch inside it would
  need a way to reach the app, which means a change to the laptop.
