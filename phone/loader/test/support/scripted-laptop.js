// A scripted stand-in for the laptop (plan 3's PairingService, RelayLink and LoaderHandler)
// that joins a fake relay in process as role=laptop. Its rules mirror plan 3:
//
// Pairing room (an offer):
// - Each frame is read as message 1 by a fresh IKpsk2 responder. A failed read, or a device
//   name that is empty after trimming, longer than 64 characters or holding a Cc or Cf
//   scalar, gets no reply and the offer stays open (counts.refused). A stale frame is
//   therefore dropped and the offer keeps waiting.
// - Otherwise it sends message 2 with {"laptopName"} and sets lastCode. That handshake
//   consumes the offer. The laptop then waits for the phone's first transport message
//   (its `hello`). If that fails to decrypt, or a peer-joined or peer-left comes first, the
//   offer ends and the laptop leaves.
// - Once the first transport message decrypts it acts on the decision: `allow` sends
//   {"type":"paired","room":<fresh room>}, stores the device under the new room, leaves the
//   pairing room for good and joins the new room as the device link; `deny` and `expire`
//   send pairDenied and leave; `silent` sends nothing.
//
// Device room (a device link):
// - peer-joined or peer-left resets the channel to awaiting a handshake.
// - While awaiting, each frame goes to a fresh IK responder, and the laptop answers only
//   when the read succeeds and the phone's key is the one stored for this room; otherwise
//   it stays silent (counts.refused). Message 1's payload is ignored.
// - Once the handshake is done, a frame that fails to decrypt ends the channel: the laptop
//   leaves and rejoins the room (counts.rejoins). So does a first message other than
//   `hello`, an undecodable message, and a `bundle.get` for a hash other than the one
//   `welcome` named.
// - `hello` gets `welcome`, or `incompatible` followed by leaving and rejoining.
//
// Every frame and signal for a room is handled in arrival order through one promise chain.

import { createHash, randomBytes } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

import { base64urlDecode, base64urlEncode } from '../../channel/pairingLink.js';
import { confirmationCode } from '../../channel/confirm.js';
import { phonePrologue } from '../../channel/noise.js';
import { systemClock } from '../../clock.js';
import { DEVICE_NAME_MAX, MAX_CHUNK_BYTES } from '../../constants.js';
import { createResponder } from './noise-responder.js';
import { generatePair, importPair } from './x25519.js';

/** @typedef {import('./fake-relay.js').FakeRelay} FakeRelay */
/** @typedef {import('./fake-relay.js').RelayHandle} RelayHandle */
/** @typedef {import('./x25519.js').KeyPairWithRaw} KeyPairWithRaw */
/** @typedef {import('../../channel/noise.js').NoiseTransport} NoiseTransport */
/** @typedef {import('../../clock.js').Clock} Clock */

/** @typedef {'allow' | 'deny' | 'expire' | 'silent'} Decision */

/**
 * @typedef {object} Offer
 * @property {Uint8Array} secret
 * @property {Decision} decision
 * @property {string | undefined} pairedRoom When a string, `paired` carries it verbatim and the
 *   laptop joins nothing.
 * @property {Uint8Array | null} phoneKey Set by the handshake.
 * @property {string | null} deviceName Set by the handshake, trimmed.
 */

/**
 * @typedef {object} Bundle
 * @property {string} text
 * @property {string} sha256 Lowercase hex SHA-256 of the UTF-8 text.
 * @property {Uint8Array} compressed Raw deflate of the UTF-8 text.
 */

/**
 * One joined room.
 * @typedef {object} Link
 * @property {string} room
 * @property {'offer' | 'device'} kind
 * @property {Offer | null} offer
 * @property {Uint8Array} prologue
 * @property {RelayHandle | null} handle
 * @property {Promise<void>} chain
 * @property {boolean} closed
 * @property {number} signals Signals that have arrived, counted on arrival rather than when
 *   handled, so a bundle transfer stops as soon as its phone leaves.
 * @property {'waiting' | 'bound' | 'silent' | 'awaiting' | 'open' | 'welcomed'} phase
 *   An offer is `waiting` for message 1, `bound` to a phone that completed the handshake, or
 *   `silent` after its first transport message under the silent decision. A device link is
 *   `awaiting` a handshake, `open` before `welcome`, or `welcomed`.
 * @property {NoiseTransport | null} transport
 * @property {{ sha256: unknown, bundle: Bundle } | null} served What `welcome` named, and the
 *   bundle that was current then.
 */

