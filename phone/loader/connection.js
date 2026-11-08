// The connection to one paired laptop: the relay socket, the IK handshake, the loader
// protocol and the bundle download, with reconnects (spec sections 2, 3 and 4.3).
//
// Ordering. Every relay event (signal, frame, close, dead socket), every timer and every
// `resume()` runs through one promise chain, one at a time and in arrival order. Decrypting is
// asynchronous, so a `peer-left` right behind a frame waits until that frame is handled.
// Within one chain task only `stop()` can change what is current, and each task checks for it
// after every await. The bundle cache read is the one wait kept off the chain: IndexedDB can
// stall, so the store read runs beside it, and its answer or its timeout comes back as a task.
// Only the store read is timed. Checking a cached row's hash runs on the chain once the row is
// in hand, as checking a download's does, so a slow phone hashing a large bundle never turns a
// good cache entry into a miss.
//
// Time. The signal and handshake timeouts, the waits for `welcome` and for each bundle chunk,
// the relay socket's waits for a pong, and the post-pairing grace count only time while the page
// is visible: iOS freezes a hidden page, so a timer that falls due while it is hidden must not
// tear down a session whose answer simply could not arrive, nor end a grace sized from those
// waits. Each return to the page gives them a fresh window. The other timers (backoff, cache
// read) run on the clock alone.
//
// Sessions. Each `peer-joined` starts a new session: a fresh initiator, and later its
// transport, welcome and bundle assembly. Anything an older session started that finishes
// late (an encrypted send, say) sees that its session is no longer current and is dropped.

import { NoiseError, createInitiator, phonePrologue, MAX_PLAINTEXT_LENGTH } from './channel/noise.js';
import { base64urlDecode } from './channel/pairingLink.js';
import { BundleAssembler, BundleError, sha256Hex } from './bundle.js';
import { TaskChain } from './chain.js';
import { alwaysVisible, isSoonAfter, systemClock } from './clock.js';
import {
  BUNDLE_CHUNK_TIMEOUT_MS, CACHE_READ_TIMEOUT_MS, HANDSHAKE_RETRIES, HANDSHAKE_TIMEOUT_MS, RESUME_COALESCE_MS,
  SIGNAL_TIMEOUT_MS, WELCOME_TIMEOUT_MS,
} from './constants.js';
import { relaySocketURL } from './links.js';
import { isObject, isPlainObject } from './objects.js';
import {
  ProtocolError, checkCompat, decodeMessage, encodeMessage, makeHello, parseLaptopMessage, readLaptopName,
} from './protocol.js';
import { REPLACED, RelaySocket, reconnectDelay } from './relay.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./clock.js').Visibility} Visibility */
/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */
/** @typedef {import('./types.js').BundleRecord} BundleRecord */
/** @typedef {import('./types.js').WebSocketLike} WebSocketLike */
/** @typedef {import('./relay.js').RelayEvent} RelayEvent */
/** @typedef {import('./protocol.js').LaptopMessage} LaptopMessage */
/** @typedef {import('./protocol.js').WelcomeMessage} WelcomeMessage */
/** @typedef {import('./protocol.js').ChunkMessage} ChunkMessage */
/** @typedef {import('./channel/noise.js').NoiseInitiator} NoiseInitiator */
/** @typedef {import('./channel/noise.js').NoiseTransport} NoiseTransport */
/** @typedef {import('./chain.js').Timer} Timer */

/**
 * @typedef {'connecting' | 'handshaking' | 'offline' | 'loading' | 'ready' | 'reconnecting'
 *   | 'relayUnreachable' | 'replaced'} ConnectionState
 */

/**
 * @typedef {'incompatibleLaptop' | 'incompatibleLoader' | 'revoked' | 'badBundle' | 'protocol'} FatalReason
 */

