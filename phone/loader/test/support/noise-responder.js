// A test-only Noise responder (the laptop's side) for Noise_IK and Noise_IKpsk2 with
// 25519, AESGCM and SHA256. It is written from the Noise specification (revision 34,
// sections 5 and 9), not from the loader's initiator in ../../channel/noise.js, so the two
// cannot share a silent handshake bug: both are checked against the cacophony vectors.
// After the handshake it hands its split keys to plan 1's createTransport.
//
//   IK:      <- s   ...   -> e, es, s, ss   <- e, ee, se
//   IKpsk2:  <- s   ...   -> e, es, s, ss   <- e, ee, se, psk

import { NoiseError, createTransport } from '../../channel/noise.js';
import { dh as x25519, generatePair } from './x25519.js';

/** @typedef {import('./x25519.js').KeyPairWithRaw} KeyPairWithRaw */
/** @typedef {import('../../channel/noise.js').NoiseTransport} NoiseTransport */

/**
 * The symmetric state of Noise section 5.2, with its cipher state (section 5.1) inline.
 * @typedef {{ h: Uint8Array, ck: Uint8Array, k: Uint8Array | null, n: bigint }} SymmetricState
 */

/**
 * @typedef {object} Responder
 * @property {(message: Uint8Array) => Promise<{ remoteStatic: Uint8Array, payload: Uint8Array }>} readMessage1
 * @property {(payload: Uint8Array) => Promise<{ message: Uint8Array, transport: NoiseTransport, handshakeHash: Uint8Array }>} writeMessage2
 */

const subtle = globalThis.crypto.subtle;
const HASHLEN = 32;
const DHLEN = 32;
const TAGLEN = 16;
const PSKLEN = 32;
const EMPTY = new Uint8Array(0);

/**
 * @param {{ pattern: 'IK' | 'IKpsk2', localStatic: KeyPairWithRaw, psk?: Uint8Array | null,
 *           prologue: Uint8Array, ephemeral?: KeyPairWithRaw | null }} options
 *   `localStatic` and `ephemeral` come from x25519.js; a fresh ephemeral is made for
 *   message 2 when none is given.
 * @returns {Promise<Responder>}
 */