const DEFAULT_BUNDLE = 'globalThis.tbdScriptedLaptop = true;\n';
const DEFAULT_RELAY_ORIGIN = 'http://127.0.0.1';
const JUNK_FRAME_BYTES = 64;
const ROOM_BYTES = 32;
const utf8 = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });
const graphemes = new Intl.Segmenter('en', { granularity: 'grapheme' });
const FORBIDDEN_SCALAR = /[\p{Cc}\p{Cf}]/u;
// Swift's whitespacesAndNewlines: general category Zs, U+0009 to U+000D, U+0085, U+2028 and
// U+2029, which is exactly Unicode's White_Space. String.prototype.trim also drops U+FEFF.
const EDGE_WHITESPACE = /^\p{White_Space}+|\p{White_Space}+$/gu;

/**
 * The default `onApp`: answers `sessions.subscribe` with one repo, worktree and session.
 * @param {any} body
 * @param {(body: object) => Promise<void>} reply
 */
async function defaultOnApp(body, reply) {
  if (body?.kind === 'request' && body.method === 'sessions.subscribe') {
    await reply({
      kind: 'reply',
      requestID: body.requestID,
      result: {
        repos: [{ name: 'acme-api', worktrees: [{ name: 'fix-login', sessions: [{ ref: 's1', kind: 'claude', status: 'waiting' }] }] }],
      },
    });
  }
}

/**
 * @param {object} options
 * @param {FakeRelay} options.relay
 * @param {string} [options.laptopName]
 * @param {Uint8Array} [options.staticKey] 32 raw private-key bytes; a fresh key when absent.
 * @param {string} [options.bundleText]
 * @param {(body: any, reply: (body: object) => Promise<void>) => unknown} [options.onApp]
 * @param {string} [options.relayOrigin] The `relay` field of each offer.
 * @param {Clock} [options.clock] For each offer's `exp`.
 */
