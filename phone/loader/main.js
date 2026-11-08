// The loader page's controller (spec section 8.1). It reads a pairing link from the address,
// opens the store, and moves between the screens of ui.js: Laptops, pairing, and one laptop's
// connection with its header strip and app frame. Which screen follows what is decided in
// views.js; the work is done by the modules it wires together.

import { systemClock, withVisibleTimeout } from './clock.js';
import { LaptopConnection } from './connection.js';
import { PAIRED_GRACE_MS, STORE_TIMEOUT_MS } from './constants.js';
import { AppFrame, readEnv } from './frame.js';
import { unwrapPhoneKeyPair } from './keys.js';
import {
  deviceNameFromUserAgent, linkErrorMessage, normalizeDeviceName, readPairingLink, takePairingFragment,
} from './links.js';
import { MESSAGES } from './messages.js';
import { PairingError, startPairing } from './pairing.js';
import { checkPresence } from './presence.js';
import { startScanner } from './qr.js';
import { laptopIDFromKey, openStore } from './store.js';
import {
  h, renderCode, renderConfirm, renderConnecting, renderLaptops, renderLinkSheet, renderLoading, renderMenu, renderMessage,
  renderName, renderPairStart, renderPaste, renderStrip,
} from './ui.js';
import {
  bootRoute, connectionScreen, fatalScreen, lastConnectedText, pairingFailureScreen, presenceLine, sortLaptops,
  stripReconnecting,
} from './views.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./clock.js').Visibility} Visibility */
/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */
/** @typedef {import('./types.js').DamagedLaptop} DamagedLaptop */
/** @typedef {import('./types.js').WebSocketLike} WebSocketLike */
/** @typedef {import('./store.js').Store} Store */
/** @typedef {import('./connection.js').ConnectionEvent} ConnectionEvent */
/** @typedef {import('./connection.js').ConnectionState} ConnectionState */
/** @typedef {import('./connection.js').FatalReason} FatalReason */
/** @typedef {import('./pairing.js').PairingFailure} PairingFailure */
/** @typedef {import('./links.js').PairingLinkData} PairingLinkData */
/** @typedef {import('./presence.js').FetchLike} FetchLike */
/** @typedef {import('./ui.js').RowHandle} RowHandle */

/**
 * The strip's open laptop menu. `nodes` stays empty until the laptops are read and the menu
 * is drawn; from then on its nodes stay in the strip until it closes. `recheck` asks the relay
 * again for each laptop whose presence is not known (`checkPresence`), and `abort` cancels
 * what is still out.
 * @typedef {{ abort(): void, recheck(): void, nodes: HTMLElement[] }} Menu
 */

/**
 * Everything the page touches outside its own modules, so a test can hand in fakes.
 * @typedef {object} BootOptions
 * @property {Window} window
 * @property {Document} document
 * @property {Clock} clock
 * @property {IDBFactory} indexedDB
 * @property {SubtleCrypto} subtle
 * @property {FetchLike} fetch
 * @property {(url: string) => WebSocketLike} openSocket
 * @property {(callback: () => void) => unknown} requestAnimationFrame
 */

const RUNNER_URL = new URL('runner.html', import.meta.url).href;
// What a redraw of the Laptops screen puts the focus back on, by position.
const FOCUSABLE = 'button, input, textarea';
const RELAY_HELP = 'Check that this phone is online. If it is, the relay may be down. TBD on the laptop shows the relay status in Settings, under Phone.';

/**
 * Starts the loader. Framed by any page, it does nothing at all: it renders nothing, opens no
 * store and no socket. The page's `<meta>` policy cannot carry `frame-ancestors`, and the
 * host sends no `X-Frame-Options`, so this check is what keeps another site from driving it.
 * @param {BootOptions} options
 * @returns {Promise<void>}
 */
export async function boot(options) {
  const win = options.window;
  if (isFramed(win)) return;
  // The pairing secret leaves the address bar, and the history entry, before anything else.
  // A link opened while the page is already open only changes the fragment, so the page does
  // not load again: it is taken out of the address the moment it arrives, whatever the page
  // is doing (still opening the store, or showing that the store is lost), and only then
  // does the page decide whether to act on it.
  const link = takeLinkFromAddress(win);
  /** @type {LoaderPage | null} */
  let page = null;
  win.addEventListener('hashchange', () => {
    const opened = takeLinkFromAddress(win);
    if (opened !== null) page?.openLink(opened);
  });
  page = new LoaderPage(options);
  page.showLoading();
  if (link !== null) page.openLink(link);
  let store;
  try {
    store = await withVisibleTimeout(
      openStore(options.indexedDB), STORE_TIMEOUT_MS, documentVisibility(options.document), options.clock);
  } catch {
    page.showStoreFailure();
    return;
  }
  page.start(store);
}

/**
 * Takes a pairing link (`#p=…`) out of the page's address, replacing the history entry, so
 * the secret is in neither the address bar nor the history.
 * @param {Window} win
 * @returns {string | null} the link, or null when the address holds none
 */
function takeLinkFromAddress(win) {
  const { link, cleanURL } = takePairingFragment(win.location.href);
  if (link !== null) win.history.replaceState(null, '', cleanURL);
  return link;
}