export async function createResponder({ pattern, localStatic, psk = null, prologue, ephemeral = null }) {
  if (pattern !== 'IK' && pattern !== 'IKpsk2') {
    throw new RangeError(`unknown handshake pattern ${String(pattern)}`);
  }
  const usesPSK = pattern === 'IKpsk2';
  if (usesPSK ? !(psk instanceof Uint8Array) || psk.length !== PSKLEN : psk !== null) {
    throw new NoiseError('invalidPSK');
  }
  requireBytes(prologue, 'the prologue');

  // InitializeSymmetric(protocol_name), then MixHash(prologue), then the pre-message `<- s`.
  const name = new TextEncoder().encode(`Noise_${pattern}_25519_AESGCM_SHA256`);
  let h;
  if (name.length <= HASHLEN) {
    h = new Uint8Array(HASHLEN);
    h.set(name);
  } else {
    h = await sha256(name);
  }
  /** @type {SymmetricState} */
  let state = { h, ck: h.slice(), k: null, n: 0n };
  state = await mixHash(state, prologue);
  state = await mixHash(state, localStatic.publicRaw);

  /** @type {'initial' | 'reading' | 'afterMessage1' | 'writing' | 'complete' | 'failed'} */
  let phase = 'initial';
  /** @type {Uint8Array | null} */ let re = null;
  /** @type {Uint8Array | null} */ let rs = null;

  return Object.freeze({
    /**
     * Reads `e, es, s, ss` and the payload. It works on a copy of the state and keeps the
     * copy only on success, so a failed read changes nothing and a later message 1 can
     * still be read.
     * @param {Uint8Array} message
     */
    async readMessage1(message) {
      requireBytes(message, 'message 1');
      if (phase !== 'initial') throw new NoiseError('invalidState');
      phase = 'reading';
      try {
        // e, s with its tag, and at least the payload's tag. A shorter message cannot
        // decrypt, so it fails as a decrypt does.
        if (message.length < DHLEN + DHLEN + TAGLEN + TAGLEN) throw new NoiseError('decryptFailed');
        let s = { ...state };
        const theirEphemeral = message.slice(0, DHLEN);
        s = await mixHash(s, theirEphemeral);
        if (usesPSK) s = await mixKey(s, theirEphemeral);
        s = await mixKey(s, await dh(localStatic.pair.privateKey, theirEphemeral)); // es
        const sealedStatic = message.slice(DHLEN, DHLEN + DHLEN + TAGLEN);
        const opened = await decryptAndHash(s, sealedStatic); // s
        s = opened.state;
        const theirStatic = opened.plaintext;
        s = await mixKey(s, await dh(localStatic.pair.privateKey, theirStatic)); // ss
        const payload = await decryptAndHash(s, message.slice(DHLEN + DHLEN + TAGLEN));
        state = payload.state;
        re = theirEphemeral;
        rs = theirStatic;
        phase = 'afterMessage1';
        return { remoteStatic: theirStatic.slice(), payload: payload.plaintext };
      } catch (error) {
        phase = 'initial';
        throw error;
      }
    },

    /**
     * Writes `e, ee, se` (and `psk` for IKpsk2) and the payload, then splits.
     * @param {Uint8Array} payload
     */
    async writeMessage2(payload) {
      requireBytes(payload, 'the message 2 payload');
      if (phase !== 'afterMessage1' || re === null || rs === null) throw new NoiseError('invalidState');
      phase = 'writing';
      try {
        const e = ephemeral ?? (await generatePair());
        let s = state;
        s = await mixHash(s, e.publicRaw);
        if (usesPSK) s = await mixKey(s, e.publicRaw);
        s = await mixKey(s, await dh(e.pair.privateKey, re)); // ee
        s = await mixKey(s, await dh(e.pair.privateKey, rs)); // se
        if (usesPSK) s = await mixKeyAndHash(s, /** @type {Uint8Array} */ (psk));
        const sealed = await encryptAndHash(s, payload);
        s = sealed.state;
        const message = new Uint8Array(DHLEN + sealed.ciphertext.length);
        message.set(e.publicRaw);
        message.set(sealed.ciphertext, DHLEN);
        // Split(): the initiator sends with the first key, so the responder receives with it.
        const [first, second] = await hkdf(s.ck, EMPTY, 2);
        const transport = await createTransport({ sendKey: second, receiveKey: first });
        state = s;
        phase = 'complete';
        return { message, transport, handshakeHash: s.h.slice() };
      } catch (error) {
        phase = 'failed';
        throw error;
      }
    },
  });
}

/**
 * MixHash: h = HASH(h || data).
 * @param {SymmetricState} s
 * @param {Uint8Array} data
 * @returns {Promise<SymmetricState>}
 */
async function mixHash(s, data) {
  return { ...s, h: await sha256(concat(s.h, data)) };
}

/**
 * MixKey: ck, temp_k = HKDF(ck, ikm, 2); the cipher key becomes temp_k with n = 0.
 * @param {SymmetricState} s
 * @param {Uint8Array} ikm
 * @returns {Promise<SymmetricState>}
 */
async function mixKey(s, ikm) {
  const [ck, k] = await hkdf(s.ck, ikm, 2);
  return { ...s, ck, k, n: 0n };
}

/**
 * MixKeyAndHash: ck, temp_h, temp_k = HKDF(ck, ikm, 3); MixHash(temp_h); key temp_k, n = 0.
 * @param {SymmetricState} s
 * @param {Uint8Array} ikm
 * @returns {Promise<SymmetricState>}
 */
async function mixKeyAndHash(s, ikm) {
  const [ck, tempH, k] = await hkdf(s.ck, ikm, 3);
  const mixed = await mixHash({ ...s, ck }, tempH);
  return { ...mixed, k, n: 0n };
}

