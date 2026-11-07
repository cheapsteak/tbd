// Strict base64url and the pairing-link parser for the phone loader.
//
// A pairing link is `<loaderURL>#p=<base64url(UTF-8 JSON)>`. The checks and
// their order match the daemon's `PairingLink.parse`, so both sides give the
// same error code for every link in `phone/test-vectors/pairing-link.json`.
//
// Parity contract: for every link text except those below, `parsePairingLink`
// and the daemon's `PairingLink.parse` return the same link or fail with the
// same error code. Outside the contract, either side's answer is acceptable,
// because the daemon never builds such a link:
// - duplicate object keys (the daemon keeps the first, `JSON.parse` the last);
// - nesting depth within a few levels of 512;
// - numbers whose decimal text differs from the IEEE-754 double they round
//   to in ways only one side observes, such as a nonzero number too small
//   for a double, which `JSON.parse` reads as 0 and the daemon refuses;
// - JSON that `JSON.parse` refuses and the daemon's JSONDecoder accepts: one
//   trailing comma before a `}` or `]`, and anything malformed inside the
//   value of a key the link does not define (a lone surrogate, an unknown
//   escape, a raw control character, or a misspelled number such as `01` or
//   `1.`), because JSONDecoder checks only the values it reads;
// - link text with surrounding whitespace, or a tab or line break inside it,
//   which this parser drops and the daemon's `URL(string:)` percent-encodes.

/**
 * @typedef {{ v: number, relay: string, room: string, secret: string, key: string, name: string, exp: number }} PairingLink
 */

/**
 * @typedef {'missingFragment' | 'badBase64' | 'badJSON' | 'unsupportedVersion' | 'badField' | 'expired'} PairingLinkErrorCode
 */

const LINK_VERSION = 1;
const MAX_NAME_BYTES = 256;
const KEY_BYTES = 32;
// Deeper JSON is badJSON. The daemon's JSONDecoder has the same limit, and the
// walk that enforces it here is recursive, so it also bounds the stack.
const MAX_JSON_DEPTH = 512;
const MAX_RELAY_HOST_LENGTH = 253;
const MAX_RELAY_PORT = 65535;

// The relay grammar, matched against the whole string in lowercase ASCII,
// with nothing after the host or port: no path, not even `/`, and no query,
// fragment or user info.
// - `https://` HOST [`:` PORT]
// - `http://localhost` [`:` PORT] or `http://127.0.0.1` [`:` PORT], for a
//   local test relay
// HOST is one or more labels joined by `.`, at most 253 characters in all.
// Each label is 1 to 63 of `a-z`, `0-9` and `-`, neither starting nor ending
// with `-` and not starting with `xn--`. The last label starts with a letter,
// so a dotted IPv4 address is refused. PORT is 1 to 5 digits with no leading
// zero, from 1 to 65535; the pattern bounds its digits and isAllowedRelay its
// value. The daemon scans the same grammar byte by byte. Without the `m` flag,
// `$` matches only at the very end, never before a trailing newline.
const HOST_LABEL = '(?!xn--)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
const LAST_HOST_LABEL = '(?!xn--)[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?';
const RELAY_PATTERN = new RegExp(
  `^(?:https://((?:${HOST_LABEL}\\.)*${LAST_HOST_LABEL})|http://(?:localhost|127\\.0\\.0\\.1))(?::([1-9][0-9]{0,4}))?$`,
);

// 8,192 bytes per String.fromCharCode call keeps the argument count far
// below every engine's limit, so large inputs never overflow the stack.
const ENCODE_CHUNK = 8192;
const BASE64URL_TEXT = /^[A-Za-z0-9_-]*$/;

// `fatal` makes invalid UTF-8 throw instead of decoding to U+FFFD.
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });
const utf8Encoder = new TextEncoder();
// For the well-formedness round trip only. `ignoreBOM` keeps a string that
// starts with U+FEFF intact, where the default would drop it and make a
// well-formed string look malformed.
const roundTripDecoder = new TextDecoder('utf-8', { ignoreBOM: true });

export class PairingLinkError extends Error {
  /**
   * @param {PairingLinkErrorCode} code
   * @param {string} [field] the failing field, for `badField` only
   */
  constructor(code, field) {
    super(field === undefined ? code : `${code}: ${field}`);
    this.name = 'PairingLinkError';
    /** @readonly */
    this.code = code;
    // Always an own property, undefined unless the code is `badField`.
    /** @readonly */
    this.field = field;
  }
}

/**
 * Base64url without padding.
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export function base64urlEncode(bytes) {
  let binary = '';
  for (let start = 0; start < bytes.length; start += ENCODE_CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(start, start + ENCODE_CHUNK));
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Strict base64url: returns null for padding, the standard `+/` alphabet,
 * whitespace, a length of 1 mod 4, or a last character with non-zero spare
 * bits. Every accepted text is the one `base64urlEncode` gives for its bytes.
 * @param {string} str
 * @returns {Uint8Array | null}
 */
export function base64urlDecode(str) {
  if (!BASE64URL_TEXT.test(str) || str.length % 4 === 1) {
    return null;
  }
  const padding = '='.repeat((4 - (str.length % 4)) % 4);
  let binary;
  try {
    binary = atob(str.replace(/-/g, '+').replace(/_/g, '/') + padding);
  } catch {
    return null;
  }
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  // atob ignores non-zero spare bits, so re-encoding is what rejects them.
  return base64urlEncode(bytes) === str ? bytes : null;
}

