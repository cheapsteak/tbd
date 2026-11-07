// The phone's side of pairing (spec section 2): the IKpsk2 handshake on the pairing link's
// room, the confirmation code, `hello`, and the wait for the user's Allow on the laptop.
//
// Order of events, as plan 3's laptop runs them:
// 1. The phone makes its key for this laptop (wrapped, as keys.js stores it), then joins the
//    pairing room. It sends message 1, carrying `{"deviceName"}`, only on `peer-joined`.
// 2. Message 2 carries `{"laptopName"}`. The phone shows the code and at once sends `hello`.
//    The laptop shows its Allow prompt only once that `hello` decrypts; with a wrong pairing
//    secret the phone cannot read message 2 at all, so it waits out the handshake timeout.
// 3. The laptop answers `paired` with a new room, the device's permanent room, or
//    `pairDenied`. Then it leaves the pairing room for good.
//
// Ordering. As in connection.js, every relay event and every timer runs through one promise
// chain, one at a time and in arrival order: decrypting is asynchronous, and the `peer-left`
// that follows `paired` must wait until that frame is handled. Once pairing has an outcome
// nothing more runs or is reported, and each task checks for that after every await.

import { confirmationCode } from './channel/confirm.js';
import { NoiseError, createInitiator, phonePrologue } from './channel/noise.js';
import { systemClock } from './clock.js';
import { HANDSHAKE_TIMEOUT_MS, PAIRING_EXPIRY_GRACE_MS, SIGNAL_TIMEOUT_MS } from './constants.js';
import { createWrappedPhoneKey } from './keys.js';
import { relaySocketURL } from './links.js';
import {
  ProtocolError, decodeMessage, encodeMessage, makeHello, parseLaptopMessage, readLaptopName,
} from './protocol.js';
import { RelaySocket } from './relay.js';
import { laptopIDFromKey } from './store.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./links.js').PairingLinkData} PairingLinkData */
/** @typedef {import('./types.js').WebSocketLike} WebSocketLike */
/** @typedef {import('./relay.js').RelayEvent} RelayEvent */
/** @typedef {import('./relay.js').RelaySignal} RelaySignal */
/** @typedef {import('./channel/noise.js').NoiseInitiator} NoiseInitiator */
/** @typedef {import('./channel/noise.js').NoiseTransport} NoiseTransport */

/**
 * Why pairing ended without a device:
 * - `denied`: the user chose Deny on the laptop.
 * - `expired`: the laptop said the offer expired, or the link's `exp` plus
 *   PAIRING_EXPIRY_GRACE_MS passed on this phone's clock before pairing ended.
 * - `invalid`: the link could not be used, the laptop never answered message 1 (a used or
 *   unknown offer, or a wrong secret), its answers broke the protocol, it left or changed its
 *   socket after message 2, or another phone socket took the pairing room.
 * - `offline`: the laptop is not in the pairing room, left it before answering, or no relay
 *   signal came.
 * - `relayUnreachable`: the socket never opened, or the relay connection ended before
 *   message 2 for any reason other than another phone socket taking the room.
 * - `cancelled`: `cancel()`.
 * @typedef {'denied' | 'expired' | 'invalid' | 'offline' | 'relayUnreachable' | 'cancelled'} PairingFailure
 */

/**
 * A paired laptop, ready to store. `room` is the device's permanent room from `paired`, never
 * the pairing link's room. `publicRaw` is the record's `phoneKey`, and `wrapKey`,
 * `wrappedKey` and `wrapIV` are its key fields, wrapped for `laptopIDFromKey(link.laptopKey)`.
 * `pair` is rebuilt from that wrap: its private key is not extractable.
 * @typedef {object} PairingResult
 * @property {string} laptopName From message 2.
 * @property {string} room
 * @property {CryptoKey} wrapKey
 * @property {Uint8Array} publicRaw
 * @property {Uint8Array} wrappedKey
 * @property {Uint8Array} wrapIV
 * @property {CryptoKeyPair} pair
 */

/**
 * @typedef {object} PairingOptions
 * @property {PairingLinkData} link From `readPairingLink`.
 * @property {string} deviceName Already through `normalizeDeviceName`.
 * @property {(url: string) => WebSocketLike} openSocket
 * @property {(code: string) => void} onCode Called once, with the 6-digit code, when message 2
 *   has been read; never after pairing has ended.
 * @property {SubtleCrypto} [subtle] For the phone's key. Default `crypto.subtle`.
 * @property {Clock} [clock]
 */