/**
 * The document's visibility, for the store timeouts, the app frame's start timeout, presence
 * requests, and the signal and handshake timeouts of a connection or a pairing: only time while
 * the page is visible counts, because iOS freezes a hidden page with its store requests, a
 * bundle starting, or a relay's answer in flight.
 * @param {Document} doc
 * @returns {Visibility}
 */
function documentVisibility(doc) {
  return {
    isVisible: () => doc.visibilityState !== 'hidden',
    onChange: (listener) => {
      doc.addEventListener('visibilitychange', listener);
      return () => doc.removeEventListener('visibilitychange', listener);
    },
  };
}

/**
 * @param {Window} win
 * @returns {boolean}
 */
function isFramed(win) {
  try {
    return win.top !== win.self;
  } catch {
    return true;
  }
}

/**
 * @param {Document} doc
 * @param {string} id
 * @returns {HTMLElement}
 */
function element(doc, id) {
  const el = doc.getElementById(id);
  if (el === null) throw new TypeError(`index.html has no #${id}`);
  return el;
}

class LoaderPage {
  #win;
  #doc;
  #clock;
  #subtle;
  #fetch;
  #openSocket;
  #raf;
  #strip;
  #screen;
  #frameHost;
  #probe;
  #visibility;

  /** @type {Store | null} */
  #store = null;
  /** Set once the store is lost: only "Reload this page" shows from then on. */
  #dead = false;
  /** @type {string | null} A pairing link opened before the store was open, taken once it is. */
  #queuedLink = null;
  /** Bumped by every move to another screen, so work that finishes late can tell it is stale. */
  #epoch = 0;
  /** @type {(() => void) | null} Undoes what the current screen started (scanner, presence). */
  #leaveScreen = null;
  /** @type {(() => void) | null} While the Laptops screen shows: asks again for presence not known. */
  #recheckLaptops = null;

  /** @type {LaptopRecord | null} The laptop the strip names. */
  #current = null;
  /** @type {LaptopConnection | null} */
  #connection = null;
  /** @type {ConnectionState | null} */
  #state = null;
  /** @type {string | null} The full screen showing for the current laptop, if any. */
  #shown = null;
  /** @type {((laptopName: string) => void) | null} Renames the laptop on the connecting screen. */
  #renameConnecting = null;
  /** @type {AppFrame | null} */
  #frame = null;
  /** @type {string | null} */
  #frameSha = null;
  #envQueued = false;

  /** @type {Menu | null} */
  #menu = null;
  /** @type {HTMLElement[]} The strip's own nodes (its button, and "Reconnecting…"), not the menu's. */
  #stripHead = [];
  /** @type {HTMLButtonElement | null} */
  #stripButton = null;
  /** @type {HTMLElement[]} */
  #sheet = [];

  /** @type {import('./pairing.js').PairingRun | null} */
  #pairing = null;

