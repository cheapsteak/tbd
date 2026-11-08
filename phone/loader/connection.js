// The connection to one paired laptop: the relay socket, the IK handshake, the loader
// protocol and the bundle download, with reconnects (spec sections 2, 3 and 4.3).
//
// Ordering. Every relay event (signal, frame, close, dead socket), every timer and every
// `resume()` runs through one promise chain, one at a time and in arrival order. Decrypting is
// asynchronous, so a `peer-left` right behind a frame waits until that frame is handled.
// Within one chain task only `stop()` can change what is current, and each task checks for it
// after every await. The bundle cache read is the one wait kept off the chain: IndexedDB can
// stall, so the read runs beside it, and its answer or its timeout comes back as a task.
//
// Sessions. Each `peer-joined` starts a new session: a fresh initiator, and later its
// transport, welcome and bundle assembly. Anything an older session started that finishes
// late (an encrypted send, say) sees that its session is no longer current and is dropped.

import { NoiseError, createInitiator, phonePrologue, MAX_PLAINTEXT_LENGTH } from './channel/noise.js';
import { base64urlDecode } from './channel/pairingLink.js';
import { BundleAssembler, BundleError, sha256Hex } from './bundle.js';
import { TaskChain } from './chain.js';
import { systemClock } from './clock.js';
import { CACHE_READ_TIMEOUT_MS, HANDSHAKE_TIMEOUT_MS, RESUME_COALESCE_MS, SIGNAL_TIMEOUT_MS } from './constants.js';
import { relaySocketURL } from './links.js';
import {
  ProtocolError, checkCompat, decodeMessage, encodeMessage, makeHello, parseLaptopMessage, readLaptopName,
} from './protocol.js';
import { RelaySocket, reconnectDelay } from './relay.js';

/** @typedef {import('./clock.js').Clock} Clock */
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
 * `app` is reported only while the state is `ready`.
 * @typedef {{ kind: 'state', state: ConnectionState }
 *   | { kind: 'connected', laptopName: string }
 *   | { kind: 'bundle', sha256: string, text: string }
 *   | { kind: 'app', body: Record<string, unknown> }
 *   | { kind: 'fatal', reason: FatalReason }} ConnectionEvent
 */

/**
 * The bundle cache, as `main.js` adapts the store to it. `get` may resolve null or undefined
 * for a miss, or reject (read as a miss). A `get` that has not answered within
 * CACHE_READ_TIMEOUT_MS is a miss too, and so is a row whose text does not hash to its name.
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
 * @property {number} [absentGraceMs] For this long after `start()`, `peer-absent` and
 *   `peer-left` read `connecting` rather than `offline`. Default 0; `main.js` passes
 *   SIGNAL_TIMEOUT_MS right after pairing, while the laptop's device link joins the new room.
 * @property {() => boolean} [isVisible] Default `() => true`. While it is false, a reconnect
 *   waits for `resume()`.
 * @property {() => number} [random] In [0, 1), for the backoff jitter. Default Math.random.
 * @property {Clock} [clock]
 */

/**
 * One handshake on one socket, and what follows it.
 * @typedef {object} Session
 * @property {RelaySocket} socket
 * @property {NoiseInitiator | null} initiator Set once message 1 is out, until message 2.
 * @property {NoiseTransport | null} transport Set by message 2.
 * @property {Timer | null} timer The handshake timeout.
 * @property {Timer | null} cacheTimer Armed while the bundle cache is read; null before the
 *   read, and again once it has answered or timed out.
 * @property {WelcomeMessage | null} welcome
 * @property {BundleAssembler | null} assembler While a `bundle.get` is being answered.
 * @property {boolean} ready
 */