/**
 * Parses and validates a pairing link. Unknown JSON fields are dropped.
 * @param {string | URL} url the link, as opened or pasted; surrounding whitespace is ignored
 * @param {{ now?: number }} [options] `now` is in milliseconds since the epoch
 * @returns {PairingLink}
 * @throws {PairingLinkError}
 */
export function parsePairingLink(url, { now = Date.now() } = {}) {
  const text = (typeof url === 'string' ? url : url.href).trim();
  let parsed;
  try {
    parsed = new URL(text);
  } catch {
    throw new PairingLinkError('missingFragment');
  }

  // `hash` is the fragment as serialized, never percent-decoded, so `+`,
  // `=` and `%` reach the strict decoder unchanged. URLSearchParams would
  // turn `+` into a space and decode `%`, so it is not used. The URL parser
  // does drop ASCII tabs and newlines inside a pasted link, as a browser does
  // for a link it opens.
  const fragment = parsed.hash;
  if (!fragment.startsWith('#p=')) {
    throw new PairingLinkError('missingFragment');
  }
  const payload = base64urlDecode(fragment.slice('#p='.length));
  if (payload === null) {
    throw new PairingLinkError('badBase64');
  }

  const object = decodeJSONObject(payload);
  const { v, relay, room, secret, key, name, exp } = object;
  if (typeof v !== 'number' || !Number.isInteger(v)) {
    throw new PairingLinkError('badJSON');
  }
  if (v !== LINK_VERSION) {
    throw new PairingLinkError('unsupportedVersion');
  }
  if (
    typeof relay !== 'string' ||
    typeof room !== 'string' ||
    typeof secret !== 'string' ||
    typeof key !== 'string' ||
    typeof name !== 'string' ||
    typeof exp !== 'number' ||
    !Number.isInteger(exp)
  ) {
    throw new PairingLinkError('badJSON');
  }

  if (!isAllowedRelay(relay)) {
    throw new PairingLinkError('badField', 'relay');
  }
  for (const [field, value] of /** @type {const} */ ([['room', room], ['secret', secret], ['key', key]])) {
    if (base64urlDecode(value)?.length !== KEY_BYTES) {
      throw new PairingLinkError('badField', field);
    }
  }
  if (name.length === 0 || utf8Encoder.encode(name).length > MAX_NAME_BYTES) {
    throw new PairingLinkError('badField', 'name');
  }
  if (exp < 1 || exp > Number.MAX_SAFE_INTEGER) {
    throw new PairingLinkError('badField', 'exp');
  }

  if (now >= exp * 1000) {
    throw new PairingLinkError('expired');
  }
  return { v, relay, room, secret, key, name, exp };
}

/**
 * UTF-8 JSON that must be a plain object; anything else is `badJSON`.
 * TextDecoder drops one leading UTF-8 byte order mark, as RFC 8259 permits,
 * and `JSON.parse` refuses a second one and any 00 byte. A string or object
 * key anywhere in the value that is not well-formed UTF-16 is also `badJSON`,
 * as is nesting deeper than MAX_JSON_DEPTH.
 * @param {Uint8Array} bytes
 * @returns {Record<string, unknown>}
 */
function decodeJSONObject(bytes) {
  let value;
  try {
    value = JSON.parse(utf8Decoder.decode(bytes));
  } catch {
    throw new PairingLinkError('badJSON');
  }
  if (!isWellFormedValue(value, 1) || value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new PairingLinkError('badJSON');
  }
  return value;
}

/**
 * Whether every string and object key in `value` is well-formed UTF-16, with
 * no lone surrogate such as a `\ud800` escape gives, and no array or object
 * is nested deeper than MAX_JSON_DEPTH.
 * @param {unknown} value
 * @param {number} depth the nesting depth of `value` if it is an array or object, 1 at the top
 * @returns {boolean}
 */
function isWellFormedValue(value, depth) {
  if (typeof value === 'string') {
    return isWellFormedString(value);
  }
  if (value === null || typeof value !== 'object') {
    return true;
  }
  if (depth > MAX_JSON_DEPTH) {
    return false;
  }
  if (Array.isArray(value)) {
    return value.every((item) => isWellFormedValue(item, depth + 1));
  }
  return Object.entries(value).every(([key, item]) => isWellFormedString(key) && isWellFormedValue(item, depth + 1));
}

/**
 * Encoding replaces a lone surrogate with U+FFFD, so only a well-formed
 * string survives the round trip. `String.prototype.isWellFormed` would say
 * the same, but postdates the loader's oldest supported browsers.
 * @param {string} text
 * @returns {boolean}
 */
function isWellFormedString(text) {
  return roundTripDecoder.decode(utf8Encoder.encode(text)) === text;
}

/**
 * Whether the relay matches RELAY_PATTERN, with a host of at most
 * MAX_RELAY_HOST_LENGTH characters and a port of at most MAX_RELAY_PORT. The
 * relay is never trimmed or lowercased, so the caller gets it back as sent.
 * @param {string} relay
 * @returns {boolean}
 */
function isAllowedRelay(relay) {
  const match = RELAY_PATTERN.exec(relay);
  if (match === null) {
    return false;
  }
  const [, host, port] = match;
  if (host !== undefined && host.length > MAX_RELAY_HOST_LENGTH) {
    return false;
  }
  return port === undefined || Number(port) <= MAX_RELAY_PORT;
}