/**
 * What a LaptopConnection reports. A state is never reported twice in a row. After `fatal`,
 * `replaced` or `stop()` (even one called from inside `onEvent`), nothing more is reported.
 * `app` is reported only while the state is `ready`. `bundle` comes just before `ready`, except
 * when `welcome` names the bundle `runningBundle` reports: the app already runs it, so the
 * state goes to `ready` with no `bundle`.
 *
 * A handshake that goes unanswered reads `offline` (`connecting` during the post-pairing
 * grace), and so does the round of retries that follows (HANDSHAKE_RETRIES of them, each on a
 * fresh socket through the backoff), a retry socket that fails included, until the laptop
 * answers one: `handshaking` comes back with message 2. After the round, the connection waits
 * on its open socket for the laptop's next `peer-joined`.
 * @typedef {{ kind: 'state', state: ConnectionState }
 *   | { kind: 'connected', laptopName: string }
 *   | { kind: 'bundle', sha256: string, text: string }
 *   | { kind: 'app', body: Record<string, unknown> }
 *   | { kind: 'fatal', reason: FatalReason }} ConnectionEvent
 */

/**
 * The bundle cache, as `main.js` adapts the store to it. `get` may resolve null or undefined
 * for a miss, or reject (read as a miss). A `get` that has not answered within
 * CACHE_READ_TIMEOUT_MS is a miss too, and so is a row whose text does not hash to its name
 * (that check runs after the read, outside its timeout).
 * `put` may resolve false (the laptop was forgotten meanwhile) or reject, and `markUsed` may
 * reject: neither is ever fatal.
 * @typedef {object} BundleCache
 * @property {(laptopID: string, sha: string) => Promise<BundleRecord | null | undefined>} get
 * @property {(record: BundleRecord) => Promise<unknown>} put
 * @property {(laptopID: string, sha: string, at: number) => Promise<unknown>} markUsed
 */

/**
 * @typedef {object} LaptopConnectionOptions
 * @property {LaptopRecord} record
 * @property {CryptoKeyPair} keyPair From `unwrapPhoneKeyPair`; its private key is not extractable.
 * @property {BundleCache} cache
 * @property {(url: string) => WebSocketLike} openSocket
 * @property {(event: ConnectionEvent) => void} onEvent
 * @property {number} [absentGraceMs] For this long after `start()`, counting only time while
 *   the page is visible (as the waits it is sized from do), `peer-absent`, `peer-left` and a
 *   handshake that goes unanswered read `connecting` rather than `offline`. When it ends, a
 *   laptop that is away reads `offline` at once, but a retry that is pending, or a handshake
 *   under way, reads `offline` only from its own outcome. Default 0; `main.js` passes
 *   `PAIRED_GRACE_MS` (a signal wait plus a handshake) right after pairing, while the laptop's
 *   device link joins the new room.
 * @property {Visibility} [visibility] The page's visibility. Default: always visible. While
 *   the page is hidden, a reconnect waits for `resume()`, and the signal and handshake
 *   timeouts, the waits for `welcome` and for each bundle chunk, the socket's waits for a pong
 *   and the post-pairing grace stop (`startVisibleTimer`).
 * @property {() => string | null} [runningBundle] The SHA-256 of the bundle the page's app
 *   frame runs now, or null. Default `() => null`. A `welcome` naming it skips the cache read
 *   and the download, so a reconnect under a running app reads no 16 MB row and hashes nothing.
 * @property {() => number} [random] In [0, 1), for the backoff jitter. Default Math.random.
 * @property {Clock} [clock]
 */

/**
 * One handshake on one socket, and what follows it.
 * @typedef {object} Session
 * @property {RelaySocket} socket
 * @property {NoiseInitiator | null} initiator Set once message 1 is out, until message 2.
 * @property {NoiseTransport | null} transport Set by message 2.
 * @property {Timer | null} timer The wait on the laptop under way: for message 2 (the handshake
 *   timeout), then for `welcome`, then, while a bundle downloads, for its next chunk.
 * @property {Timer | null} cacheTimer Armed while the bundle cache is read; null before the
 *   read, and again once it has answered or timed out.
 * @property {WelcomeMessage | null} welcome
 * @property {BundleAssembler | null} assembler While a `bundle.get` is being answered.
 * @property {boolean} ready
 */

// The backoff reaches its cap long before this; the bound only keeps `2 ** attempt` finite.
const MAX_ATTEMPT = 32;
// IK message 1's payload. The laptop ignores it (plan 3 change 7).
const IK_PAYLOAD = encodeMessage({});
const utf8Encoder = new TextEncoder();

