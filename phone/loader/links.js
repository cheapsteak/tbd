// Pairing-link intake, relay URLs and the phone's device name.
//
// Links are parsed by plan 1's `parsePairingLink`; this module only adds the clock grace,
// decodes the three keys and maps each error code to a screen.

import { PairingLinkError, base64urlDecode, parsePairingLink } from './channel/pairingLink.js';
import { DEVICE_NAME_MAX, PAIRING_EXPIRY_GRACE_MS } from './constants.js';
import { MESSAGES } from './messages.js';

/** @typedef {import('./channel/pairingLink.js').PairingLink} PairingLink */

/**
 * @typedef {object} PairingLinkData
 * @property {PairingLink} fields The parsed link, as plan 1 returns it.
 * @property {Uint8Array} room 32 bytes.
 * @property {Uint8Array} secret 32 bytes.
 * @property {Uint8Array} laptopKey 32 bytes.
 */

const ROOM_TEXT = /^[A-Za-z0-9_-]{43}$/;
const ROOM_BYTES = 32;
// The only hosts that may use cleartext, as in plan 1's relay grammar.
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1']);
// Plan 3's laptop refuses a name with a Cc or Cf scalar. Cs (a lone surrogate) is refused
// too: a Swift String cannot hold one, so the laptop's JSON decoder would refuse the name.
const FORBIDDEN_NAME_SCALAR = /[\p{Cc}\p{Cf}\p{Cs}]/u;

/**
 * Splits a pairing link off the page's address, so the secret can leave the address bar.
 * @param {string} href the page's `location.href`
 * @returns {{ link: string | null, cleanURL: string }} `link` is the whole `href` when its
 *   fragment starts with `#p=`, else null; `cleanURL` is `href` without any fragment.
 */
export function takePairingFragment(href) {
  const hashAt = href.indexOf('#');
  if (hashAt === -1) {
    return { link: null, cleanURL: href };
  }
  return { link: href.startsWith('#p=', hashAt) ? href : null, cleanURL: href.slice(0, hashAt) };
}

/**
 * Parses a scanned, pasted or opened pairing link. A phone clock up to
 * PAIRING_EXPIRY_GRACE_MS ahead of the laptop's still accepts a fresh link.
 * @param {string} text
 * @param {number} nowMs
 * @returns {PairingLinkData}
 * @throws {PairingLinkError} unchanged from `parsePairingLink`
 * @throws {TypeError} when `nowMs` is not a finite number, which would skip the expiry check
 */
export function readPairingLink(text, nowMs) {
  if (!Number.isFinite(nowMs)) {
    throw new TypeError('readPairingLink needs a finite nowMs');
  }
  const fields = parsePairingLink(text, { now: nowMs - PAIRING_EXPIRY_GRACE_MS });
  return {
    fields,
    room: decodeKey(fields.room, 'room'),
    secret: decodeKey(fields.secret, 'secret'),
    laptopKey: decodeKey(fields.key, 'key'),
  };
}

/**
 * The parser has already checked each key, so this never throws for a parsed link.
 * @param {string} text
 * @param {string} field
 * @returns {Uint8Array}
 */
function decodeKey(text, field) {
  const bytes = base64urlDecode(text);
  if (bytes === null) {
    throw new PairingLinkError('badField', field);
  }
  return bytes;
}

/**
 * The screen for a link that failed to read.
 * @param {unknown} error
 * @returns {string}
 */
export function linkErrorMessage(error) {
  if (!(error instanceof PairingLinkError)) {
    return MESSAGES.notLink;
  }
  switch (error.code) {
    case 'badBase64':
    case 'badJSON':
    case 'badField':
      return MESSAGES.damagedLink;
    case 'unsupportedVersion':
      // A newer laptop than this loader; a reload fetches the current loader.
      return MESSAGES.reload;
    case 'expired':
      return MESSAGES.expired;
    default:
      return MESSAGES.notLink;
  }
}

/**
 * Whether `value` is a room ID: 43 base64url characters that plan 1's strict decoder turns
 * into 32 bytes.
 * @param {unknown} value
 * @returns {value is string}
 */
export function isRoomID(value) {
  return typeof value === 'string' && ROOM_TEXT.test(value) && base64urlDecode(value)?.length === ROOM_BYTES;
}