/**
 * EncryptAndHash: with a key, AES-GCM with h as associated data; without one, the identity.
 * Then MixHash(ciphertext).
 * @param {SymmetricState} s
 * @param {Uint8Array} plaintext
 * @returns {Promise<{ state: SymmetricState, ciphertext: Uint8Array }>}
 */
async function encryptAndHash(s, plaintext) {
  let ciphertext = plaintext.slice();
  let n = s.n;
  if (s.k !== null) {
    const key = await subtle.importKey('raw', s.k, 'AES-GCM', false, ['encrypt']);
    ciphertext = new Uint8Array(await subtle.encrypt(gcm(n, s.h), key, plaintext));
    n += 1n;
  }
  const state = await mixHash({ ...s, n }, ciphertext);
  return { state, ciphertext };
}

/**
 * DecryptAndHash, the inverse of encryptAndHash. A failed tag check is `decryptFailed`.
 * @param {SymmetricState} s
 * @param {Uint8Array} ciphertext
 * @returns {Promise<{ state: SymmetricState, plaintext: Uint8Array }>}
 */
async function decryptAndHash(s, ciphertext) {
  let plaintext = ciphertext.slice();
  let n = s.n;
  if (s.k !== null) {
    const key = await subtle.importKey('raw', s.k, 'AES-GCM', false, ['decrypt']);
    try {
      plaintext = new Uint8Array(await subtle.decrypt(gcm(n, s.h), key, ciphertext));
    } catch {
      throw new NoiseError('decryptFailed');
    }
    n += 1n;
  }
  const state = await mixHash({ ...s, n }, ciphertext);
  return { state, plaintext };
}

/**
 * AESGCM's nonce: 32 bits of zeros, then n as a 64-bit big-endian integer. 128-bit tag.
 * @param {bigint} n
 * @param {Uint8Array} ad
 * @returns {AesGcmParams}
 */
function gcm(n, ad) {
  const iv = new Uint8Array(12);
  new DataView(iv.buffer).setBigUint64(4, n, false);
  return { name: 'AES-GCM', iv, additionalData: ad, tagLength: TAGLEN * 8 };
}

/**
 * HKDF of Noise section 4.3, with HMAC-SHA256.
 * @param {Uint8Array} chainingKey
 * @param {Uint8Array} ikm
 * @param {2 | 3} outputs
 * @returns {Promise<Uint8Array[]>}
 */
async function hkdf(chainingKey, ikm, outputs) {
  const tempKey = await hmac(chainingKey, ikm);
  const out1 = await hmac(tempKey, Uint8Array.of(0x01));
  const out2 = await hmac(tempKey, concat(out1, Uint8Array.of(0x02)));
  if (outputs === 2) return [out1, out2];
  const out3 = await hmac(tempKey, concat(out2, Uint8Array.of(0x03)));
  return [out1, out2, out3];
}

/**
 * DH, refusing an all-zero result (a low-order public key) as `invalidPublicKey`. An engine
 * that refuses such a key itself gets the same code.
 * @param {CryptoKey} privateKey
 * @param {Uint8Array} publicRaw
 * @returns {Promise<Uint8Array>}
 */
async function dh(privateKey, publicRaw) {
  let shared;
  try {
    shared = await x25519(privateKey, publicRaw);
  } catch {
    throw new NoiseError('invalidPublicKey');
  }
  if (shared.every((byte) => byte === 0)) throw new NoiseError('invalidPublicKey');
  return shared;
}

/**
 * @param {Uint8Array} key
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array>}
 */
async function hmac(key, data) {
  const hmacKey = await subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await subtle.sign('HMAC', hmacKey, data));
}

/**
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array>}
 */
async function sha256(data) {
  return new Uint8Array(await subtle.digest('SHA-256', data));
}

/**
 * @param {...Uint8Array} parts
 * @returns {Uint8Array}
 */
function concat(...parts) {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/**
 * @param {unknown} value
 * @param {string} name
 * @returns {asserts value is Uint8Array}
 */
function requireBytes(value, name) {
  if (!(value instanceof Uint8Array)) throw new TypeError(`${name} must be a Uint8Array`);
}
