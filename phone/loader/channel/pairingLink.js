// Strict base64url and the pairing-link parser for the phone loader.
//
// A pairing link is `<loaderURL>#p=<base64url(UTF-8 JSON)>`. The checks and
// their order match the daemon's `PairingLink.parse`, so both sides give the
// same error code for every link in `phone/test-vectors/pairing-link.json`.

/**
 * @typedef {{ v: number, relay: string, room: string, secret: string, key: string, name: string, exp: number }} PairingLink
 */

/**
 * @typedef {'missingFragment' | 'badBase64' | 'badJSON' | 'unsupportedVersion' | 'badField' | 'expired'} PairingLinkErrorCode
 */

const LINK_VERSION = 1;
const MAX_NAME_BYTES = 256;
const KEY_BYTES = 32;
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1']);

// 8,192 bytes per String.fromCharCode call keeps the argument count far
// below every engine's limit, so large inputs never overflow the stack.
const ENCODE_CHUNK = 8192;
const BASE64URL_TEXT = /^[A-Za-z0-9_-]*$/;

// `fatal` makes invalid UTF-8 throw instead of decoding to U+FFFD.
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });
const utf8Encoder = new TextEncoder();

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
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
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
 * TextDecoder drops a leading UTF-8 byte order mark, as RFC 8259 permits.
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
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new PairingLinkError('badJSON');
  }
  return value;
}

/**
 * `https:`, or `http:` on a loopback host for local test relays. `hostname`
 * excludes the port, which `host` would include.
 * @param {string} relay
 * @returns {boolean}
 */
function isAllowedRelay(relay) {
  let parsed;
  try {
    parsed = new URL(relay);
  } catch {
    return false;
  }
  if (parsed.hostname === '') {
    return false;
  }
  return parsed.protocol === 'https:' || (parsed.protocol === 'http:' && LOOPBACK_HOSTS.has(parsed.hostname));
}
