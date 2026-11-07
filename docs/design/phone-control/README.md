# Phone control mocks

This folder is the reviewed visual design for the phone UI in section 8 of
[the phone control spec](../../specs/2026-11-07-phone-control-design.md). It has three parts:

- **`phone-control-mocks.html`** – the mock. One self-contained page that runs every screen and
  state of the phone UI in a browser, with the real structure and interactions.
- **`screenshots/`** – a picture of every state in light and dark mode, at 390 × 844 points (iPhone
  15 size) and 2× pixels, as lossless WebP. They are listed under "States" below.
- **`capture-screenshots.sh`** – makes the screenshots again from the mock.

## Building to the mocks

The mocks are the design. Build what they show. Do not design the screens again from the spec's
words.

- **Look** – copy the values in the mock's CSS as they are: the colour tokens on `:root` and in the
  dark-mode blocks, font sizes, spacing, corner radii, row heights, and the glyphs in the SVG
  sprite. Do not pick values that are only close.
- **Structure** – the render functions in the mock's script (`stripHTML`, `sessionsHTML`,
  `sessionHTML`, `promptHTML`, `composerHTML`, `sheetHTML`, `newSheetHTML`) give the order of the
  elements and which control opens what. Build components with the same structure.
- **Behaviour** – click through the mock to see what each control does: which menu opens, what a
  confirm asks, and when the composer refuses a send. Build the same behaviour.
- **Words** – copy the UI text exactly: titles, button labels, confirm questions, and error and
  empty-state text. Session names, transcripts and other sample data are placeholders.
- **Not part of the design** – the MOCK panel, the phone frame, buttons labelled "Mock: …", the
  fake timers and the demo transcript stream. In the panel's "Design choices", the first option in
  each row is the chosen design. The other options were rejected, so do not build them.
- **When the spec and the mock differ** – on how a screen looks or what a tap does, the mock wins.
  Say so in the PR and update section 8 to match. Data, protocol and security come from the rest
  of the spec.
- **Proof** – a PR that builds or changes a phone screen shows, for each state it touches, a
  screenshot of the built screen beside the screenshot here, in light and dark mode, at the same
  size. A visible difference needs a stated reason.

## Opening one state

- Put the state's name after `#` to open it directly, for example `phone-control-mocks.html#perm`.
  The names are under "States" below.
- On a local copy, `?theme=dark` or `?theme=light` picks the theme, and `?clean=1` hides the MOCK
  tab: `phone-control-mocks.html?theme=dark&clean=1#perm`.
- At 620 px wide or less, the page fills the screen like the phone app. On a wider screen, a phone
  frame sits beside the controls.

## Changing the mocks

Edit the HTML, run `./capture-screenshots.sh`, look at the new pictures, and commit the HTML and
the screenshots together. A new state goes in the mock's `IXG` index, so it gets a name and a
screenshot. A change to what a screen shows or does also updates section 8 of the spec.

## States

### Loader

- **`#lapmenu`** – Laptop menu

  <img src="screenshots/light/lapmenu.webp" width="195" alt="Laptop menu, light"> <img src="screenshots/dark/lapmenu.webp" width="195" alt="Laptop menu, dark">

- **`#laptops`** – Laptops

  <img src="screenshots/light/laptops.webp" width="195" alt="Laptops, light"> <img src="screenshots/dark/laptops.webp" width="195" alt="Laptops, dark">

- **`#forget-ask`** – Forget a laptop

  <img src="screenshots/light/forget-ask.webp" width="195" alt="Forget a laptop, light"> <img src="screenshots/dark/forget-ask.webp" width="195" alt="Forget a laptop, dark">

- **`#scan`** – Scan the QR code

  <img src="screenshots/light/scan.webp" width="195" alt="Scan the QR code, light"> <img src="screenshots/dark/scan.webp" width="195" alt="Scan the QR code, dark">

- **`#paste`** – Paste link

  <img src="screenshots/light/paste.webp" width="195" alt="Paste link, light"> <img src="screenshots/dark/paste.webp" width="195" alt="Paste link, dark">

- **`#name`** – Name this phone

  <img src="screenshots/light/name.webp" width="195" alt="Name this phone, light"> <img src="screenshots/dark/name.webp" width="195" alt="Name this phone, dark">

- **`#code`** – Confirm code

  <img src="screenshots/light/code.webp" width="195" alt="Confirm code, light"> <img src="screenshots/dark/code.webp" width="195" alt="Confirm code, dark">

- **`#denied`** – Denied

  <img src="screenshots/light/denied.webp" width="195" alt="Denied, light"> <img src="screenshots/dark/denied.webp" width="195" alt="Denied, dark">

