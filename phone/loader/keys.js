// The phone's X25519 keys, and their wrapping for storage (spec section 2).
//
// WebKit loses a non-extractable X25519 key stored in IndexedDB (bug 312279) but keeps a
// non-extractable AES-GCM key. So each phone private key is stored only wrapped (PKCS#8 under
// AES-GCM), each by its own non-extractable wrap key kept in the same laptop record, and
// rebuilt at use time into the `CryptoKeyPair` that plan 1's `createInitiator` takes as
// `localStatic`. A damaged or lost wrap key then costs only its own laptop. Every function
// takes `subtle` first, so Node's Web Crypto drives the tests.
//
// Callers make keys with `createWrappedPhoneKey`. `createPhoneKeyPair` and `wrapPrivateKey`
// are its building blocks: the extractable private key they pass between them never leaves
// that call.

import { base64urlEncode } from './channel/pairingLink.js';

/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */

const X25519 = Object.freeze({ name: 'X25519' });
const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BITS = 128;
const WRAP_BITS = 256;
const WRAP_USAGES = Object.freeze(/** @type {KeyUsage[]} */ (['wrapKey', 'unwrapKey']));
// The wrap's additional data is this label, the laptop ID, a space and the base64url of the
// phone's public key. So a wrapped key unwraps only for the record it was made for, and only
// beside the public key it belongs to.
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
 * A laptop's wrap key: AES-GCM 256, not extractable, usable only to wrap and unwrap.
 * @param {SubtleCrypto} subtle
 * @returns {Promise<CryptoKey>}
 */
export async function createWrapKey(subtle) {
  return subtle.generateKey({ name: 'AES-GCM', length: WRAP_BITS }, false, [...WRAP_USAGES]);
}

/**
 * Whether `value` is a key `createWrapKey` could have made: a secret AES-GCM 256 key, not
 * extractable, with exactly the usages `wrapKey` and `unwrapKey`.
 * @param {unknown} value
 * @returns {value is CryptoKey}
 */
export function isWrapKey(value) {
  if (!(value instanceof CryptoKey) || value.type !== 'secret' || value.extractable !== false) {
    return false;
  }
  const algorithm = /** @type {AesKeyAlgorithm} */ (value.algorithm);
  const { usages } = value;
  return algorithm.name === 'AES-GCM' && algorithm.length === WRAP_BITS
    && usages.length === WRAP_USAGES.length && WRAP_USAGES.every((usage) => usages.includes(usage));
}

/**
 * A new key for one laptop, in one step: a fresh wrap key, an X25519 key pair, its private
 * key wrapped under the wrap key, and the pair rebuilt from that wrap with a private key that
 * is not extractable. The extractable private key exists only inside this call.
 *
 * Unwrapping before returning also proves that the record fields unwrap, before anything is
 * stored. `pair` serves as the pairing handshake's `localStatic`; the other fields go into the
 * laptop record, with `publicRaw` as its `phoneKey`.
 * @param {SubtleCrypto} subtle
 * @param {string} laptopID the `id` of the record that will hold the key
 * @returns {Promise<{ wrapKey: CryptoKey, publicRaw: Uint8Array, wrappedKey: Uint8Array,
 *   wrapIV: Uint8Array, pair: CryptoKeyPair }>}
 * @throws {TypeError} for an empty laptop ID (from `wrapPrivateKey`)
 */
export async function createWrappedPhoneKey(subtle, laptopID) {
  const wrapKey = await createWrapKey(subtle);
  const phone = await createPhoneKeyPair(subtle);
  const { wrappedKey, wrapIV } = await wrapPrivateKey(subtle, wrapKey, phone.pair.privateKey, laptopID, phone.publicRaw);
  const pair = await unwrapPhoneKeyPair(subtle, wrapKey, { id: laptopID, phoneKey: phone.publicRaw, wrappedKey, wrapIV });
  return { wrapKey, publicRaw: phone.publicRaw, wrappedKey, wrapIV, pair };
}

/**
 * A new X25519 key pair whose private key is extractable, so that it can be wrapped once.
 * A building block of `createWrappedPhoneKey`, which callers use instead.
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
 * additional data `tbd-phone/1 key <laptopID> <base64url phoneKey>`. A building block of
 * `createWrappedPhoneKey`, which callers use instead.
 * @param {SubtleCrypto} subtle
 * @param {CryptoKey} wrapKey from `createWrapKey`
 * @param {CryptoKey} privateKey the extractable private key from `createPhoneKeyPair`
 * @param {string} laptopID the `id` of the record that will hold the wrapped key
 * @param {Uint8Array} phoneKey the raw public key of `privateKey`, 32 bytes
 * @returns {Promise<{ wrappedKey: Uint8Array, wrapIV: Uint8Array }>}
 * @throws {TypeError} for a key that is not an X25519 private key, an empty laptop ID, or a
 *   public key that is not 32 bytes
 */
export async function wrapPrivateKey(subtle, wrapKey, privateKey, laptopID, phoneKey) {
  if (!(privateKey instanceof CryptoKey) || privateKey.type !== 'private' || privateKey.algorithm.name !== X25519.name) {
    throw new TypeError('only an X25519 private key is wrapped');
  }
  if (typeof laptopID !== 'string' || laptopID === '') {
    throw new TypeError('a wrapped key needs the laptop ID of its record');
  }
  const publicRaw = copyBytes(phoneKey, 'phoneKey');
  if (publicRaw.length !== KEY_BYTES) {
    throw new TypeError('phoneKey must be 32 bytes');
  }
  const wrapIV = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const wrapped = await subtle.wrapKey('pkcs8', privateKey, wrapKey, wrapParams(wrapIV, laptopID, publicRaw));
  return { wrappedKey: new Uint8Array(wrapped), wrapIV };
}

/**
 * Rebuilds a stored key pair. The private key is unwrapped as X25519, not extractable, with
 * only the `deriveBits` usage; the public key is imported extractable from `phoneKey`, as
 * `createInitiator` requires. The wrap's additional data names `phoneKey`, so a public key
 * that is not the one wrapped beside the private key fails the unwrap.
 * @param {SubtleCrypto} subtle
 * @param {CryptoKey} wrapKey the record's `wrapKey`
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
      'pkcs8', wrappedKey, wrapKey, wrapParams(wrapIV, id, phoneKey), X25519, false, ['deriveBits']);
    const publicKey = await subtle.importKey('raw', phoneKey, X25519, true, []);
    return { privateKey, publicKey };
  } catch (error) {
    throw new KeyMissingError(error);
  }
}

/**
 * @param {Uint8Array<ArrayBuffer>} iv
 * @param {string} laptopID
 * @param {Uint8Array} phoneKey
 * @returns {AesGcmParams}
 */
function wrapParams(iv, laptopID, phoneKey) {
  const additionalData = utf8Encoder.encode(`${WRAP_LABEL}${laptopID} ${base64urlEncode(phoneKey)}`);
  return { name: 'AES-GCM', iv, additionalData, tagLength: TAG_BITS };
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
