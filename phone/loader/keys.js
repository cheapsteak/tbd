// The phone's X25519 keys, and their wrapping for storage (spec section 2).
//
// WebKit loses a non-extractable X25519 key stored in IndexedDB (bug 312279) but keeps a
// non-extractable AES-GCM key. So each phone private key is stored only wrapped (PKCS#8 under
// AES-GCM) by one non-extractable wrap key, and rebuilt at use time into the `CryptoKeyPair`
// that plan 1's `createInitiator` takes as `localStatic`. Every function takes `subtle` first,
// so Node's Web Crypto drives the tests.

/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */

const X25519 = Object.freeze({ name: 'X25519' });
const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BITS = 128;
// The wrap's additional data is this label and the laptop ID, so a wrapped key unwraps only
// for the record it was made for.
const WRAP_LABEL = 'tbd-phone/1 key ';

const utf8Encoder = new TextEncoder();

/** The stored key cannot be used: it is missing, damaged, or wrapped for another record. */
export class KeyMissingError extends Error {
  /** @param {unknown} [cause] */
  constructor(cause) {
    super("this phone's key for the laptop is missing or damaged", { cause });
    this.name = 'KeyMissingError';
  }
}

/**
 * The key that wraps every phone private key: AES-GCM 256, not extractable, usable only to
 * wrap and unwrap.
 * @param {SubtleCrypto} subtle
 * @returns {Promise<CryptoKey>}
 */
export async function createWrapKey(subtle) {
  return subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['wrapKey', 'unwrapKey']);
}

/**
 * A new X25519 key pair for one laptop. The private key is extractable only so that
 * `wrapPrivateKey` can wrap it once. The pairing handshake uses `pair` as its `localStatic`;
 * the caller then wraps the private key, stores the result, and drops `pair`. Every later use
 * goes through `unwrapPhoneKeyPair`, whose private key is not extractable.
 * @param {SubtleCrypto} subtle
 * @returns {Promise<{ pair: CryptoKeyPair, publicRaw: Uint8Array }>} `publicRaw` is the raw
 *   public key, 32 bytes
 */
export async function createPhoneKeyPair(subtle) {
  const pair = /** @type {CryptoKeyPair} */ (await subtle.generateKey(X25519, true, ['deriveBits']));
  const publicRaw = new Uint8Array(await subtle.exportKey('raw', pair.publicKey));
  if (publicRaw.length !== KEY_BYTES) {
    throw new TypeError(`Web Crypto gave a ${publicRaw.length}-byte X25519 public key`);
  }
  return { pair, publicRaw };
}

/**
 * Wraps a phone private key as PKCS#8 under AES-GCM, with a fresh 12-byte IV and the
 * additional data `tbd-phone/1 key <laptopID>`.
 * @param {SubtleCrypto} subtle
 * @param {CryptoKey} wrapKey from `createWrapKey`
 * @param {CryptoKey} privateKey the extractable private key from `createPhoneKeyPair`
 * @param {string} laptopID the `id` of the record that will hold the wrapped key
 * @returns {Promise<{ wrappedKey: Uint8Array, wrapIV: Uint8Array }>}
 * @throws {TypeError} for a key that is not an X25519 private key, or an empty laptop ID
 */
export async function wrapPrivateKey(subtle, wrapKey, privateKey, laptopID) {
  if (!(privateKey instanceof CryptoKey) || privateKey.type !== 'private' || privateKey.algorithm.name !== X25519.name) {
    throw new TypeError('only an X25519 private key is wrapped');
  }
  if (typeof laptopID !== 'string' || laptopID === '') {
    throw new TypeError('a wrapped key needs the laptop ID of its record');
  }
  const wrapIV = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const wrapped = await subtle.wrapKey('pkcs8', privateKey, wrapKey, wrapParams(wrapIV, laptopID));
  return { wrappedKey: new Uint8Array(wrapped), wrapIV };
}

/**
 * Rebuilds a stored key pair. The private key is unwrapped as X25519, not extractable, with
 * only the `deriveBits` usage; the public key is imported extractable from `phoneKey`, as
 * `createInitiator` requires. The two are checked to be one pair.
 * @param {SubtleCrypto} subtle
 * @param {CryptoKey} wrapKey
 * @param {Pick<LaptopRecord, 'id' | 'phoneKey' | 'wrappedKey' | 'wrapIV'>} record
 * @returns {Promise<CryptoKeyPair>}
 * @throws {KeyMissingError} for any failure, with the reason as its `cause`
 */
export async function unwrapPhoneKeyPair(subtle, wrapKey, record) {
  try {
    const { id } = record;
    if (typeof id !== 'string') {
      throw new TypeError('the record has no laptop ID');
    }
    const wrappedKey = copyBytes(record.wrappedKey, 'wrappedKey');
    const wrapIV = copyBytes(record.wrapIV, 'wrapIV');
    const phoneKey = copyBytes(record.phoneKey, 'phoneKey');
    if (wrapIV.length !== IV_BYTES || phoneKey.length !== KEY_BYTES) {
      throw new TypeError('the record has a wrap IV or public key of the wrong size');
    }
    const privateKey = await subtle.unwrapKey(
      'pkcs8', wrappedKey, wrapKey, wrapParams(wrapIV, id), X25519, false, ['deriveBits']);
    const publicKey = await subtle.importKey('raw', phoneKey, X25519, true, []);
    if (!(await isOnePair(subtle, privateKey, publicKey))) {
      throw new TypeError("the record's public key is not the wrapped key's");
    }
    return { privateKey, publicKey };
  } catch (error) {
    throw new KeyMissingError(error);
  }
}

/**
 * @param {Uint8Array<ArrayBuffer>} iv
 * @param {string} laptopID
 * @returns {AesGcmParams}
 */
function wrapParams(iv, laptopID) {
  return { name: 'AES-GCM', iv, additionalData: utf8Encoder.encode(WRAP_LABEL + laptopID), tagLength: TAG_BITS };
}

/**
 * Whether `publicKey` is the public half of `privateKey`. Web Crypto can neither export the
 * unwrapped private key nor derive its public key, so this compares DH(private, probe) with
 * DH(probe, public) for a throwaway probe pair; they are equal only for a matching pair.
 * @param {SubtleCrypto} subtle
 * @param {CryptoKey} privateKey
 * @param {CryptoKey} publicKey
 * @returns {Promise<boolean>}
 */
async function isOnePair(subtle, privateKey, publicKey) {
  const probe = /** @type {CryptoKeyPair} */ (await subtle.generateKey(X25519, false, ['deriveBits']));
  const [mine, theirs] = await Promise.all([
    subtle.deriveBits({ name: X25519.name, public: probe.publicKey }, privateKey, KEY_BYTES * 8),
    subtle.deriveBits({ name: X25519.name, public: publicKey }, probe.privateKey, KEY_BYTES * 8),
  ]);
  const a = new Uint8Array(mine), b = new Uint8Array(theirs);
  return a.length === KEY_BYTES && a.length === b.length && a.every((byte, i) => byte === b[i]);
}

/**
 * @param {unknown} value
 * @param {string} name
 * @returns {Uint8Array<ArrayBuffer>} a copy, so the caller's array can change meanwhile
 */
function copyBytes(value, name) {
  if (!(value instanceof Uint8Array)) {
    throw new TypeError(`${name} must be a Uint8Array`);
  }
  return new Uint8Array(value);
}