- **`#expired`** – Code expired

  <img src="screenshots/light/expired.webp" width="195" alt="Code expired, light"> <img src="screenshots/dark/expired.webp" width="195" alt="Code expired, dark">

- **`#connecting`** – Connecting

  <img src="screenshots/light/connecting.webp" width="195" alt="Connecting, light"> <img src="screenshots/dark/connecting.webp" width="195" alt="Connecting, dark">

- **`#offline`** – Laptop offline

  <img src="screenshots/light/offline.webp" width="195" alt="Laptop offline, light"> <img src="screenshots/dark/offline.webp" width="195" alt="Laptop offline, dark">

- **`#update`** – Update TBD

  <img src="screenshots/light/update.webp" width="195" alt="Update TBD, light"> <img src="screenshots/dark/update.webp" width="195" alt="Update TBD, dark">

- **`#reload`** – Reload this page

  <img src="screenshots/light/reload.webp" width="195" alt="Reload this page, light"> <img src="screenshots/dark/reload.webp" width="195" alt="Reload this page, dark">

- **`#removed`** – Phone removed

  <img src="screenshots/light/removed.webp" width="195" alt="Phone removed, light"> <img src="screenshots/dark/removed.webp" width="195" alt="Phone removed, dark">

- **`#relay`** – Can't reach the relay

  <img src="screenshots/light/relay.webp" width="195" alt="Can't reach the relay, light"> <img src="screenshots/dark/relay.webp" width="195" alt="Can't reach the relay, dark">

- **`#reconnect`** – Connection drops

  <img src="screenshots/light/reconnect.webp" width="195" alt="Connection drops, light"> <img src="screenshots/dark/reconnect.webp" width="195" alt="Connection drops, dark">

### Session list

- **`#sessions`** – Session list

  <img src="screenshots/light/sessions.webp" width="195" alt="Session list, light"> <img src="screenshots/dark/sessions.webp" width="195" alt="Session list, dark">

- **`#bump`** – A status changes now

  <img src="screenshots/light/bump.webp" width="195" alt="A status changes now, light"> <img src="screenshots/dark/bump.webp" width="195" alt="A status changes now, dark">

### Session view

- **`#q1`** – Question

  <img src="screenshots/light/q1.webp" width="195" alt="Question, light"> <img src="screenshots/dark/q1.webp" width="195" alt="Question, dark">

- **`#q-other`** – Other answer

  <img src="screenshots/light/q-other.webp" width="195" alt="Other answer, light"> <img src="screenshots/dark/q-other.webp" width="195" alt="Other answer, dark">

- **`#qm`** – Multi-select

  <img src="screenshots/light/qm.webp" width="195" alt="Multi-select, light"> <img src="screenshots/dark/qm.webp" width="195" alt="Multi-select, dark">

- **`#q3`** – Three questions

  <img src="screenshots/light/q3.webp" width="195" alt="Three questions, light"> <img src="screenshots/dark/q3.webp" width="195" alt="Three questions, dark">

- **`#q3-review`** – Review answers

  <img src="screenshots/light/q3-review.webp" width="195" alt="Review answers, light"> <img src="screenshots/dark/q3-review.webp" width="195" alt="Review answers, dark">

- **`#perm`** – Permission

  <img src="screenshots/light/perm.webp" width="195" alt="Permission, light"> <img src="screenshots/dark/perm.webp" width="195" alt="Permission, dark">

- **`#deny-msg`** – Deny with a message

  <img src="screenshots/light/deny-msg.webp" width="195" alt="Deny with a message, light"> <img src="screenshots/dark/deny-msg.webp" width="195" alt="Deny with a message, dark">

- **`#card-hidden`** – Card hidden

  <img src="screenshots/light/card-hidden.webp" width="195" alt="Card hidden, light"> <img src="screenshots/dark/card-hidden.webp" width="195" alt="Card hidden, dark">

- **`#answered`** – Answered

  <img src="screenshots/light/answered.webp" width="195" alt="Answered, light"> <img src="screenshots/dark/answered.webp" width="195" alt="Answered, dark">

- **`#tool-open`** – Tool row open

  <img src="screenshots/light/tool-open.webp" width="195" alt="Tool row open, light"> <img src="screenshots/dark/tool-open.webp" width="195" alt="Tool row open, dark">

- **`#agent-open`** – Subagent open

  <img src="screenshots/light/agent-open.webp" width="195" alt="Subagent open, light"> <img src="screenshots/dark/agent-open.webp" width="195" alt="Subagent open, dark">

- **`#elsewhere`** – Answered on the laptop

  <img src="screenshots/light/elsewhere.webp" width="195" alt="Answered on the laptop, light"> <img src="screenshots/dark/elsewhere.webp" width="195" alt="Answered on the laptop, dark">

