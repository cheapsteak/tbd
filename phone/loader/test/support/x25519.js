// X25519 key helpers for the test-only Noise responder and the scripted laptop. Node only.

import { base64urlDecode } from '../../channel/pairingLink.js';

const subtle = globalThis.crypto.subtle;
const ALGORITHM = { name: 'X25519' };
// RFC 8410: Web Crypto takes a raw X25519 private key only inside this PKCS#8 header.
const PKCS8_PREFIX = Uint8Array.from([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20,
]);
const KEY_BYTES = 32;

/**
 * @typedef {{ pair: CryptoKeyPair, publicRaw: Uint8Array }} KeyPairWithRaw
 */

/**
 * Imports 32 raw private-key bytes, extractable. The public key comes from the exported JWK.
 * @param {Uint8Array} raw32
 * @returns {Promise<KeyPairWithRaw>}
 */
export async function importPair(raw32) {
  if (!(raw32 instanceof Uint8Array) || raw32.length !== KEY_BYTES) {
    throw new RangeError('an X25519 private key is 32 raw bytes');
  }
  const pkcs8 = new Uint8Array(PKCS8_PREFIX.length + KEY_BYTES);
  pkcs8.set(PKCS8_PREFIX);
  pkcs8.set(raw32, PKCS8_PREFIX.length);
  const privateKey = await subtle.importKey('pkcs8', pkcs8, ALGORITHM, true, ['deriveBits']);
  const jwk = await subtle.exportKey('jwk', privateKey);
  const publicRaw = typeof jwk.x === 'string' ? base64urlDecode(jwk.x) : null;
  if (publicRaw === null || publicRaw.length !== KEY_BYTES) {
    throw new Error('the exported JWK has no usable public key');
  }
  const publicKey = await subtle.importKey('raw', publicRaw, ALGORITHM, true, []);
  return { pair: { privateKey, publicKey }, publicRaw };
}

/**
 * A fresh, extractable key pair.
 * @returns {Promise<KeyPairWithRaw>}
 */
export async function generatePair() {
  const pair = /** @type {CryptoKeyPair} */ (await subtle.generateKey(ALGORITHM, true, ['deriveBits']));
  const publicRaw = new Uint8Array(await subtle.exportKey('raw', pair.publicKey));
  return { pair, publicRaw };
}

/**
 * The X25519 shared secret. It is returned as computed; the caller decides what an
 * all-zero result means.
 * @param {CryptoKey} privateKey
 * @param {Uint8Array} publicRaw 32 bytes
 * @returns {Promise<Uint8Array>}
 */
export async function dh(privateKey, publicRaw) {
  const publicKey = await subtle.importKey('raw', publicRaw, ALGORITHM, false, []);
  return new Uint8Array(await subtle.deriveBits({ name: 'X25519', public: publicKey }, privateKey, KEY_BYTES * 8));
}