export class LaptopConnection {
  #record;
  #keyPair;
  #cache;
  #openSocket;
  #onEvent;
  #absentGraceMs;
  #visibility;
  #runningBundle;
  #random;
  #clock;
  #url;
  #prologue;

  /** Every relay event, timer and `resume()`, one at a time and in arrival order. */
  #tasks;
  #started = false;
  /** No more work and no more events: set by `stop()`, a fatal and `replaced`. */
  #ended = false;
  /** @type {ConnectionState | null} */
  #state = null;

  /** @type {RelaySocket | null} */
  #socket = null;
  #socketOpen = false;
  /** @type {RelaySocket | null} The socket the last `resume()` opened. */
  #resumeSocket = null;
  /** When, on the clock, the last `resume()` opened `#resumeSocket`. */
  #resumedAt = 0;
  /** Whether any socket of this connection has opened. Until one has, a failure is `relayUnreachable`. */
  #everOpened = false;
  #gotSignal = false;
  /** The current socket's last signal was `peer-absent` or `peer-left`. */
  #peerAbsent = false;
  /**
   * Handshakes in a row that got no message 2 in time: the round so far. Message 2, `ready`,
   * `peer-absent`, `peer-left` and a `resume()` that replaces the socket end the round (0); a
   * `resume()` that only probes, or coalesces, leaves it as it is. While one lasts, a retry's
   * handshake and a retry socket that fails leave the state as it is, so the screen does not
   * flip from "Laptop offline" to connecting and back on every retry. Above HANDSHAKE_RETRIES
   * the round is over: no more retries, until one of those starts the next.
   */
  #unanswered = 0;
  #attempt = 0;
  #graceOver = false;

  /** @type {Session | null} */
  #session = null;
  /** @type {Timer | null} */
  #signalTimer = null;
  /** @type {Timer | null} */
  #reconnectTimer = null;
  /** @type {Timer | null} */
  #graceTimer = null;