export async function createScriptedLaptop({
  relay,
  laptopName = 'acme-mbp',
  staticKey,
  bundleText = DEFAULT_BUNDLE,
  onApp = defaultOnApp,
  relayOrigin = DEFAULT_RELAY_ORIGIN,
  clock = systemClock,
}) {
  /** @type {KeyPairWithRaw} */
  const staticPair = staticKey === undefined ? await generatePair() : await importPair(staticKey);
  /** @type {Map<string, Link>} */
  const links = new Map();
  let bundle = makeBundle(bundleText);
  /** @type {Record<string, unknown> | null} */
  let welcomePatch = null;
  /** @type {'laptop' | 'loader' | null} */
  let incompatible = null;
  /** @type {((index: number) => unknown) | null} */
  let chunkHook = null;
  let junkBeforeMessage2 = false;

  const laptop = {
    publicKey: staticPair.publicRaw.slice(),
    /** @type {Array<{ room: string, type: string }>} Every phone message that decrypted. */
    log: [],
    counts: {
      bundleGet: 0,
      hello: 0,
      /** Completed handshakes of either pattern. */
      handshakes: 0,
      ikHandshakes: 0,
      /** Completed IKpsk2 handshakes. */
      pairings: 0,
      refused: 0,
      /** Times a device link left and rejoined its room to end a broken channel. */
      rejoins: 0,
    },
    /** @type {Map<string, { phoneKey: Uint8Array, deviceName: string }>} */
    devices: new Map(),
    /** @type {string | null} The last pairing's code: 6 digits, no space. */
    lastCode: null,
    /** @type {object[]} */
    appBodies: [],
    /** @type {unknown[]} Unexpected errors thrown while handling a frame or a signal. */
    errors: [],

    /**
     * Opens a pairing offer and joins its room.
     * @param {{ expSeconds?: number, decision?: Decision, pairedRoom?: string }} [options]
     * @returns {{ v: 1, relay: string, room: string, secret: string, key: string, name: string, exp: number }}
     */
    makeOffer({ expSeconds = 300, decision = 'allow', pairedRoom } = {}) {
      if (!['allow', 'deny', 'expire', 'silent'].includes(decision)) throw new RangeError(`unknown decision ${decision}`);
      const roomBytes = randomBytes(ROOM_BYTES);
      const secret = new Uint8Array(randomBytes(32));
      const room = base64urlEncode(roomBytes);
      join(room, 'offer', { secret, decision, pairedRoom, phoneKey: null, deviceName: null });
      return {
        v: 1,
        relay: relayOrigin,
        room,
        secret: base64urlEncode(secret),
        key: base64urlEncode(staticPair.publicRaw),
        name: laptopName,
        exp: Math.floor(clock.now() / 1000) + expSeconds,
      };
    },

    /** @param {string} text The bundle later `welcome` messages name. */
    setBundle(text) {
      bundle = makeBundle(text);
    },

    /**
     * Fields merged into each later `welcome`. `bundle` merges one level deep, so
     * `{ bundle: { sha256 } }` keeps the real size. An undefined value removes a field.
     * @param {Record<string, unknown> | null} patch
     */
    setWelcome(patch) {
      welcomePatch = patch;
    },

    /** @param {'laptop' | 'loader' | null} tooOld Answer `hello` with `incompatible`. */
    setIncompatible(tooOld) {
      incompatible = tooOld;
    },

    /**
     * Called before each chunk is sent; returning 'stop' sends nothing more. Null clears it.
     * @param {((index: number) => unknown) | null} fn
     */
    onChunk(fn) {
      chunkHook = fn ?? null;
    },

    /** @param {boolean} on Send one random 64-byte frame right before each message 2. */
    sendJunkBeforeMessage2(on) {
      junkBeforeMessage2 = Boolean(on);
    },

    /**
     * Sends `{"type":"app","body"}` once the room's phone has had `welcome`.
     * @param {string} room
     * @param {object} body
     * @returns {Promise<boolean>} false when no welcomed phone is on the room.
     */
    async sendApp(room, body) {
      const link = links.get(room);
      if (link === undefined) return false;
      const sent = await enqueue(link, async () => {
        if (link.phase !== 'welcomed') return false;
        await sendMessage(link, { type: 'app', body });
        return true;
      });
      return sent === true;
    },

    /**
     * Sends `revoked` when a phone is connected, deletes the device and leaves.
     * @param {string} room
     */
    async revoke(room) {
      const link = links.get(room);
      if (link !== undefined) {
        await enqueue(link, async () => {
          if (link.phase === 'open' || link.phase === 'welcomed') await sendMessage(link, { type: 'revoked' });
          leaveLink(link);
        });
        leaveLink(link);
      }
      laptop.devices.delete(room);
    },

    /** @param {string} room Leaves the room; a device stays stored. */
    leave(room) {
      const link = links.get(room);
      if (link !== undefined) leaveLink(link);
    },

    /** @param {string} room Joins the room as a device link, unless already in it. */
    join(room) {
      if (!links.has(room)) join(room, 'device', null);
    },
  };

  /**
   * @param {string} room
   * @param {'offer' | 'device'} kind
   * @param {Offer | null} offer
   * @returns {Link}
   */
  function join(room, kind, offer) {
    const roomBytes = base64urlDecode(room);
    if (roomBytes === null || roomBytes.length !== ROOM_BYTES) throw new RangeError(`not a room ID: ${room}`);
    /** @type {Link} */
    const link = {
      room,
      kind,
      offer,
      prologue: phonePrologue(roomBytes),
      handle: null,
      chain: Promise.resolve(),
      closed: false,
      signals: 0,
      phase: kind === 'offer' ? 'waiting' : 'awaiting',
      transport: null,
      served: null,
    };
    links.set(room, link);
    link.handle = relay.connect(`/v1/rooms/${room}?role=laptop`, {
      binary: (bytes) => void enqueue(link, () => (link.kind === 'offer' ? offerFrame(link, bytes) : deviceFrame(link, bytes))),
      text: (text) => {
        link.signals += 1;
        void enqueue(link, () => (link.kind === 'offer' ? offerSignal(link, text) : deviceSignal(link, text)));
      },
      close: () => void enqueue(link, () => leaveLink(link)),
    });
    if (link.handle === null) {
      links.delete(room);
      throw new Error(`the relay refused room ${room}`);
    }
    return link;
  }

  /**
   * Runs `fn` after everything queued on the link, unless the link has closed by then.
   * @template T
   * @param {Link} link
   * @param {() => T | Promise<T>} fn
   * @returns {Promise<T | undefined>}
   */
  function enqueue(link, fn) {
    const run = link.chain.then(async () => {
      if (link.closed) return undefined;
      try {
        return await fn();
      } catch (error) {
        laptop.errors.push(error);
        return undefined;
      }
    });
    link.chain = run.then(() => {});
    return run;
  }

  /** @param {Link} link */
  function leaveLink(link) {
    if (link.closed) return;
    link.closed = true;
    if (links.get(link.room) === link) links.delete(link.room);
    link.handle?.close(1000, '');
  }

  /** @param {Link} link */
  function rejoin(link) {
    laptop.counts.rejoins += 1;
    leaveLink(link);
    join(link.room, 'device', null);
  }

  /**
   * @param {Link} link
   * @param {Uint8Array} frame
   */
  function sendFrame(link, frame) {
    if (!link.closed) link.handle?.send(frame);
  }

  /**
   * @param {Link} link
   * @param {object} message
   */
  async function sendMessage(link, message) {
    const transport = /** @type {NoiseTransport} */ (link.transport);
    sendFrame(link, await transport.encrypt(utf8.encode(JSON.stringify(message))));
  }

  /** @param {Link} link */
  function sendJunk(link) {
    if (junkBeforeMessage2) sendFrame(link, new Uint8Array(randomBytes(JUNK_FRAME_BYTES)));
  }

  /**
   * @param {Link} link
   * @param {string} signal
   */
  function offerSignal(link, signal) {
    // Before the handshake the offer waits for any phone; after it, the phone is gone.
    if ((signal === 'peer-joined' || signal === 'peer-left') && link.phase !== 'waiting') leaveLink(link);
  }

  /**
   * @param {Link} link
   * @param {Uint8Array} frame
   */
  async function offerFrame(link, frame) {
    const offer = /** @type {Offer} */ (link.offer);
    if (link.phase === 'waiting') {
      const responder = await createResponder({
        pattern: 'IKpsk2', localStatic: staticPair, psk: offer.secret, prologue: link.prologue,
      });
      let read;
      try {
        read = await responder.readMessage1(frame);
      } catch {
        laptop.counts.refused += 1;
        return;
      }
      const deviceName = acceptedDeviceName(read.payload);
      if (deviceName === null) {
        laptop.counts.refused += 1;
        return;
      }
      sendJunk(link);
      const written = await responder.writeMessage2(utf8.encode(JSON.stringify({ laptopName })));
      laptop.lastCode = await confirmationCode(written.handshakeHash);
      laptop.counts.handshakes += 1;
      laptop.counts.pairings += 1;
      offer.phoneKey = read.remoteStatic;
      offer.deviceName = deviceName;
      link.transport = written.transport;
      link.phase = 'bound';
      sendFrame(link, written.message);
      return;
    }

    const message = await openMessage(link, frame);
    if (message === null) {
      // Not a transport message from this phone: the offer is over.
      laptop.counts.refused += 1;
      leaveLink(link);
      return;
    }
    if (link.phase !== 'bound') return; // silent: the first message already decided
    if (message.type === 'hello') laptop.counts.hello += 1;
    switch (offer.decision) {
      case 'allow': {
        const room = typeof offer.pairedRoom === 'string' ? offer.pairedRoom : base64urlEncode(randomBytes(ROOM_BYTES));
        await sendMessage(link, { type: 'paired', room });
        laptop.devices.set(room, {
          phoneKey: /** @type {Uint8Array} */ (offer.phoneKey),
          deviceName: /** @type {string} */ (offer.deviceName),
        });
        leaveLink(link);
        if (typeof offer.pairedRoom !== 'string') join(room, 'device', null);
        return;
      }
      case 'deny':
      case 'expire':
        await sendMessage(link, { type: 'pairDenied', reason: offer.decision === 'deny' ? 'denied' : 'expired' });
        leaveLink(link);
        return;
      case 'silent':
        link.phase = 'silent';
    }
  }

  /**
   * @param {Link} link
   * @param {string} signal
   */
  function deviceSignal(link, signal) {
    if (signal === 'peer-joined' || signal === 'peer-left') {
      link.phase = 'awaiting';
      link.transport = null;
      link.served = null;
    }
  }

  /**
   * @param {Link} link
   * @param {Uint8Array} frame
   */
  async function deviceFrame(link, frame) {
    if (link.phase === 'awaiting') {
      const responder = await createResponder({ pattern: 'IK', localStatic: staticPair, psk: null, prologue: link.prologue });
      let read;
      try {
        read = await responder.readMessage1(frame);
      } catch {
        laptop.counts.refused += 1;
        return;
      }
      const device = laptop.devices.get(link.room);
      if (device === undefined || !sameBytes(device.phoneKey, read.remoteStatic)) {
        laptop.counts.refused += 1;
        return;
      }
      sendJunk(link);
      const written = await responder.writeMessage2(utf8.encode(JSON.stringify({ laptopName })));
      laptop.counts.handshakes += 1;
      laptop.counts.ikHandshakes += 1;
      link.transport = written.transport;
      link.phase = 'open';
      sendFrame(link, written.message);
      return;
    }

    const message = await openMessage(link, frame);
    if (message === null) {
      rejoin(link);
      return;
    }
    if (link.phase === 'open') {
      if (message.type !== 'hello') {
        rejoin(link);
        return;
      }
      laptop.counts.hello += 1;
      if (incompatible !== null) {
        await sendMessage(link, { type: 'incompatible', tooOld: incompatible });
        rejoin(link);
        return;
      }
      const welcome = makeWelcome(bundle, welcomePatch);
      link.served = { sha256: /** @type {any} */ (welcome.bundle)?.sha256, bundle };
      link.phase = 'welcomed';
      await sendMessage(link, welcome);
      return;
    }

    switch (message.type) {
      case 'bundle.get':
        laptop.counts.bundleGet += 1;
        if (link.served === null || message.sha256 !== link.served.sha256) {
          rejoin(link);
          return;
        }
        await sendChunks(link, link.served.sha256, link.served.bundle);
        return;
      case 'app':
        laptop.appBodies.push(message.body);
        await onApp(message.body, (body) => sendMessage(link, { type: 'app', body }));
    }
  }

  /**
   * Decrypts and parses one transport message, and logs it. Null when it does not decrypt
   * or is not a JSON object with a string `type`.
   * @param {Link} link
   * @param {Uint8Array} frame
   * @returns {Promise<Record<string, any> | null>}
   */
  async function openMessage(link, frame) {
    let message;
    try {
      const plaintext = await /** @type {NoiseTransport} */ (link.transport).decrypt(frame);
      message = JSON.parse(utf8Decoder.decode(plaintext));
    } catch {
      return null;
    }
    if (message === null || typeof message !== 'object' || Array.isArray(message) || typeof message.type !== 'string') {
      return null;
    }
    laptop.log.push({ room: link.room, type: message.type });
    return message;
  }

  /**
   * @param {Link} link
   * @param {unknown} sha256 As `welcome` named it.
   * @param {Bundle} served
   */
  async function sendChunks(link, sha256, served) {
    const count = Math.max(1, Math.ceil(served.compressed.length / MAX_CHUNK_BYTES));
    const signals = link.signals;
    for (let index = 0; index < count; index++) {
      if (link.closed || link.signals !== signals || chunkHook?.(index) === 'stop') return;
      const raw = served.compressed.subarray(index * MAX_CHUNK_BYTES, (index + 1) * MAX_CHUNK_BYTES);
      await sendMessage(link, {
        type: 'bundle.chunk', sha256, index, count, data: Buffer.from(raw).toString('base64'),
      });
    }
  }

  return laptop;
}