/**
 * A pairing under way. `probe()` checks the socket when the page returns from the background,
 * as RelaySocket's `probe()` does; it does nothing while no socket is open, and a socket
 * found dead ends pairing as any lost connection does.
 * @typedef {{ result: Promise<PairingResult>, cancel(): void, probe(): void }} PairingRun
 */

/**
 * One timer, armed through the clock. When it fires, its work is queued on the chain, and
 * `cancelled` stops work that was queued but has not run yet.
 * @typedef {{ id: unknown, cancelled: boolean }} Timer
 */

/** @typedef {Awaited<ReturnType<typeof createWrappedPhoneKey>>} PhoneKey */

// Browsers run a longer timeout at once, so a far-off deadline is waited for in steps.
const MAX_TIMER_MS = 2_147_483_647;
// The relay's close code for a socket another socket of the same role displaced.
const REPLACED = 4000;

export class PairingError extends Error {
  /**
   * @param {PairingFailure} reason
   * @param {unknown} [cause] what went wrong, for an unexpected failure
   */
  constructor(reason, cause) {
    super(`pairing failed: ${reason}`, cause === undefined ? undefined : { cause });
    this.name = 'PairingError';
    /** @readonly */
    this.reason = reason;
  }
}

/**
 * Pairs this phone with the laptop that made `link`.
 *
 * `result` resolves once the laptop sends `paired`, and rejects with a PairingError otherwise.
 * Anything unexpected rejects `invalid` with the error as its `cause`: a link the loader cannot
 * use (a relay or room `relaySocketURL` refuses, a room or laptop key that is not 32 bytes),
 * which is reported this way rather than thrown, or Web Crypto refusing to make a key. On every
 * outcome the socket closes with 1000 and every timer stops; after `paired` nothing more is
 * sent (plan 3 change 4). `cancel()` rejects `cancelled`, and does nothing once there is an
 * outcome.
 * @param {PairingOptions} options
 * @returns {PairingRun}
 */
export function startPairing(options) {
  /** @type {Pairing} */
  let pairing;
  try {
    pairing = new Pairing(options);
  } catch (error) {
    const result = Promise.reject(new PairingError('invalid', error));
    // Marked handled, so it is not reported as unhandled before the caller attaches its own.
    result.catch(() => {});
    return { result, cancel() {}, probe() {} };
  }
  pairing.start();
  return { result: pairing.result, cancel: () => pairing.cancel(), probe: () => pairing.probe() };
}

class Pairing {
  #link;
  #deviceName;
  #openSocket;
  #onCode;
  #subtle;
  #clock;
  #url;
  #prologue;
  #laptopID;
  /** When this phone stops pairing: `exp`, plus the clock grace, in milliseconds. */
  #deadline;

  /** @type {Promise<PairingResult>} */
  result;
  /** @type {(value: PairingResult) => void} */
  #resolve = () => {};
  /** @type {(error: PairingError) => void} */
  #reject = () => {};

  /** @type {Promise<void>} */
  #chain = Promise.resolve();
  #ended = false;
  /** @type {PhoneKey | null} */
  #key = null;
  /** @type {RelaySocket | null} */
  #socket = null;
  #opened = false;
  #gotSignal = false;
  /** @type {NoiseInitiator | null} Set once message 1 is out, until message 2. */
  #initiator = null;
  /** @type {NoiseTransport | null} Set by message 2. */
  #transport = null;
  #laptopName = '';

  /** @type {Timer | null} */
  #signalTimer = null;
  /** @type {Timer | null} */
  #handshakeTimer = null;
  /** @type {Timer | null} */
  #expiryTimer = null;

  /** @param {PairingOptions} options */
  constructor({ link, deviceName, openSocket, onCode, subtle = globalThis.crypto.subtle, clock = systemClock }) {
    this.#link = link;
    this.#deviceName = deviceName;
    this.#openSocket = openSocket;
    this.#onCode = onCode;
    this.#subtle = subtle;
    this.#clock = clock;
    this.#url = relaySocketURL(link.fields.relay, link.fields.room);
    this.#prologue = phonePrologue(link.room);
    this.#laptopID = laptopIDFromKey(link.laptopKey);
    this.#deadline = link.fields.exp * 1000 + PAIRING_EXPIRY_GRACE_MS;
    this.result = new Promise((resolve, reject) => {
      this.#resolve = resolve;
      this.#reject = reject;
    });
  }