  /**
   * @param {LaptopConnectionOptions} options
   * @throws {RangeError} for a record whose relay or room `relaySocketURL` refuses
   */
  constructor({
    record, keyPair, cache, openSocket, onEvent, absentGraceMs = 0, visibility = alwaysVisible,
    runningBundle = () => null, random = Math.random, clock = systemClock,
  }) {
    this.#record = record;
    this.#keyPair = keyPair;
    this.#cache = cache;
    this.#openSocket = openSocket;
    this.#onEvent = onEvent;
    this.#absentGraceMs = Number.isFinite(absentGraceMs) && absentGraceMs > 0 ? absentGraceMs : 0;
    this.#visibility = visibility;
    this.#runningBundle = runningBundle;
    this.#random = random;
    this.#clock = clock;
    // A ProtocolError (a message the laptop should never send) is `fatal('protocol')`, a
    // BundleError is `fatal('badBundle')`, and anything else unexpected is `fatal('protocol')`.
    this.#tasks = new TaskChain({
      isEnded: () => this.#ended,
      onError: (error) => {
        if (!this.#ended) this.#fail(error instanceof BundleError ? 'badBundle' : 'protocol');
      },
      visibility,
      clock,
    });
    // relaySocketURL checks the room, so the decode below has 32 bytes to work with.
    this.#url = relaySocketURL(record.relay, record.room);
    this.#prologue = phonePrologue(/** @type {Uint8Array} */ (base64urlDecode(record.room)));
  }

  /** Opens the first socket. Only the first call does anything. */
  start() {
    if (this.#started || this.#ended) return;
    this.#started = true;
    this.#setState('connecting');
    if (this.#absentGraceMs > 0) {
      this.#graceTimer = this.#tasks.armVisible(this.#absentGraceMs, () => {
        this.#graceTimer = null;
        this.#graceOver = true;
        // Only a wait with nothing under way turns offline here. A retry that is pending, or a
        // handshake in flight, may still be answered: it reads offline from its own outcome.
        if (this.#isWaiting()) this.#setState('offline');
      });
    } else {
      this.#graceOver = true;
    }
    this.#connect();
  }

  /**
   * The page became visible again, or was shown from the back-forward cache. An open socket
   * gets a liveness probe, and a dead one reconnects at once. Otherwise (a reconnect is
   * waiting, or a socket is still connecting, perhaps one frozen while the page was hidden)
   * a fresh socket replaces it at once and the backoff starts over.
   *
   * Calls that come close together coalesce: within RESUME_COALESCE_MS of the call that
   * opened a socket, while that socket is still connecting, another call does nothing, so the
   * two events one return to the page can fire open one socket, not two. (The probe already
   * runs one at a time.) Should that socket hang, the signal timeout still ends it. A later
   * call is a later return to the page, and replaces the socket at once like any other.
   *
   * A return to the page that replaces the socket also starts a fresh round of handshake
   * retries. A socket that waits after a round went unanswered gets no new `peer-joined`, so
   * it is replaced, and the new one handshakes at once. A probe, or a call that coalesces,
   * leaves a round in progress as it is: a retry socket that then fails, or is found dead,
   * still reads offline.
   */
  resume() {
    if (!this.#started) return;
    this.#tasks.enqueue(() => {
      // An open socket left waiting by an unanswered round, with no handshake under way.
      const afterRound = this.#roundOver() && this.#session === null;
      if (this.#socketOpen && !afterRound) {
        this.#socket?.probe();
        return;
      }
      const now = this.#clock.now();
      if (this.#socket !== null && this.#socket === this.#resumeSocket && isSoonAfter(this.#resumedAt, now, RESUME_COALESCE_MS)) return;
      this.#closeSocket();
      this.#reconnectTimer = this.#tasks.disarm(this.#reconnectTimer);
      this.#attempt = 0;
      this.#unanswered = 0;
      this.#connect();
      this.#resumeSocket = this.#socket;
      this.#resumedAt = now;
    });
  }

  /**
   * Sends an `app` message to the laptop. Sends keep their call order.
   * @param {Record<string, unknown>} body a plain object, sent unchanged
   * @returns {'sent' | 'offline' | 'tooLarge'} `offline` unless the state is `ready`;
   *   `tooLarge` when `{"type":"app","body"}` encodes to more than MAX_PLAINTEXT_LENGTH bytes
   * @throws {TypeError} for a body that is not a plain object, or that JSON cannot encode
   *   (a cycle or a BigInt)
   */
  sendApp(body) {
    if (!isPlainObject(body)) {
      throw new TypeError('an app body is a plain object');
    }
    const session = this.#session;
    if (this.#ended || this.#state !== 'ready' || session === null || !session.ready || session.transport === null) {
      return 'offline';
    }
    const plaintext = encodeMessage({ type: 'app', body });
    if (plaintext.length > MAX_PLAINTEXT_LENGTH) {
      return 'tooLarge';
    }
    // The transport encrypts in call order, so these callbacks run in call order too.
    session.transport.encrypt(plaintext).then((frame) => {
      if (this.#isCurrent(session)) session.socket.send(frame);
    }, () => {});
    return 'sent';
  }

  /** Closes the socket and cancels every timer. Nothing is reported afterwards. */
  stop() {
    this.#shutdown();
  }

  // --- sockets ----------------------------------------------------------------------------

  #connect() {
    const socket = new RelaySocket({
      url: this.#url,
      openSocket: this.#openSocket,
      onEvent: (event) => this.#tasks.enqueue(() => this.#onRelayEvent(socket, event)),
      visibility: this.#visibility,
      clock: this.#clock,
    });
    this.#socket = socket;
    this.#socketOpen = false;
    this.#gotSignal = false;
    this.#peerAbsent = false;
    // One bound for the WebSocket connecting and the first relay signal together: every phone
    // join gets a signal at once, so a socket without one by now is no use.
    this.#signalTimer = this.#tasks.armVisible(SIGNAL_TIMEOUT_MS, () => {
      this.#signalTimer = null;
      if (socket !== this.#socket || this.#gotSignal) return;
      this.#closeSocket();
      this.#setState(this.#lostState());
      this.#reconnectWithBackoff();
    });
    socket.open();
  }

  /**
   * @param {RelaySocket} socket
   * @param {RelayEvent} event
   */
  async #onRelayEvent(socket, event) {
    if (socket !== this.#socket) return;
    switch (event.kind) {
      case 'open':
        this.#socketOpen = true;
        this.#everOpened = true;
        return;
      case 'signal':
        this.#gotSignal = true;
        this.#signalTimer = this.#tasks.disarm(this.#signalTimer);
        if (event.name === 'peer-joined') {
          this.#peerAbsent = false;
          await this.#handshake(socket);
        } else {
          this.#endSession();
          this.#peerAbsent = true;
          this.#unanswered = 0;
          this.#setState(this.#awayState());
        }
        return;
      case 'frame':
        await this.#onFrame(event.bytes);
        return;
      case 'closed':
        this.#lostSocket();
        if (event.code === REPLACED) {
          // Another tab of this origin took the room. Reconnecting would knock it off in
          // turn, so this connection ends here.
          this.#setState('replaced');
          this.#shutdown();
          return;
        }
        this.#setState(this.#lostState());
        this.#reconnectWithBackoff();
        return;
      case 'dead':
        // A liveness failure, not a refusal, so it reconnects without waiting.
        this.#lostSocket();
        this.#setState(this.#lostState());
        this.#attempt = 0;
        this.#reconnectNow();
    }
  }

  /** Closes the current socket with 1000, if any, and forgets it. */
  #closeSocket() {
    const socket = this.#socket;
    this.#lostSocket();
    socket?.close();
  }

  /** Forgets the current socket and everything that hung on it. */
  #lostSocket() {
    this.#signalTimer = this.#tasks.disarm(this.#signalTimer);
    this.#endSession();
    this.#socket = null;
    this.#socketOpen = false;
    this.#gotSignal = false;
    this.#peerAbsent = false;
  }

  #reconnectWithBackoff() {
    const delay = reconnectDelay(this.#attempt, this.#random());
    this.#attempt = Math.min(this.#attempt + 1, MAX_ATTEMPT);
    this.#reconnectTimer = this.#tasks.arm(delay, () => {
      this.#reconnectTimer = null;
      this.#reconnectNow();
    });
  }

  /** Reconnects unless the page is hidden, in which case `resume()` reconnects. */
  #reconnectNow() {
    if (this.#socket !== null || !this.#visibility.isVisible()) return;
    this.#connect();
  }

  // --- the handshake and the loader protocol ---------------------------------------------

  /**
   * A new peer: whatever came before is over, and a fresh IK handshake starts.
   * @param {RelaySocket} socket
   */
  async #handshake(socket) {
    this.#endSession();
    /** @type {Session} */
    const session = {
      socket, initiator: null, transport: null, timer: null, cacheTimer: null, welcome: null, assembler: null, ready: false,
    };
    this.#session = session;
    if (this.#unanswered === 0) this.#setState('handshaking');
    const initiator = await createInitiator({
      pattern: 'IK',
      localStatic: this.#keyPair,
      remoteStatic: this.#record.laptopKey,
      psk: null,
      prologue: this.#prologue,
    });
    const message1 = await initiator.writeMessage1(IK_PAYLOAD);
    if (!this.#isCurrent(session)) return;
    session.initiator = initiator;
    socket.send(message1);
    session.timer = this.#tasks.armVisible(HANDSHAKE_TIMEOUT_MS, () => {
      if (!this.#isCurrent(session) || session.transport !== null) return;
      // No message 2. Plan 3 refuses an unknown key without a reply, so a phone removed while
      // it was away reads as offline. But message 1 or 2 may have been lost instead (a relay
      // hiccup, or a laptop still storing this phone's key right after `paired`), and the
      // laptop's socket stays where it is, so this socket would get no new peer-joined. A
      // fresh socket, after the backoff, does: the laptop resets on the peer-joined it causes,
      // and a fresh handshake runs.
      this.#unanswered = Math.min(this.#unanswered + 1, HANDSHAKE_RETRIES + 1);
      if (this.#roundOver()) {
        // The round went unanswered: a laptop that no longer knows this phone, which then
        // sees it as offline (spec section 2). This socket stays, and waits for the laptop's
        // next peer-joined.
        this.#endSession();
        this.#setState(this.#awayState());
        return;
      }
      this.#closeSocket();
      this.#setState(this.#awayState());
      this.#reconnectWithBackoff();
    });
  }

  /** @param {Uint8Array} bytes */
  async #onFrame(bytes) {
    const session = this.#session;
    if (session === null || session.initiator === null && session.transport === null) {
      return; // no handshake under way: nothing can use the frame
    }
    if (session.transport === null) {
      await this.#onMessage2(session, bytes);
      return;
    }
    let plaintext;
    try {
      plaintext = await session.transport.decrypt(bytes);
    } catch {
      if (!this.#isCurrent(session)) return;
      // A changed, repeated or reordered frame (spec section 2). The laptop resets on the
      // peer-left this causes, and the next connection runs a fresh handshake.
      this.#closeSocket();
      this.#setState('reconnecting');
      this.#reconnectWithBackoff();
      return;
    }
    if (!this.#isCurrent(session)) return;
    await this.#onMessage(session, parseLaptopMessage(decodeMessage(plaintext)));
  }

  /**
   * @param {Session} session
   * @param {Uint8Array} bytes
   */
  async #onMessage2(session, bytes) {
    const initiator = /** @type {NoiseInitiator} */ (session.initiator);
    let result;
    try {
      result = await initiator.readMessage2(bytes);
    } catch (error) {
      // A frame meant for a replaced peer can arrive before message 2. A failed read leaves
      // the initiator as it was, so drop the frame and wait for the next one.
      if (error instanceof NoiseError) return;
      throw error;
    }
    if (!this.#isCurrent(session)) return;
    session.timer = this.#tasks.disarm(session.timer);
    session.initiator = null;
    session.transport = result.transport;
    const laptopName = readLaptopName(result.payload);
    // The laptop answered: a retry after an unanswered handshake reads handshaking from here.
    this.#unanswered = 0;
    this.#setState('handshaking');
    this.#emit({ kind: 'connected', laptopName });
    // The laptop counts the phone as connected once this first transport message decrypts.
    await this.#send(session, makeHello());
    if (this.#isCurrent(session)) this.#awaitLaptop(session, WELCOME_TIMEOUT_MS);
  }

  /**
   * @param {Session} session
   * @param {LaptopMessage} message
   */
  async #onMessage(session, message) {
    switch (message.type) {
      case 'welcome':
        this.#onWelcome(session, message);
        return;
      case 'bundle.chunk':
        await this.#onChunk(session, message);
        return;
      case 'incompatible':
        this.#fail(message.tooOld === 'laptop' ? 'incompatibleLaptop' : 'incompatibleLoader');
        return;
      case 'revoked':
        this.#fail('revoked');
        return;
      case 'app':
        // Only once the bundle runs: the app subscribes after its channel comes up, so nothing
        // it asked for arrives earlier. Passed on unread and uncopied: a body can carry its
        // own `__proto__` key.
        if (this.#state === 'ready') this.#emit({ kind: 'app', body: message.body });
        return;
      default:
        // `paired` and `pairDenied` belong to pairing; an unknown type is for a newer loader.
    }
  }

  /**
   * A bundle the app frame already runs goes straight to `ready`. Otherwise the cache read
   * starts beside the chain, so a store that stalls holds up no signal, timer or `resume()`.
   * A read with no answer within CACHE_READ_TIMEOUT_MS is a miss, and an answer after that is
   * dropped.
   * @param {Session} session
   * @param {WelcomeMessage} welcome
   */
  #onWelcome(session, welcome) {
    if (session.welcome !== null) {
      throw new ProtocolError('welcome.repeated');
    }
    session.welcome = welcome;
    session.timer = this.#tasks.disarm(session.timer);
    if (checkCompat(welcome) === 'loaderTooOld') {
      this.#fail('incompatibleLoader');
      return;
    }
    const { sha256 } = welcome.bundle;
    if (this.#runningBundle() === sha256) {
      // The laptop still serves the bundle the app runs, which was checked against this hash
      // when it was loaded: the app goes on, and its channel comes back up.
      this.#markUsed(sha256);
      this.#ready(session);
      return;
    }
    session.cacheTimer = this.#tasks.arm(CACHE_READ_TIMEOUT_MS, () => this.#onCacheRow(session, welcome, null));
    this.#readCache(sha256).then((row) => this.#tasks.enqueue(() => this.#onCacheRow(session, welcome, row)));
  }

  /**
   * The store answered the cache read, or its time ran out first. The timer stops here, before
   * the row's hash is checked, so only the store read is timed.
   * @param {Session} session
   * @param {WelcomeMessage} welcome
   * @param {BundleRecord | null} row the stored row, or null for a miss or a timeout
   */
  async #onCacheRow(session, welcome, row) {
    if (!this.#isCurrent(session) || session.cacheTimer === null) return;
    session.cacheTimer = this.#tasks.disarm(session.cacheTimer);
    const { sha256 } = welcome.bundle;
    const text = row === null ? null : await verifiedText(row, sha256);
    if (!this.#isCurrent(session)) return;
    if (text !== null) {
      this.#markUsed(sha256);
      this.#bundleReady(session, sha256, text);
      return;
    }
    session.assembler = new BundleAssembler(welcome.bundle);
    // Only ever the hash `welcome` named: the laptop ends the connection for any other.
    await this.#send(session, { type: 'bundle.get', sha256 });
    if (!this.#isCurrent(session)) return;
    this.#setState('loading');
    this.#awaitLaptop(session, BUNDLE_CHUNK_TIMEOUT_MS);
  }

  /**
   * @param {Session} session
   * @param {ChunkMessage} chunk
   */
  async #onChunk(session, chunk) {
    const assembler = session.assembler;
    const welcome = session.welcome;
    if (assembler === null || welcome === null) {
      throw new ProtocolError('bundle.chunk.unasked');
    }
    if (!assembler.add(chunk)) {
      this.#awaitLaptop(session, BUNDLE_CHUNK_TIMEOUT_MS);
      return;
    }
    // The last chunk is in. Inflating and hashing are the phone's work, so they are not timed.
    session.timer = this.#tasks.disarm(session.timer);
    const text = await assembler.finish();
    if (!this.#isCurrent(session)) return;
    session.assembler = null;
    const { sha256, size } = welcome.bundle;
    settle(() => this.#cache.put({ laptopID: this.#record.id, sha256, text, size, usedAt: this.#clock.now() }));
    this.#bundleReady(session, sha256, text);
  }

  /**
   * @param {Session} session
   * @param {string} sha256
   * @param {string} text
   */
  #bundleReady(session, sha256, text) {
    this.#emit({ kind: 'bundle', sha256, text });
    this.#ready(session);
  }

  /** @param {Session} session */
  #ready(session) {
    session.ready = true;
    // Only a connection that got this far starts the backoff over, so one that keeps failing
    // after its handshake (a frame that will not decrypt, say) keeps backing off.
    this.#attempt = 0;
    this.#unanswered = 0;
    this.#setState('ready');
  }

  /**
   * Reads the cached row for `sha256` from the store, and nothing more. Never rejects.
   * @param {string} sha256
   * @returns {Promise<BundleRecord | null>} the row, or null for no row or a failed read
   */
  async #readCache(sha256) {
    try {
      return (await this.#cache.get(this.#record.id, sha256)) ?? null;
    } catch {
      // A cache that cannot be read is a miss.
      return null;
    }
  }

  /** @param {string} sha256 */
  #markUsed(sha256) {
    const at = this.#clock.now();
    settle(() => this.#cache.markUsed(this.#record.id, sha256, at));
  }

  /**
   * Encrypts and sends one loader message on the session's socket.
   * @param {Session} session
   * @param {object} message
   */
  async #send(session, message) {
    const frame = await /** @type {NoiseTransport} */ (session.transport).encrypt(encodeMessage(message));
    if (this.#isCurrent(session)) session.socket.send(frame);
  }

  /**
   * Starts, or starts over, the wait for the laptop's next message on a session past its
   * handshake. Only time while the page is visible counts. A laptop silent for `ms` is taken for
   * a dead link, as a lost socket is: the socket closes and a fresh one follows through the
   * backoff, and the laptop resets on the `peer-left` this causes. A download cut short this way
   * caches nothing, since only a finished bundle is stored.
   * @param {Session} session
   * @param {number} ms
   */
  #awaitLaptop(session, ms) {
    this.#tasks.disarm(session.timer);
    session.timer = this.#tasks.armVisible(ms, () => {
      if (!this.#isCurrent(session)) return;
      this.#closeSocket();
      this.#setState(this.#lostState());
      this.#reconnectWithBackoff();
    });
  }

  /** @param {Session} session */
  #isCurrent(session) {
    return !this.#ended && this.#session === session;
  }

  #endSession() {
    const session = this.#session;
    if (session === null) return;
    session.timer = this.#tasks.disarm(session.timer);
    session.cacheTimer = this.#tasks.disarm(session.cacheTimer);
    this.#session = null;
  }

  // --- ending -------------------------------------------------------------------------------

  /**
   * Closes with 1000 and never reconnects.
   * @param {FatalReason} reason
   */
  #fail(reason) {
    this.#emit({ kind: 'fatal', reason });
    this.#shutdown();
  }

  #shutdown() {
    this.#ended = true;
    this.#closeSocket();
    this.#reconnectTimer = this.#tasks.disarm(this.#reconnectTimer);
    this.#graceTimer = this.#tasks.disarm(this.#graceTimer);
  }

  // --- plumbing -----------------------------------------------------------------------------

  /**
   * What a laptop that is away, or does not answer, reads as: `offline`, or `connecting` while
   * the post-pairing grace lasts.
   * @returns {ConnectionState}
   */
  #awayState() {
    return this.#graceOver ? 'offline' : 'connecting';
  }

  /**
   * What a socket that closed, died or got no signal leaves the state at: `relayUnreachable`
   * until any socket has opened, then `reconnecting`. While a round of unanswered handshakes
   * lasts it is the away state instead: the laptop is no nearer for a retry socket failing.
   * @returns {ConnectionState}
   */
  #lostState() {
    if (!this.#everOpened) return 'relayUnreachable';
    return this.#unanswered > 0 ? this.#awayState() : 'reconnecting';
  }

  /** The round of unanswered handshakes is over: no retry follows until a new round starts. */
  #roundOver() {
    return this.#unanswered > HANDSHAKE_RETRIES;
  }

  /**
   * The connection sits on an open socket with nothing under way: the laptop is away, or a
   * round of handshakes went unanswered. Only the laptop's next signal changes anything.
   */
  #isWaiting() {
    return this.#socket !== null && this.#session === null && (this.#peerAbsent || this.#roundOver());
  }

  /** @param {ConnectionState} state */
  #setState(state) {
    if (state === this.#state) return;
    this.#state = state;
    this.#emit({ kind: 'state', state });
  }

  /** @param {ConnectionEvent} event */
  #emit(event) {
    // Also covers a handler that calls stop() while one handler is still emitting.
    if (this.#ended) return;
    try {
      this.#onEvent(event);
    } catch (error) {
      // The caller's handler failed; report it without letting it break the connection.
      queueMicrotask(() => {
        throw error;
      });
    }
  }
}

/**
 * A cached row's text, once it is checked to still hash to its name. Never rejects.
 * @param {unknown} row
 * @param {string} sha256
 * @returns {Promise<string | null>} the text, or null for a row that is not a bundle or whose
 *   text is damaged (the fetch that follows replaces it)
 */
async function verifiedText(row, sha256) {
  if (!isObject(row)) return null;
  const { text, sha256: name } = row;
  if (typeof text !== 'string' || name !== sha256) return null;
  try {
    return await sha256Hex(utf8Encoder.encode(text)) === sha256 ? text : null;
  } catch {
    return null;
  }
}

/**
 * Starts a cache write whose outcome does not matter: a refused or failed write is never fatal.
 * @param {() => Promise<unknown>} write
 */
function settle(write) {
  try {
    Promise.resolve(write()).catch(() => {});
  } catch {
    // A cache that throws instead of rejecting is ignored the same way.
  }
}