const REPLACED = 4000;
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
  #isVisible;
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
    record, keyPair, cache, openSocket, onEvent, absentGraceMs = 0, isVisible = () => true,
    random = Math.random, clock = systemClock,
  }) {
    this.#record = record;
    this.#keyPair = keyPair;
    this.#cache = cache;
    this.#openSocket = openSocket;
    this.#onEvent = onEvent;
    this.#absentGraceMs = Number.isFinite(absentGraceMs) && absentGraceMs > 0 ? absentGraceMs : 0;
    this.#isVisible = isVisible;
    this.#random = random;
    this.#clock = clock;
    // A ProtocolError (a message the laptop should never send) is `fatal('protocol')`, a
    // BundleError is `fatal('badBundle')`, and anything else unexpected is `fatal('protocol')`.
    this.#tasks = new TaskChain({
      isEnded: () => this.#ended,
      onError: (error) => {
        if (!this.#ended) this.#fail(error instanceof BundleError ? 'badBundle' : 'protocol');
      },
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
      this.#graceTimer = this.#tasks.arm(this.#absentGraceMs, () => {
        this.#graceTimer = null;
        this.#graceOver = true;
        if (this.#socket !== null && this.#peerAbsent) this.#setState('offline');
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
   */
  resume() {
    if (!this.#started) return;
    this.#tasks.enqueue(() => {
      if (this.#socketOpen) {
        this.#socket?.probe();
        return;
      }
      const now = this.#clock.now();
      if (this.#socket !== null && this.#socket === this.#resumeSocket && isSoonAfter(this.#resumedAt, now)) return;
      this.#closeSocket();
      this.#reconnectTimer = this.#tasks.disarm(this.#reconnectTimer);
      this.#attempt = 0;
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
    if (body === null || typeof body !== 'object' || Array.isArray(body)) {
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
      clock: this.#clock,
    });
    this.#socket = socket;
    this.#socketOpen = false;
    this.#gotSignal = false;
    this.#peerAbsent = false;
    // One bound for the WebSocket connecting and the first relay signal together: every phone
    // join gets a signal at once, so a socket without one by now is no use.
    this.#signalTimer = this.#tasks.arm(SIGNAL_TIMEOUT_MS, () => {
      this.#signalTimer = null;
      if (socket !== this.#socket || this.#gotSignal) return;
      this.#closeSocket();
      this.#setState(this.#everOpened ? 'reconnecting' : 'relayUnreachable');
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
          this.#setState(this.#graceOver ? 'offline' : 'connecting');
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
        this.#setState(this.#everOpened ? 'reconnecting' : 'relayUnreachable');
        this.#reconnectWithBackoff();
        return;
      case 'dead':
        // A liveness failure, not a refusal, so it reconnects without waiting.
        this.#lostSocket();
        this.#setState('reconnecting');
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
    if (this.#socket !== null || !this.#isVisible()) return;
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
    this.#setState('handshaking');
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
    session.timer = this.#tasks.arm(HANDSHAKE_TIMEOUT_MS, () => {
      if (!this.#isCurrent(session) || session.transport !== null) return;
      // Plan 3 refuses an unknown key without a reply, so a phone removed while it was away
      // reads as offline. The socket stays open for the next peer-joined.
      this.#endSession();
      this.#setState('offline');
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
    this.#emit({ kind: 'connected', laptopName });
    // The laptop counts the phone as connected once this first transport message decrypts.
    await this.#send(session, makeHello());
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
   * Starts the cache read beside the chain, so a store that stalls holds up no signal, timer
   * or `resume()`. A read with no answer within CACHE_READ_TIMEOUT_MS is a miss, and an answer
   * after that is dropped.
   * @param {Session} session
   * @param {WelcomeMessage} welcome
   */
  #onWelcome(session, welcome) {
    if (session.welcome !== null) {
      throw new ProtocolError('welcome.repeated');
    }
    session.welcome = welcome;
    if (checkCompat(welcome) === 'loaderTooOld') {
      this.#fail('incompatibleLoader');
      return;
    }
    session.cacheTimer = this.#tasks.arm(CACHE_READ_TIMEOUT_MS, () => this.#onCacheRead(session, welcome, null));
    this.#readCache(welcome.bundle.sha256)
      .then((text) => this.#tasks.enqueue(() => this.#onCacheRead(session, welcome, text)));
  }

  /**
   * The cache read answered or timed out, whichever came first.
   * @param {Session} session
   * @param {WelcomeMessage} welcome
   * @param {string | null} text the cached bundle, or null for a miss
   */
  async #onCacheRead(session, welcome, text) {
    if (!this.#isCurrent(session) || session.cacheTimer === null) return;
    session.cacheTimer = this.#tasks.disarm(session.cacheTimer);
    const { sha256 } = welcome.bundle;
    if (text !== null) {
      const at = this.#clock.now();
      settle(() => this.#cache.markUsed(this.#record.id, sha256, at));
      this.#bundleReady(session, sha256, text);
      return;
    }
    session.assembler = new BundleAssembler(welcome.bundle);
    // Only ever the hash `welcome` named: the laptop ends the connection for any other.
    await this.#send(session, { type: 'bundle.get', sha256 });
    if (!this.#isCurrent(session)) return;
    this.#setState('loading');
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
    if (!assembler.add(chunk)) return;
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
    session.ready = true;
    // Only a connection that got this far starts the backoff over, so one that keeps failing
    // after its handshake (a frame that will not decrypt, say) keeps backing off.
    this.#attempt = 0;
    this.#emit({ kind: 'bundle', sha256, text });
    this.#setState('ready');
  }

  /**
   * Reads the cached bundle and checks its text still hashes to its name. Never rejects.
   * @param {string} sha256
   * @returns {Promise<string | null>} the bundle text, or null for a miss: no row, a failed
   *   read, or a row whose text is damaged (the fetch that follows replaces it)
   */
  async #readCache(sha256) {
    try {
      const record = await this.#cache.get(this.#record.id, sha256);
      if (record == null || typeof record.text !== 'string' || record.sha256 !== sha256) {
        return null;
      }
      return await sha256Hex(utf8Encoder.encode(record.text)) === sha256 ? record.text : null;
    } catch {
      // A cache that cannot be read is a miss.
      return null;
    }
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

/**
 * Whether `now` is within RESUME_COALESCE_MS after `then`, on the same clock. A clock that
 * went back reads as not soon, so the resume replaces the socket, as it would without coalescing.
 * @param {number} then
 * @param {number} now
 */
function isSoonAfter(then, now) {
  const elapsed = now - then;
  return elapsed >= 0 && elapsed < RESUME_COALESCE_MS;
}
