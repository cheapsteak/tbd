// The loader protocol (version 1): JSON objects inside Noise transport messages.
//
// `parseLaptopMessage` builds each result from the fields it checked, so nothing the laptop
// adds reaches the caller unvalidated. `app.body` is the one opaque value: it is checked to be
// a JSON object and passed on unread.

import { LAPTOP_NAME_MAX_BYTES, LOADER_PROTOCOLS, LOADER_VERSION, MAX_BUNDLE_COMPRESSED } from './constants.js';
import { isRoomID } from './links.js';

/**
 * @typedef {object} WelcomeMessage
 * @property {'welcome'} type
 * @property {number} protocol
 * @property {number} minProtocol
 * @property {string} tbdVersion
 * @property {{ sha256: string, size: number }} bundle `sha256` is the lowercase hex SHA-256 of
 *   the inflated bundle; `size` counts its compressed bytes.
 */

/**
 * @typedef {object} ChunkMessage
 * @property {'bundle.chunk'} type
 * @property {string} sha256
 * @property {number} index
 * @property {number} count
 * @property {string} data Base64 of raw-deflate bytes.
 */

/**
 * @typedef {WelcomeMessage
 *   | { type: 'incompatible', tooOld: 'laptop' | 'loader' }
 *   | ChunkMessage
 *   | { type: 'app', body: Record<string, unknown> }
 *   | { type: 'revoked' }
 *   | { type: 'paired', room: string }
 *   | { type: 'pairDenied', reason: 'denied' | 'expired' }
 *   | { type: 'unknown' }} LaptopMessage
 */

const SHA256_HEX = /^[0-9a-f]{64}$/;
const MAX_TBD_VERSION_LENGTH = 64;

const utf8Encoder = new TextEncoder();
// `fatal` makes invalid UTF-8 throw instead of decoding to U+FFFD.
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });
// For the well-formedness round trip only. `ignoreBOM` keeps a string that starts with U+FEFF
// intact, where the default would drop it and make a well-formed string look malformed.
const roundTripDecoder = new TextDecoder('utf-8', { ignoreBOM: true });

export class ProtocolError extends Error {
  /**
   * @param {string} reason what failed: `utf8`, `json`, `notObject`, `type`, or
   *   `<type>.<field>` for a known message with a bad field; for message 2's payload,
   *   `message2` (not UTF-8 JSON) or `message2.laptopName`
   */
  constructor(reason) {
    super(`loader protocol: ${reason}`);
    this.name = 'ProtocolError';
    /** @readonly */
    this.reason = reason;
  }
}

/** @returns {{ type: 'hello', loaderVersion: string, protocols: number[] }} */
export function makeHello() {
  return { type: 'hello', loaderVersion: LOADER_VERSION, protocols: [...LOADER_PROTOCOLS] };
}

/**
 * @param {object} obj
 * @returns {Uint8Array} UTF-8 JSON
 */
export function encodeMessage(obj) {
  return utf8Encoder.encode(JSON.stringify(obj));
}

/**
 * Decodes one transport message's plaintext.
 * @param {Uint8Array} bytes
 * @returns {Record<string, unknown> & { type: string }} a JSON object with a string `type`
 * @throws {ProtocolError}
 */
export function decodeMessage(bytes) {
  let text;
  try {
    text = utf8Decoder.decode(bytes);
  } catch {
    throw new ProtocolError('utf8');
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new ProtocolError('json');
  }
  if (!isPlainObject(value)) {
    throw new ProtocolError('notObject');
  }
  if (typeof value.type !== 'string') {
    throw new ProtocolError('type');
  }
  return /** @type {Record<string, unknown> & { type: string }} */ (value);
}

/**
 * Validates a laptop message. An unknown `type` is `{ type: 'unknown' }`, for the caller to
 * ignore; a known type with a wrong shape throws.
 * @param {unknown} obj a decoded message
 * @returns {LaptopMessage}
 * @throws {ProtocolError}
 */