  start() {
    // The whole pairing, not only the wait for Allow: a laptop socket that keeps rejoining
    // restarts the handshake each time, and must not keep pairing alive past the offer.
    this.#armExpiry();
    this.#enqueue(async () => {
      // Before the socket opens: the extractable private key exists only inside this call,
      // and the pair used for the handshake is rebuilt from the wrap that will be stored.
      const key = await createWrappedPhoneKey(this.#subtle, this.#laptopID);
      if (this.#ended) return;
      this.#key = key;
      this.#connect();
    });
  }

  cancel() {
    this.#fail('cancelled');
  }

  probe() {
    if (!this.#ended) this.#socket?.probe();
  }

  #connect() {
    const socket = new RelaySocket({
      url: this.#url,
      openSocket: this.#openSocket,
      onEvent: (event) => this.#enqueue(() => this.#onRelayEvent(event)),
      clock: this.#clock,
    });
    this.#socket = socket;
    // One bound for the WebSocket connecting and the first relay signal together.
    this.#signalTimer = this.#arm(SIGNAL_TIMEOUT_MS, () => {
      this.#signalTimer = null;
      if (!this.#gotSignal) this.#fail(this.#opened ? 'offline' : 'relayUnreachable');
    });
    socket.open();
  }

  /** @param {RelayEvent} event */
  async #onRelayEvent(event) {
    switch (event.kind) {
      case 'open':
        this.#opened = true;
        return;
      case 'signal':
        await this.#onSignal(event.name);
        return;
      case 'frame':
        await this.#onFrame(event.bytes);
        return;
      case 'closed':
      case 'dead':
        if (event.kind === 'closed' && event.code === REPLACED) {
          // Another phone socket joined the pairing room: someone else who saw the QR code,
          // or this page in a second tab. The relay is reachable, but this attempt is over,
          // and joining again would knock the other socket off in turn.
          this.#fail('invalid');
          return;
        }
        // Before message 2 the relay connection failed. After it, either the laptop's offer
        // ended or its answer can no longer arrive.
        this.#fail(this.#transport === null ? 'relayUnreachable' : 'invalid');
    }
  }

  /** @param {RelaySignal} name */
  async #onSignal(name) {
    this.#gotSignal = true;
    this.#signalTimer = this.#disarm(this.#signalTimer);
    if (this.#transport !== null) {
      // The laptop's pairing socket left or was replaced, so this session is over there.
      this.#fail('invalid');
      return;
    }
    if (name === 'peer-joined') {
      // A new laptop socket: any message 1 sent before went to the old one.
      await this.#sendMessage1();
      return;
    }
    // The laptop is not in the room, or left before answering: its offer is gone, or the
    // laptop is asleep.
    this.#fail('offline');
  }

  async #sendMessage1() {
    this.#handshakeTimer = this.#disarm(this.#handshakeTimer);
    this.#initiator = null;
    const key = /** @type {PhoneKey} */ (this.#key);
    const initiator = await createInitiator({
      pattern: 'IKpsk2',
      localStatic: key.pair,
      remoteStatic: this.#link.laptopKey,
      psk: this.#link.secret,
      prologue: this.#prologue,
    });
    const message1 = await initiator.writeMessage1(encodeMessage({ deviceName: this.#deviceName }));
    if (this.#ended) return;
    this.#initiator = initiator;
    /** @type {RelaySocket} */ (this.#socket).send(message1);
    this.#handshakeTimer = this.#arm(HANDSHAKE_TIMEOUT_MS, () => {
      this.#handshakeTimer = null;
      // Plan 3 refuses a used or unknown offer without a reply, and under a wrong secret
      // message 2 cannot be read.
      this.#fail('invalid');
    });
  }

  /** @param {Uint8Array} bytes */
  async #onFrame(bytes) {
    if (this.#transport !== null) {
      await this.#onMessage(this.#transport, bytes);
      return;
    }
    const initiator = this.#initiator;
    if (initiator === null) return; // no message 1 out: nothing can use the frame
    let handshake;
    try {
      handshake = await initiator.readMessage2(bytes);
    } catch (error) {
      // A frame meant for a replaced peer can arrive before message 2. A failed read leaves
      // the initiator as it was, so drop the frame and wait for the next one.
      if (error instanceof NoiseError) return;
      throw error;
    }
    if (this.#ended) return;
    this.#handshakeTimer = this.#disarm(this.#handshakeTimer);
    this.#initiator = null;
    this.#transport = handshake.transport;
    this.#laptopName = readLaptopName(handshake.payload);
    const code = await confirmationCode(handshake.handshakeHash);
    if (this.#ended) return;
    this.#showCode(code);
    // The laptop shows its Allow prompt once this first transport message decrypts.
    await this.#send(handshake.transport, makeHello());
  }

  /**
   * After message 2 only `paired` and `pairDenied` matter. A frame that fails to decrypt or a
   * message that breaks the protocol throws, which the chain turns into `invalid`.
   * @param {NoiseTransport} transport
   * @param {Uint8Array} bytes
   */
  async #onMessage(transport, bytes) {
    const plaintext = await transport.decrypt(bytes);
    if (this.#ended) return;
    const message = parseLaptopMessage(decodeMessage(plaintext));
    switch (message.type) {
      case 'paired': {
        // The laptop must rotate the room: anyone who saw the QR code knows the old one.
        if (message.room === this.#link.fields.room) {
          throw new ProtocolError('paired.room');
        }
        const { wrapKey, publicRaw, wrappedKey, wrapIV, pair } = /** @type {PhoneKey} */ (this.#key);
        this.#succeed({ laptopName: this.#laptopName, room: message.room, wrapKey, publicRaw, wrappedKey, wrapIV, pair });
        return;
      }
      case 'pairDenied':
        this.#fail(message.reason);
        return;
      default:
        // Plan 3 sends nothing else while pairing.
    }
  }

  /**
   * Encrypts and sends one loader message.
   * @param {NoiseTransport} transport
   * @param {object} message
   */
  async #send(transport, message) {
    const frame = await transport.encrypt(encodeMessage(message));
    if (!this.#ended) this.#socket?.send(frame);
  }

  /** Waits for the deadline, in steps of at most MAX_TIMER_MS. */
  #armExpiry() {
    const wait = Math.min(Math.max(0, this.#deadline - this.#clock.now()), MAX_TIMER_MS);
    this.#expiryTimer = this.#arm(wait, () => {
      this.#expiryTimer = null;
      if (this.#clock.now() >= this.#deadline) {
        this.#fail('expired');
      } else {
        this.#armExpiry();
      }
    });
  }

  /** @param {string} code */
  #showCode(code) {
    try {
      this.#onCode(code);
    } catch (error) {
      // The caller's handler failed; report it without letting it break pairing.
      queueMicrotask(() => {
        throw error;
      });
    }
  }

  // --- ending -------------------------------------------------------------------------------

  /** @param {PairingResult} result */
  #succeed(result) {
    if (this.#ended) return;
    this.#end();
    this.#resolve(result);
  }

  /**
   * @param {PairingFailure} reason
   * @param {unknown} [cause]
   */
  #fail(reason, cause) {
    if (this.#ended) return;
    this.#end();
    this.#reject(new PairingError(reason, cause));
  }

  /** Closes the socket with 1000 and stops every timer. */
  #end() {
    this.#ended = true;
    this.#signalTimer = this.#disarm(this.#signalTimer);
    this.#handshakeTimer = this.#disarm(this.#handshakeTimer);
    this.#expiryTimer = this.#disarm(this.#expiryTimer);
    this.#initiator = null;
    this.#transport = null;
    const socket = this.#socket;
    this.#socket = null;
    socket?.close();
  }

  // --- plumbing -----------------------------------------------------------------------------

  /**
   * Runs `task` after every task queued before it, unless pairing has ended by then. Anything
   * it throws ends pairing with `invalid`.
   * @param {() => void | Promise<void>} task
   */
  #enqueue(task) {
    this.#chain = this.#chain.then(async () => {
      if (this.#ended) return;
      try {
        await task();
      } catch (error) {
        this.#fail('invalid', error);
      }
    });
  }

  /**
   * @param {number} ms
   * @param {() => void | Promise<void>} fn runs on the chain
   * @returns {Timer}
   */
  #arm(ms, fn) {
    /** @type {Timer} */
    const timer = { id: null, cancelled: false };
    timer.id = this.#clock.setTimeout(() => {
      timer.id = null;
      this.#enqueue(() => (timer.cancelled ? undefined : fn()));
    }, ms);
    return timer;
  }

  /**
   * @param {Timer | null} timer
   * @returns {null}
   */
  #disarm(timer) {
    if (timer !== null) {
      timer.cancelled = true;
      if (timer.id !== null) this.#clock.clearTimeout(timer.id);
    }
    return null;
  }
}