/**
 * @param {string} text
 * @returns {Bundle}
 */
function makeBundle(text) {
  const bytes = utf8.encode(text);
  return {
    text,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    compressed: new Uint8Array(deflateRawSync(bytes)),
  };
}

/**
 * @param {Bundle} bundle
 * @param {Record<string, unknown> | null} patch
 * @returns {Record<string, unknown>}
 */
function makeWelcome(bundle, patch) {
  /** @type {Record<string, unknown>} */
  const welcome = {
    type: 'welcome',
    protocol: 1,
    minProtocol: 1,
    tbdVersion: '0.0.0-test',
    bundle: { sha256: bundle.sha256, size: bundle.compressed.length },
  };
  if (patch === null) return welcome;
  const { bundle: bundlePatch, ...rest } = patch;
  Object.assign(welcome, rest);
  if ('bundle' in patch) {
    welcome.bundle = isPlainObject(bundlePatch) ? { .../** @type {object} */ (welcome.bundle), ...bundlePatch } : bundlePatch;
  }
  return welcome;
}

/**
 * Plan 3's rule: `{"deviceName": String}`, trimmed, 1 to 64 characters (grapheme clusters, as
 * Swift counts a String), with no scalar whose general category is Cc or Cf.
 * @param {Uint8Array} payload
 * @returns {string | null} The trimmed name, or null to refuse.
 */
function acceptedDeviceName(payload) {
  let value;
  try {
    value = JSON.parse(utf8Decoder.decode(payload));
  } catch {
    return null;
  }
  if (!isPlainObject(value) || typeof value.deviceName !== 'string') return null;
  const name = value.deviceName.replace(EDGE_WHITESPACE, '');
  if (name.length === 0 || FORBIDDEN_SCALAR.test(name)) return null;
  let count = 0;
  for (const _ of graphemes.segment(name)) count += 1;
  return count <= DEVICE_NAME_MAX ? name : null;
}

/**
 * @param {unknown} value
 * @returns {value is Record<string, any>}
 */
function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
function sameBytes(a, b) {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}