  /** @param {BootOptions} options */
  constructor(options) {
    this.#win = options.window;
    this.#doc = options.document;
    this.#clock = options.clock;
    this.#subtle = options.subtle;
    this.#fetch = options.fetch;
    this.#openSocket = options.openSocket;
    this.#raf = options.requestAnimationFrame;
    this.#strip = element(this.#doc, 'strip');
    this.#screen = element(this.#doc, 'screen');
    this.#frameHost = element(this.#doc, 'frame-host');
    this.#probe = element(this.#doc, 'safe-probe');
    this.#visibility = documentVisibility(this.#doc);

    this.#doc.addEventListener('visibilitychange', () => {
      if (this.#doc.visibilityState === 'visible') this.#resume();
    });
    // `persisted`: shown from the back-forward cache. A first load fires `pageshow` too, with
    // nothing to resume.
    this.#win.addEventListener('pageshow', (event) => {
      if (event.persisted) this.#resume();
    });
    this.#doc.addEventListener('keydown', (event) => this.#onKeyDown(event));
    const queueEnv = () => this.#queueEnv();
    this.#win.visualViewport?.addEventListener('resize', queueEnv);
    this.#win.visualViewport?.addEventListener('scroll', queueEnv);
    this.#win.addEventListener('resize', queueEnv);
    this.#win.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', queueEnv);
  }

  /** The spinner, while the store opens. */
  showLoading() {
    this.#mount(renderLoading());
  }

  /**
   * A pairing link, already taken out of the page's address. Until the store is open it
   * waits (a later link replaces it); once the store is lost it is dropped.
   * @param {string} link
   */
  openLink(link) {
    if (this.#dead) return;
    if (this.#store === null) {
      this.#queuedLink = link;
      return;
    }
    this.#takeLink(link, 'scan');
  }

  /**
   * Runs the page on its open store: a pairing link that came first, or else the route.
   * @param {Store} store
   */
  start(store) {
    if (this.#dead) return;
    this.#store = store;
    store.onClosed = () => this.showStoreFailure();
    const link = this.#queuedLink;
    this.#queuedLink = null;
    if (link !== null) {
      this.#takeLink(link, 'scan');
      return;
    }
    this.#route();
  }

  /** Where the page goes without a link: by how many laptops there are. */
  async #route() {
    const list = await this.#loadLaptops();
    if (list === null) return;
    const route = bootRoute(list);
    if (route.kind === 'connect') {
      this.#connect(route.record);
    } else if (route.kind === 'pair') {
      this.#showPair(null);
    } else {
      this.#showLaptops(list);
    }
  }

  // --- screens ----------------------------------------------------------------------------

  /**
   * Leaves whatever is showing: stops the connection, the frame, a pairing, the scanner and
   * any presence checks, and clears the strip.
   * @returns {number} the new epoch
   */
  #leave() {
    this.#stopConnection();
    this.#cancelPairing();
    this.#current = null;
    this.#renderStrip();
    return this.#epoch;
  }

  /**
   * Shows `node` as the screen, in place of the app frame. Every screen is shown through here,
   * and a screen replaces the app: any frame is destroyed, an open strip menu closes (with the
   * layer that catches taps outside it, which would otherwise swallow the first tap on the new
   * screen), and the strip is drawn again, so nothing in the strip (such as "Reconnecting…")
   * outlives the frame it spoke for.
   * @param {HTMLElement} node
   * @param {(() => void) | null} [onLeave]
   */
  #mount(node, onLeave = null) {
    if (this.#dead) return;
    this.#leaveScreen?.();
    this.#leaveScreen = onLeave;
    this.#closeMenu(false);
    this.#destroyFrame();
    this.#screen.replaceChildren(node);
    this.#screen.hidden = false;
    this.#frameHost.hidden = true;
    this.#renderStrip();
  }

  /**
   * "Reload this page" for a store that cannot be opened, was lost, or stopped answering.
   * Nothing else shows after it, and a pairing link that was waiting is dropped.
   */
  showStoreFailure() {
    if (this.#dead) return;
    this.#queuedLink = null;
    this.#leave();
    this.#mount(this.#reloadScreen(null));
    this.#dead = true;
    this.#closeSheet();
  }

  /**
   * A store request, bounded by STORE_TIMEOUT_MS of time while the page is visible.
   * @template T
   * @param {(store: Store) => Promise<T>} request
   * @returns {Promise<T>}
   */
  #ask(request) {
    return withVisibleTimeout(request(/** @type {Store} */ (this.#store)), STORE_TIMEOUT_MS, this.#visibility, this.#clock);
  }

  /**
   * Every laptop, in the order the screens list them.
   * @returns {Promise<{ laptops: LaptopRecord[], damaged: DamagedLaptop[] }>}
   * @throws for a read that fails or takes longer than `#ask` allows
   */
  async #readLaptops() {
    const list = await this.#ask((store) => store.listLaptops());
    return { laptops: sortLaptops(list.laptops), damaged: list.damaged };
  }

  /**
   * Every laptop, for a screen that has nothing else to show, or null after showing the store
   * failure: a read that fails or does not answer in time ends in "Reload this page".
   * @returns {Promise<{ laptops: LaptopRecord[], damaged: DamagedLaptop[] } | null>}
   */
  async #list() {
    try {
      return await this.#readLaptops();
    } catch {
      this.showStoreFailure();
      return null;
    }
  }

  /**
   * Leaves whatever is showing for the spinner, and lists the laptops afresh.
   * @returns {Promise<{ laptops: LaptopRecord[], damaged: DamagedLaptop[] } | null>} null when
   *   the read failed (the store failure shows) or the page moved on meanwhile
   */
  async #loadLaptops() {
    const epoch = this.#leave();
    this.#mount(renderLoading());
    const list = await this.#list();
    return epoch === this.#epoch ? list : null;
  }

  // --- Laptops ----------------------------------------------------------------------------

  /** Opens the Laptops screen, listing the laptops afresh. */
  async #goLaptops() {
    const list = await this.#loadLaptops();
    if (list !== null) this.#showLaptops(list);
  }

  /** @param {{ laptops: LaptopRecord[], damaged: DamagedLaptop[] }} list */
  #showLaptops(list) {
    const epoch = this.#leave();
    if (this.#dead) return;
    /** @type {Map<string, RowHandle>} Each laptop's row as now drawn, by laptop ID. */
    let rowsByID = new Map();
    /** @type {IDBValidKey | null} The key of the row asking to Forget, if any. */
    let asking = null;
    /** @param {IDBValidKey | null} key */
    const ask = (key) => {
      asking = key;
      rerender();
    };
    /** @param {IDBValidKey} key the row's laptop, damaged or not */
    const forgetActions = (key) => ({
      asking: asking === key,
      onForget: () => ask(key),
      onConfirm: () => this.#forget(key, 'laptops'),
      onCancel: () => ask(null),
    });
    const build = () => {
      const now = this.#clock.now();
      const rows = [
        ...list.laptops.map((record) => ({
          name: record.laptopName,
          line: presenceLine(presence.status(record.id), record.lastConnectedAt, now, 'list'),
          onOpen: () => this.#connect(record),
          ...forgetActions(record.id),
        })),
        ...list.damaged.map((damaged) => {
          const name = damaged.laptopName ?? 'this laptop';
          return { name, line: { dot: null, text: MESSAGES.keyMissing(name) }, onOpen: null, ...forgetActions(damaged.key) };
        }),
      ];
      const drawn = renderLaptops({ rows, onPair: () => this.#goPair(null) });
      rowsByID = new Map(list.laptops.map((record, i) => [record.id, drawn.rows[i]]));
      return drawn.root;
    };
    // Asking to Forget, and Cancel, redraw the screen: the user's own tap, not one in progress.
    const rerender = () => {
      if (epoch !== this.#epoch) return;
      const focus = this.#focusIndex(this.#screen);
      this.#screen.replaceChildren(build());
      this.#restoreFocus(this.#screen, focus);
    };
    // Presence comes from the relay's endpoint, never a socket, so listing the laptops never
    // knocks another tab off its room. Each answer changes only its row's status line, in
    // place, so a tap in progress and the scroll position survive it. A return to the page
    // asks again (`#resume`) for the rows not known to be online or offline, so an answer cut
    // short while the phone was locked does not stay.
    const presence = checkPresence(list.laptops, {
      fetch: this.#fetch,
      visibility: this.#visibility,
      clock: this.#clock,
      onResult: (id, status) => {
        if (epoch !== this.#epoch) return;
        const record = list.laptops.find((laptop) => laptop.id === id);
        if (record === undefined) return;
        rowsByID.get(id)?.setLine(presenceLine(status, record.lastConnectedAt, this.#clock.now(), 'list'));
      },
    });
    this.#mount(build(), () => {
      this.#recheckLaptops = null;
      presence.abort();
    });
    this.#recheckLaptops = () => presence.recheck();
  }

  /**
   * Forgets a laptop's record, its keys and its cached bundles, after the user confirmed.
   * @param {IDBValidKey} key
   * @param {'laptops' | 'route'} then where to go next: the Laptops screen, or the pair screen
   *   when no laptop is left and the Laptops screen otherwise
   */
  async #forget(key, then) {
    const epoch = this.#leave();
    this.#mount(renderLoading());
    try {
      await this.#ask((store) => store.forgetLaptop(key));
    } catch {
      this.showStoreFailure();
      return;
    }
    if (epoch !== this.#epoch) return;
    const list = await this.#list();
    if (list === null || epoch !== this.#epoch) return;
    if (then === 'route' && list.laptops.length === 0 && list.damaged.length === 0) {
      this.#showPair(null);
    } else {
      this.#showLaptops(list);
    }
  }

  // --- pairing ----------------------------------------------------------------------------

  /** @param {string | null} error */
  #goPair(error) {
    this.#leave();
    this.#showPair(error);
  }

  /**
   * The pair screen, with the camera running. A camera that fails sends the user to the paste
   * screen with its field focused.
   * @param {string | null} error an inline message for the last scanned or opened link
   */
  #showPair(error) {
    const epoch = this.#leave();
    if (this.#dead) return;
    const { root, video } = renderPairStart({
      error,
      onCancel: () => this.#goLaptops(),
      onPaste: () => this.#showPaste(null, '', false),
    });
    this.#mount(root);
    const scanner = startScanner({
      video,
      clock: this.#clock,
      onText: (text) => {
        if (epoch === this.#epoch) this.#takeLink(text, 'scan');
      },
      onError: () => {
        if (epoch === this.#epoch) this.#showPaste(MESSAGES.camera, '', true);
      },
    });
    this.#leaveScreen = () => scanner.stop();
  }

  /**
   * @param {string | null} error
   * @param {string} value
   * @param {boolean} focus
   */
  #showPaste(error, value, focus) {
    this.#leave();
    const { root, field } = renderPaste({
      error,
      value,
      onBack: () => this.#showPair(null),
      onSubmit: (text) => this.#takeLink(text, 'paste'),
    });
    this.#mount(root);
    if (focus) field.focus();
  }

  /**
   * A scanned, pasted or opened link. A good one opens the name screen; a bad one shows why,
   * on the screen it came from.
   * @param {string} text
   * @param {'scan' | 'paste'} from
   */
  #takeLink(text, from) {
    let link;
    try {
      link = readPairingLink(text.trim(), this.#clock.now());
    } catch (error) {
      if (from === 'paste') this.#showPaste(linkErrorMessage(error), text, false);
      else this.#showPair(linkErrorMessage(error));
      return;
    }
    const nav = this.#win.navigator;
    this.#showName(link, deviceNameFromUserAgent(nav.userAgent, nav.maxTouchPoints), null);
  }

  /**
   * @param {PairingLinkData} link
   * @param {string} value
   * @param {string | null} error
   */
  #showName(link, value, error) {
    this.#leave();
    const { root, field } = renderName({
      laptopName: link.fields.name,
      value,
      error,
      onBack: () => this.#showPair(null),
      onSubmit: (input) => {
        let name;
        try {
          name = normalizeDeviceName(input);
        } catch {
          this.#showName(link, input, MESSAGES.badName);
          return;
        }
        // Inside the tap, so Safari may grant it: persisted storage keeps the keys.
        try {
          this.#win.navigator.storage?.persist?.()?.catch(() => {});
        } catch {
          // Asking is best effort.
        }
        this.#pair(link, name);
      },
    });
    this.#mount(root);
    if (error !== null) field.focus();
  }

  /**
   * Pairs with the laptop, stores it, and connects to it.
   * @param {PairingLinkData} link
   * @param {string} phoneName
   */
  async #pair(link, phoneName) {
    const epoch = this.#leave();
    const laptopName = link.fields.name;
    const onCancel = () => this.#goLaptops();
    this.#mount(renderCode({ laptopName, phoneName, code: null, onCancel }));
    const run = startPairing({
      link,
      deviceName: phoneName,
      openSocket: this.#openSocket,
      subtle: this.#subtle,
      visibility: this.#visibility,
      clock: this.#clock,
      onCode: (code) => {
        if (this.#pairing === run) this.#mount(renderCode({ laptopName, phoneName, code, onCancel }));
      },
    });
    this.#pairing = run;
    let result;
    try {
      result = await run.result;
    } catch (error) {
      if (this.#pairing !== run || epoch !== this.#epoch) return;
      this.#pairing = null;
      const reason = error instanceof PairingError ? error.reason : 'invalid';
      this.#showPairFailure(reason, link, phoneName);
      return;
    }
    if (this.#pairing !== run || epoch !== this.#epoch) return;
    this.#pairing = null;
    /** @type {LaptopRecord} */
    const record = {
      id: laptopIDFromKey(link.laptopKey),
      relay: link.fields.relay,
      // The laptop's new room from `paired`, never the QR code's pairing room.
      room: result.room,
      laptopKey: link.laptopKey,
      laptopName: result.laptopName,
      phoneName,
      phoneKey: result.publicRaw,
      wrapKey: result.wrapKey,
      wrappedKey: result.wrappedKey,
      wrapIV: result.wrapIV,
      pairedAt: this.#clock.now(),
      lastConnectedAt: null,
    };
    try {
      await this.#ask((store) => store.putLaptop(record));
    } catch {
      this.showStoreFailure();
      return;
    }
    if (epoch !== this.#epoch) return;
    // The laptop's device link joins the new room just after `paired`, so a `peer-absent`
    // right away reads as connecting for a while, not offline.
    this.#connect(record, { pair: result.pair, absentGraceMs: PAIRED_GRACE_MS });
  }

  #cancelPairing() {
    const run = this.#pairing;
    this.#pairing = null;
    run?.cancel();
  }

  /**
   * @param {PairingFailure} reason
   * @param {PairingLinkData} link
   * @param {string} phoneName
   */
  #showPairFailure(reason, link, phoneName) {
    const screen = pairingFailureScreen(reason);
    if (screen === null) return;
    const laptop = link.fields.name;
    const bar = { title: 'Pair a laptop', left: 'Close', onLeft: () => this.#goLaptops() };
    const pairAgain = () => this.#goPair(null);
    const back = { label: 'Back to laptops', onClick: () => this.#goLaptops() };
    const retry = { label: 'Try again', kind: /** @type {const} */ ('pri'), onClick: () => this.#pair(link, phoneName) };
    switch (screen) {
      case 'denied':
        this.#mount(renderMessage({
          state: screen, tone: 'err', icon: 'x', nav: bar, title: MESSAGES.denied(laptop),
          body: 'Someone chose Deny on the laptop. If that was a mistake, pair again.',
          actions: [{ label: 'Pair again', kind: 'pri', onClick: pairAgain }, back],
        }));
        return;
      case 'expired':
        this.#mount(renderMessage({
          state: screen, tone: 'rate', icon: 'glass', nav: bar, title: MESSAGES.expired,
          body: 'A code works for 5 minutes. On the laptop, choose Pair a Phone… again to get a new one.',
          actions: [{ label: 'Scan a new code', kind: 'pri', onClick: pairAgain }],
        }));
        return;
      case 'pair-offline':
        this.#mount(renderMessage({
          state: screen, tone: 'idle', icon: 'moon', nav: bar, title: MESSAGES.offline,
          body: `${laptop} may be asleep or closed, or Phone control may be off in TBD.`,
          actions: [retry, back],
        }));
        return;
      case 'pair-relay':
        this.#mount(renderMessage({
          state: screen, tone: 'err', icon: 'wifi-off', nav: bar, title: MESSAGES.relay, body: RELAY_HELP,
          actions: [retry, back],
        }));
        return;
      default:
        this.#mount(renderMessage({
          state: screen, tone: 'err', icon: 'warn', nav: bar, title: MESSAGES.invalidCode,
          actions: [{ label: 'Scan a new code', kind: 'pri', onClick: pairAgain }],
        }));
    }
  }

  // --- one laptop -------------------------------------------------------------------------

  /**
   * Connects to a laptop: rebuilds its key, then starts its connection.
   * @param {LaptopRecord} record
   * @param {{ pair?: CryptoKeyPair, absentGraceMs?: number }} [options] `pair` straight from
   *   pairing, which saves unwrapping the key just stored
   */
  async #connect(record, { pair, absentGraceMs = 0 } = {}) {
    const epoch = this.#leave();
    this.#current = record;
    this.#renderStrip();
    this.#showConnScreen('connecting');
    let keyPair = pair;
    if (keyPair === undefined) {
      try {
        keyPair = await unwrapPhoneKeyPair(this.#subtle, record.wrapKey, record);
      } catch {
        // unwrapPhoneKeyPair reports every failure as a KeyMissingError.
        if (epoch === this.#epoch) this.#showConnScreen('key-missing');
        return;
      }
      if (epoch !== this.#epoch) return;
    }
    const store = /** @type {Store} */ (this.#store);
    /** @type {LaptopConnection} */
    let connection;
    try {
      connection = new LaptopConnection({
        record,
        keyPair,
        cache: {
          get: (laptopID, sha) => store.getBundle(laptopID, sha),
          put: (bundle) => store.putBundle(bundle),
          markUsed: (laptopID, sha, at) => store.markBundleUsed(laptopID, sha, at),
        },
        openSocket: this.#openSocket,
        onEvent: (event) => this.#onConnectionEvent(connection, event),
        absentGraceMs,
        visibility: this.#visibility,
        // A reconnect under a running app finds its bundle here, and goes on without reading
        // or downloading it again; `ready` brings the app's channel back up.
        runningBundle: () => (this.#connection === connection && this.#frame !== null ? this.#frameSha : null),
        clock: this.#clock,
      });
    } catch {
      // A relay or room the socket URL refuses: the record cannot be used.
      this.#showConnScreen('key-missing');
      return;
    }
    this.#connection = connection;
    connection.start();
  }

  /** Stops the connection and removes the app frame. The strip stays. */
  #stopConnection() {
    this.#epoch += 1;
    const connection = this.#connection;
    this.#connection = null;
    this.#state = null;
    this.#shown = null;
    connection?.stop();
    this.#destroyFrame();
    this.#closeMenu(false);
    this.#leaveScreen?.();
    this.#leaveScreen = null;
  }

  #destroyFrame() {
    this.#frame?.destroy();
    this.#frame = null;
    this.#frameSha = null;
    this.#closeSheet();
  }

  /**
   * @param {LaptopConnection} connection
   * @param {ConnectionEvent} event
   */
  #onConnectionEvent(connection, event) {
    if (connection !== this.#connection) return;
    switch (event.kind) {
      case 'state':
        this.#onState(event.state);
        return;
      case 'connected':
        this.#onConnected(event.laptopName);
        return;
      case 'bundle':
        this.#onBundle(connection, event.sha256, event.text);
        return;
      case 'app':
        // Passed on as it came: a body can carry its own `__proto__` key, so it is never copied.
        this.#frame?.deliver(event.body);
        return;
      case 'fatal':
        this.#endConnection(fatalScreen(event.reason), event.reason);
    }
  }

  /** @param {ConnectionState} state */
  #onState(state) {
    this.#state = state;
    if (state === 'ready') this.#recordConnection();
    if (state === 'replaced') {
      // Another tab of this page took the room. The connection has ended, so the frame goes.
      this.#endConnection('replaced');
      return;
    }
    if (this.#frame !== null) {
      this.#frame.setChannel(state === 'ready');
      this.#renderStrip();
      return;
    }
    const screen = connectionScreen(state);
    if (screen !== null) this.#showConnScreen(screen);
  }

  /**
   * The handshake named the laptop: the strip, and the connecting screen if it shows, take the
   * name at once. (The connecting screen is not drawn again for each state that keeps it, so
   * it is renamed in place.) Nothing is stored yet, since the session may still end
   * `incompatible` or in a protocol error.
   * @param {string} laptopName
   */
  #onConnected(laptopName) {
    const current = this.#current;
    if (current === null) return;
    this.#current = { ...current, laptopName };
    this.#renderStrip();
    if (this.#shown === 'connecting') this.#renameConnecting?.(laptopName);
  }

  /**
   * The connection reached `ready`: it records the visit, and the name the handshake reported,
   * in the laptop's record. Only a session that got this far counts as connected.
   */
  #recordConnection() {
    const current = this.#current;
    if (current === null) return;
    const lastConnectedAt = this.#clock.now();
    this.#current = { ...current, lastConnectedAt };
    const { laptopName } = current;
    // Recording the visit is not worth failing a working connection over.
    /** @type {Store} */ (this.#store).touchLaptop(current.id, { lastConnectedAt, laptopName }).catch(() => {});
  }

  /**
   * @param {LaptopConnection} connection
   * @param {string} sha256
   * @param {string} text
   */
  #onBundle(connection, sha256, text) {
    if (this.#frame !== null && this.#frameSha === sha256) return;
    this.#destroyFrame();
    this.#leaveScreen?.();
    this.#leaveScreen = null;
    this.#shown = null;
    this.#screen.replaceChildren();
    this.#screen.hidden = true;
    this.#frameHost.hidden = false;
    this.#frame = new AppFrame({
      host: this.#frameHost,
      runnerURL: RUNNER_URL,
      text,
      sha256,
      sendApp: (body) => connection.sendApp(/** @type {Record<string, unknown>} */ (body)),
      onOpenLink: (url) => this.#showLinkSheet(url),
      onFault: () => this.#endConnection('reload'),
      visibility: this.#visibility,
      clock: this.#clock,
    });
    this.#frameSha = sha256;
    this.#renderStrip();
    this.#sendEnv();
  }

  /**
   * Ends the current laptop's connection, if it has not ended itself, removes the app frame
   * and shows `screen`.
   * @param {'replaced' | 'update' | 'reload' | 'removed'} screen
   * @param {FatalReason} [reason]
   */
  #endConnection(screen, reason) {
    const connection = this.#connection;
    this.#connection = null;
    connection?.stop();
    this.#destroyFrame();
    this.#showConnScreen(screen, reason);
  }

  /** Tries the current laptop again from the start. */
  #retry() {
    const current = this.#current;
    if (current !== null) this.#connect(current);
  }

  /**
   * One of the current laptop's full screens, under the header strip.
   * @param {'connecting' | 'offline' | 'relay' | 'replaced' | 'update' | 'reload' | 'removed' | 'key-missing'} screen
   * @param {FatalReason} [reason]
   */
  #showConnScreen(screen, reason) {
    const current = this.#current;
    if (current === null || this.#dead) return;
    if (screen === this.#shown && screen === 'connecting') return;
    this.#shown = screen;
    const name = current.laptopName;
    const switchLaptop = { label: 'Switch laptop', onClick: () => this.#goLaptops() };
    const tryAgain = { label: 'Try again', kind: /** @type {const} */ ('pri'), onClick: () => this.#retry() };
    switch (screen) {
      case 'connecting': {
        const { root, setName } = renderConnecting({ laptopName: name });
        this.#mount(root);
        this.#renameConnecting = setName;
        return;
      }
      case 'offline': {
        const last = lastConnectedText(current.lastConnectedAt, this.#clock.now());
        this.#mount(renderMessage({
          state: screen, tone: 'idle', icon: 'moon', title: MESSAGES.offline,
          body: last === null
            ? `${name} may be asleep or closed, or Phone control may be off in TBD.`
            : `${name} last connected ${last}. It may be asleep or closed, or Phone control may be off in TBD.`,
          actions: [tryAgain, switchLaptop],
        }));
        return;
      }
      case 'relay':
        this.#mount(renderMessage({
          state: screen, tone: 'err', icon: 'wifi-off', title: MESSAGES.relay, body: RELAY_HELP,
          actions: [tryAgain, switchLaptop],
        }));
        return;
      case 'replaced':
        this.#mount(renderMessage({
          state: screen, tone: 'idle', icon: 'swap', title: MESSAGES.replaced,
          actions: [{ label: 'Reconnect', kind: 'pri', onClick: () => this.#retry() }, switchLaptop],
        }));
        return;
      case 'update':
        this.#mount(renderMessage({
          state: screen, tone: 'rate', icon: 'download', title: MESSAGES.updateTBD,
          body: ['This page is newer than TBD on ', name, '. On the laptop, run ', h('code', null, 'tbd update'), ', then try again.'],
          actions: [tryAgain, switchLaptop],
        }));
        return;
      case 'reload':
        this.#mount(this.#reloadScreen(reason === 'incompatibleLoader' ? name : null));
        return;
      case 'removed':
      case 'key-missing':
        this.#showForgetScreen(screen, current, false);
    }
  }

  /**
   * "This phone was removed from …" or the missing-key screen, each with Forget behind a
   * confirmation.
   * @param {'removed' | 'key-missing'} screen
   * @param {LaptopRecord} current
   * @param {boolean} asking
   */
  #showForgetScreen(screen, current, asking) {
    const name = current.laptopName;
    const ask = asking
      ? renderConfirm({
        name,
        onForget: () => this.#forget(current.id, 'route'),
        onCancel: () => this.#showForgetScreen(screen, current, false),
      })
      : null;
    const actions = [
      { label: `Forget ${name}`, kind: /** @type {const} */ ('danger'), onClick: () => this.#showForgetScreen(screen, current, true) },
      { label: 'Back to laptops', onClick: () => this.#goLaptops() },
    ];
    this.#mount(screen === 'removed'
      ? renderMessage({
        state: screen, tone: 'err', icon: 'x', title: MESSAGES.removed(name),
        body: 'Someone chose Revoke for this phone in TBD Settings on the laptop. Forget the laptop here. To use it again, pair again.',
        actions, ask,
      })
      : renderMessage({ state: screen, tone: 'err', icon: 'warn', title: MESSAGES.keyMissing(name), actions, ask }));
  }

  /**
   * @param {string | null} newerLaptop the laptop whose TBD is newer than this page, if that
   *   is the reason
   */
  #reloadScreen(newerLaptop) {
    return renderMessage({
      state: 'reload', tone: 'work', icon: 'refresh', title: MESSAGES.reload,
      body: newerLaptop === null ? null : `TBD on ${newerLaptop} is newer than this page. Reload to get the new page.`,
      actions: [{ label: 'Reload', kind: 'pri', onClick: () => this.#win.location.reload() }],
    });
  }

  // --- the header strip and its menu ------------------------------------------------------

  /**
   * Draws the strip's own nodes: the laptop's name and "Reconnecting…" while the frame waits
   * for its channel. An open menu after them keeps its nodes, so a tap on it, its focus and
   * its scroll position survive a redraw.
   */
  #renderStrip() {
    const current = this.#current;
    if (current === null) {
      this.#strip.hidden = true;
      this.#strip.replaceChildren();
      this.#stripHead = [];
      this.#stripButton = null;
      return;
    }
    const { nodes, button } = renderStrip({
      laptopName: current.laptopName,
      reconnecting: stripReconnecting(this.#frame !== null, this.#state),
      expanded: this.#menu !== null && this.#menu.nodes.length > 0,
      onToggle: () => (this.#menu === null ? this.#openMenu() : this.#closeMenu(true)),
    });
    const refocus = this.#stripButton !== null && this.#doc.activeElement === this.#stripButton;
    for (const node of this.#stripHead) node.remove();
    this.#strip.prepend(...nodes);
    this.#stripHead = nodes;
    this.#stripButton = button;
    this.#strip.hidden = false;
    if (refocus) button.focus();
  }

  async #openMenu() {
    const current = this.#current;
    if (current === null || this.#menu !== null) return;
    /** @type {Menu} */
    const menu = { abort: () => {}, recheck: () => {}, nodes: [] };
    this.#menu = menu;
    let list;
    try {
      list = await this.#readLaptops();
    } catch {
      // The menu is a convenience over a working app, so a read that fails or stalls only
      // closes it. A store that is really lost has already said so through `onClosed`.
      if (this.#menu === menu) this.#closeMenu(false);
      return;
    }
    if (this.#menu !== menu) return;
    // The current laptop, as this page knows it now, in place of its stored row.
    const laptops = list.laptops.map((record) => (record.id === current.id && this.#current !== null ? this.#current : record));
    const now = this.#clock.now();
    const { nodes, items, rows } = renderMenu({
      laptops: laptops.map((record) => ({
        name: record.laptopName,
        line: presenceLine(undefined, record.lastConnectedAt, now, 'menu'),
        current: record.id === current.id,
        onPick: () => this.#pick(record),
      })),
      onPair: () => this.#goPair(null),
      onManage: () => this.#goLaptops(),
      onDismiss: () => this.#closeMenu(true),
    });
    menu.nodes = nodes;
    this.#strip.append(...nodes);
    this.#renderStrip();
    // Each answer changes only its item's status line, in place, so a tap on the menu is
    // never lost to a redraw. A return to the page asks again, as the Laptops screen does.
    const presence = checkPresence(laptops, {
      fetch: this.#fetch,
      visibility: this.#visibility,
      clock: this.#clock,
      onResult: (id, status) => {
        const at = laptops.findIndex((record) => record.id === id);
        if (this.#menu !== menu || at < 0) return;
        rows[at].setLine(presenceLine(status, laptops[at].lastConnectedAt, this.#clock.now(), 'menu'));
      },
    });
    menu.recheck = () => presence.recheck();
    menu.abort = () => presence.abort();
    items[0]?.focus();
  }

  /** @param {boolean} refocus whether to put the focus back on the strip's button */
  #closeMenu(refocus) {
    const menu = this.#menu;
    if (menu === null) return;
    this.#menu = null;
    menu.abort();
    for (const node of menu.nodes) node.remove();
    this.#renderStrip();
    if (refocus) this.#stripButton?.focus();
  }

  /** @param {LaptopRecord} record */
  #pick(record) {
    if (record.id === this.#current?.id) {
      this.#closeMenu(true);
      return;
    }
    this.#connect(record);
  }

  // --- the app frame's environment and links ----------------------------------------------

  #queueEnv() {
    if (this.#frame === null || this.#envQueued) return;
    this.#envQueued = true;
    this.#raf(() => {
      this.#envQueued = false;
      this.#sendEnv();
    });
  }

  #sendEnv() {
    this.#frame?.sendEnv(readEnv(this.#win, this.#probe, this.#frameHost));
  }

  /** @param {string} url */
  #showLinkSheet(url) {
    this.#closeSheet();
    const { nodes, open } = renderLinkSheet({
      url,
      onOpen: () => {
        // Inside the tap's click handler, so the browser allows the new tab.
        this.#win.open(url, '_blank', 'noopener,noreferrer');
        this.#closeSheet();
      },
      onCancel: () => this.#closeSheet(),
    });
    this.#sheet = nodes;
    this.#doc.body.append(...nodes);
    open.focus();
  }

  #closeSheet() {
    for (const node of this.#sheet) node.remove();
    this.#sheet = [];
  }

  // --- lifecycle --------------------------------------------------------------------------

  /**
   * The page is visible again, or came back from the back-forward cache. Presence showing on
   * the Laptops screen or in the strip's menu is asked for again where it is not known: a row
   * that read "Can't reach the relay", perhaps because the phone locked with its request out,
   * and a row whose request is still out. A row already online or offline keeps its answer,
   * and a request just asked is left running, so the two events of one return ask once.
   */
  #resume() {
    this.#connection?.resume();
    this.#pairing?.probe();
    this.#recheckLaptops?.();
    this.#menu?.recheck();
  }

  /** @param {KeyboardEvent} event */
  #onKeyDown(event) {
    if (event.key !== 'Escape') return;
    if (this.#sheet.length > 0) {
      this.#closeSheet();
    } else if (this.#menu !== null) {
      this.#closeMenu(true);
    }
  }

  /**
   * Which focusable element inside `root` has the focus, by position, so a re-render can put
   * it back.
   * @param {HTMLElement} root
   * @returns {number}
   */
  #focusIndex(root) {
    const active = this.#doc.activeElement;
    if (active === null || !root.contains(active)) return -1;
    return [...root.querySelectorAll(FOCUSABLE)].indexOf(active);
  }

  /**
   * @param {HTMLElement} root
   * @param {number} index from `#focusIndex`
   */
  #restoreFocus(root, index) {
    if (index < 0) return;
    const target = root.querySelectorAll(FOCUSABLE)[index];
    if (target instanceof HTMLElement) target.focus();
  }
}

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  boot({
    window,
    document,
    clock: systemClock,
    indexedDB: window.indexedDB,
    subtle: window.crypto.subtle,
    fetch: (url, init) => window.fetch(url, init),
    // A browser WebSocket is a WebSocketLike; its `send` only types its argument more narrowly.
    openSocket: (url) => /** @type {WebSocketLike} */ (/** @type {unknown} */ (new WebSocket(url))),
    requestAnimationFrame: (callback) => window.requestAnimationFrame(callback),
  });
}