export function parseLaptopMessage(obj) {
  if (!isPlainObject(obj)) {
    throw new ProtocolError('notObject');
  }
  const { type } = obj;
  if (typeof type !== 'string') {
    throw new ProtocolError('type');
  }
  /** @param {string} field */
  const bad = (field) => new ProtocolError(`${type}.${field}`);
  switch (type) {
    case 'welcome': {
      const { protocol, minProtocol, tbdVersion, bundle } = obj;
      if (!isIntegerIn(protocol, 1)) throw bad('protocol');
      if (!isIntegerIn(minProtocol, 1)) throw bad('minProtocol');
      if (typeof tbdVersion !== 'string') throw bad('tbdVersion');
      const versionLength = [...tbdVersion].length;
      if (versionLength < 1 || versionLength > MAX_TBD_VERSION_LENGTH) throw bad('tbdVersion');
      if (!isPlainObject(bundle)) throw bad('bundle');
      const { sha256, size } = bundle;
      if (!isSHA256(sha256)) throw bad('bundle.sha256');
      if (!isIntegerIn(size, 1, MAX_BUNDLE_COMPRESSED)) throw bad('bundle.size');
      return { type, protocol, minProtocol, tbdVersion, bundle: { sha256, size } };
    }
    case 'incompatible': {
      const { tooOld } = obj;
      if (tooOld !== 'laptop' && tooOld !== 'loader') throw bad('tooOld');
      return { type, tooOld };
    }
    case 'bundle.chunk': {
      const { sha256, index, count, data } = obj;
      if (!isSHA256(sha256)) throw bad('sha256');
      if (!isIntegerIn(index, 0)) throw bad('index');
      if (!isIntegerIn(count, 1)) throw bad('count');
      if (index >= count) throw bad('index');
      if (typeof data !== 'string') throw bad('data');
      return { type, sha256, index, count, data };
    }
    case 'app': {
      const { body } = obj;
      if (!isPlainObject(body)) throw bad('body');
      return { type, body };
    }
    case 'revoked':
      return { type };
    case 'paired': {
      const { room } = obj;
      if (!isRoomID(room)) throw bad('room');
      return { type, room };
    }
    case 'pairDenied': {
      const { reason } = obj;
      if (reason !== 'denied' && reason !== 'expired') throw bad('reason');
      return { type, reason };
    }
    default:
      return { type: 'unknown' };
  }
}

/**
 * Reads the payload of a handshake's message 2, pairing (`IKpsk2`) or reconnecting (`IK`):
 * `{"laptopName": <string>}`, a name `isLaptopName` accepts. Other fields are ignored.
 * @param {Uint8Array} payload
 * @returns {string} the laptop's name
 * @throws {ProtocolError}
 */
export function readLaptopName(payload) {
  let value;
  try {
    value = JSON.parse(utf8Decoder.decode(payload));
  } catch {
    throw new ProtocolError('message2');
  }
  const name = isPlainObject(value) ? value.laptopName : undefined;
  if (typeof name !== 'string' || !isLaptopName(name)) {
    throw new ProtocolError('message2.laptopName');
  }
  return name;
}

/**
 * Whether `name` passes the rules a pairing link's `name` must (channel/pairingLink.js): not
 * empty, no lone surrogate, and at most LAPTOP_NAME_MAX_BYTES bytes of UTF-8. A laptop's name
 * is stored and shown on every screen, so the one a handshake reports obeys the same rules as
 * the one a pairing link carries.
 * @param {string} name
 * @returns {boolean}
 */
export function isLaptopName(name) {
  if (name.length === 0) return false;
  // Encoding replaces a lone surrogate with U+FFFD, so only a well-formed string survives the
  // round trip, and only then does the encoded length count its real bytes.
  const encoded = utf8Encoder.encode(name);
  return roundTripDecoder.decode(encoded) === name && encoded.length <= LAPTOP_NAME_MAX_BYTES;
}

/**
 * Whether this loader can run the protocol `welcome` chose.
 * @param {{ protocol: number, minProtocol: number }} welcome
 * @returns {'ok' | 'loaderTooOld'}
 */
export function checkCompat(welcome) {
  if (!LOADER_PROTOCOLS.includes(welcome.protocol) || welcome.minProtocol > Math.max(...LOADER_PROTOCOLS)) {
    return 'loaderTooOld';
  }
  return 'ok';
}

/**
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * @param {unknown} value
 * @param {number} min
 * @param {number} [max]
 * @returns {value is number} an integer from `min` to `max`
 */
function isIntegerIn(value, min, max = Infinity) {
  return Number.isInteger(value) && /** @type {number} */ (value) >= min && /** @type {number} */ (value) <= max;
}

/**
 * @param {unknown} value
 * @returns {value is string} a lowercase hex SHA-256
 */
export function isSHA256(value) {
  return typeof value === 'string' && SHA256_HEX.test(value);
}