/**
 * The WebSocket URL of a room (relay API v1).
 * @param {string} relay the relay origin from a pairing link
 * @param {string} room
 * @param {'phone' | 'laptop'} [role]
 * @returns {string}
 * @throws {RangeError} for a relay `relayOrigin` refuses, a bad room or an unknown role
 */
export function relaySocketURL(relay, room, role = 'phone') {
  if (role !== 'phone' && role !== 'laptop') {
    throw new RangeError('unknown relay role');
  }
  const { secure, host } = relayOrigin(relay);
  return new URL(`v1/rooms/${checkedRoom(room)}?role=${role}`, `${secure ? 'wss' : 'ws'}://${host}/`).href;
}

/**
 * The presence URL of a room (relay API v1): `GET` answers `{"laptop":true|false}`.
 * @param {string} relay the relay origin from a pairing link
 * @param {string} room
 * @returns {string}
 * @throws {RangeError} for a relay `relayOrigin` refuses or a bad room
 */
export function relayPresenceURL(relay, room) {
  const { secure, host } = relayOrigin(relay);
  return new URL(`v1/rooms/${checkedRoom(room)}/presence`, `${secure ? 'https' : 'http'}://${host}/`).href;
}

/**
 * @param {string} room
 * @returns {string}
 */
function checkedRoom(room) {
  if (!isRoomID(room)) {
    throw new RangeError('bad room ID');
  }
  return room;
}

/**
 * Checks a stored relay origin. Every relay `parsePairingLink` accepts passes, and the
 * parser's safety rules hold for a damaged record too: `https:`, or `http:` only for the hosts
 * `localhost` and `127.0.0.1`, and nothing but the origin – no user name, password, path (a
 * lone `/` is allowed), query or fragment. The checks run on the parsed URL, the same object
 * the callers build from, and they take only `secure` and `host`, so nothing else of the
 * stored text reaches a socket.
 * @param {string} relay
 * @returns {{ secure: boolean, host: string }} `host` includes any non-default port
 */
function relayOrigin(relay) {
  let url;
  try {
    url = new URL(relay);
  } catch {
    throw new RangeError('relay is not a URL');
  }
  if (url.username !== '' || url.password !== '' || url.pathname !== '/' || url.search !== '' || url.hash !== '') {
    throw new RangeError('relay must be an origin only');
  }
  if (url.protocol === 'https:') {
    return { secure: true, host: url.host };
  }
  if (url.protocol === 'http:' && LOOPBACK_HOSTS.has(url.hostname)) {
    return { secure: false, host: url.host };
  }
  throw new RangeError('relay must use https unless it is localhost or 127.0.0.1');
}

/**
 * A default name for this phone, for the user to edit.
 * @param {string} ua `navigator.userAgent`
 * @param {number} maxTouchPoints `navigator.maxTouchPoints`
 * @returns {string}
 */
export function deviceNameFromUserAgent(ua, maxTouchPoints) {
  if (/\biPhone\b/.test(ua)) return 'iPhone';
  if (/\biPad\b/.test(ua)) return 'iPad';
  // iPadOS Safari asks for desktop sites with a Mac user agent; only touch tells them apart.
  if (/\bMacintosh\b/.test(ua) && maxTouchPoints > 1) return 'iPad';
  if (/\bAndroid\b/.test(ua)) return /\bMobile\b/.test(ua) ? 'Android phone' : 'Android tablet';
  return 'Phone';
}

/**
 * The name the phone sends in pairing message 1. It is at least as strict as the laptop's
 * check (trimmed, 1 to 64 grapheme clusters, no Cc or Cf scalar), so a name it accepts is
 * never silently refused: trimmed, 1 to DEVICE_NAME_MAX code points (never fewer than the
 * grapheme clusters), with no Cc, Cf or lone-surrogate scalar.
 * @param {string} input
 * @returns {string} the trimmed name
 * @throws {RangeError}
 */
export function normalizeDeviceName(input) {
  const name = input.trim();
  const codePoints = [...name].length;
  if (codePoints < 1 || codePoints > DEVICE_NAME_MAX || FORBIDDEN_NAME_SCALAR.test(name)) {
    throw new RangeError('device name must be 1 to 64 characters with no control characters');
  }
  return name;
}