- **`#working`** – Working, with tabs

  <img src="screenshots/light/working.webp" width="195" alt="Working, with tabs, light"> <img src="screenshots/dark/working.webp" width="195" alt="Working, with tabs, dark">

- **`#pill`** – New messages pill

  <img src="screenshots/light/pill.webp" width="195" alt="New messages pill, light"> <img src="screenshots/dark/pill.webp" width="195" alt="New messages pill, dark">

- **`#details`** – Show details on

  <img src="screenshots/light/details.webp" width="195" alt="Show details on, light"> <img src="screenshots/dark/details.webp" width="195" alt="Show details on, dark">

- **`#codex`** – Codex tab

  <img src="screenshots/light/codex.webp" width="195" alt="Codex tab, light"> <img src="screenshots/dark/codex.webp" width="195" alt="Codex tab, dark">

- **`#parked`** – Parked: Send and wake

  <img src="screenshots/light/parked.webp" width="195" alt="Parked: Send and wake, light"> <img src="screenshots/dark/parked.webp" width="195" alt="Parked: Send and wake, dark">

- **`#refused`** – Send refused

  <img src="screenshots/light/refused.webp" width="195" alt="Send refused, light"> <img src="screenshots/dark/refused.webp" width="195" alt="Send refused, dark">

- **`#error`** – Error

  <img src="screenshots/light/error.webp" width="195" alt="Error, light"> <img src="screenshots/dark/error.webp" width="195" alt="Error, dark">

- **`#rate`** – Rate limited

  <img src="screenshots/light/rate.webp" width="195" alt="Rate limited, light"> <img src="screenshots/dark/rate.webp" width="195" alt="Rate limited, dark">

- **`#gone`** – Exited

  <img src="screenshots/light/gone.webp" width="195" alt="Exited, light"> <img src="screenshots/dark/gone.webp" width="195" alt="Exited, dark">

- **`#remote`** – Remote session

  <img src="screenshots/light/remote.webp" width="195" alt="Remote session, light"> <img src="screenshots/dark/remote.webp" width="195" alt="Remote session, dark">

- **`#unknown`** – Unknown status

  <img src="screenshots/light/unknown.webp" width="195" alt="Unknown status, light"> <img src="screenshots/dark/unknown.webp" width="195" alt="Unknown status, dark">

### Menus and sheets

- **`#profmenu`** – Account dropdown

  <img src="screenshots/light/profmenu.webp" width="195" alt="Account dropdown, light"> <img src="screenshots/dark/profmenu.webp" width="195" alt="Account dropdown, dark">

- **`#prof-ask`** – Account dropdown: restart or fork

  <img src="screenshots/light/prof-ask.webp" width="195" alt="Account dropdown: restart or fork, light"> <img src="screenshots/dark/prof-ask.webp" width="195" alt="Account dropdown: restart or fork, dark">

- **`#modelmenu`** – Model dropdown

  <img src="screenshots/light/modelmenu.webp" width="195" alt="Model dropdown, light"> <img src="screenshots/dark/modelmenu.webp" width="195" alt="Model dropdown, dark">

- **`#menu`** – Session menu

  <img src="screenshots/light/menu.webp" width="195" alt="Session menu, light"> <img src="screenshots/dark/menu.webp" width="195" alt="Session menu, dark">

- **`#switch`** – Switch account

  <img src="screenshots/light/switch.webp" width="195" alt="Switch account, light"> <img src="screenshots/dark/switch.webp" width="195" alt="Switch account, dark">

- **`#switch-ask`** – Switch account: restart or fork

  <img src="screenshots/light/switch-ask.webp" width="195" alt="Switch account: restart or fork, light"> <img src="screenshots/dark/switch-ask.webp" width="195" alt="Switch account: restart or fork, dark">

- **`#fork`** – Fork

  <img src="screenshots/light/fork.webp" width="195" alt="Fork, light"> <img src="screenshots/dark/fork.webp" width="195" alt="Fork, dark">

- **`#model`** – Model

  <img src="screenshots/light/model.webp" width="195" alt="Model, light"> <img src="screenshots/dark/model.webp" width="195" alt="Model, dark">

- **`#new-local`** – New: local worktree

  <img src="screenshots/light/new-local.webp" width="195" alt="New: local worktree, light"> <img src="screenshots/dark/new-local.webp" width="195" alt="New: local worktree, dark">

- **`#new-remote`** – New: remote session

  <img src="screenshots/light/new-remote.webp" width="195" alt="New: remote session, light"> <img src="screenshots/dark/new-remote.webp" width="195" alt="New: remote session, dark">
