// Noise for the phone channel: the AES-GCM cipher state, the transport, the
// prologue and the phone's side of the `IKpsk2` and `IK` handshakes (Noise
// revision 34). The rules match the daemon's `NoiseCipherState`,
// `NoiseTransport`, `PhoneChannelPrologue` and `NoiseInitiator`. Both sides
// check `phone/test-vectors/framing.json` and cacophony's vectors in
// `phone/test-vectors/noise-cacophony.json`.

import { base64urlDecode } from './pairingLink.js';

/**
 * The daemon's `NoiseError` case names.
 * @typedef {'decryptFailed' | 'nonceExhausted' | 'messageTooShort' | 'messageTooLong' | 'invalidPublicKey' | 'invalidPSK' | 'invalidRoomID' | 'invalidState'} NoiseErrorCode
 */

/**
 * The send and receive pair once the handshake is done. Each direction runs
 * its calls one at a time in call order, so unawaited sends still go out with
 * consecutive nonces.
 * @typedef {{ encrypt(plaintext: Uint8Array): Promise<Uint8Array>, decrypt(ciphertext: Uint8Array): Promise<Uint8Array> }} NoiseTransport
 */

/**
 * `IKpsk2` pairs a phone; `IK` reconnects a paired one.
 * @typedef {'IKpsk2' | 'IK'} NoisePattern
 */

/**
 * What reading message 2 gives: the responder's payload, the transport, and
 * the handshake hash the confirmation code is made from.
 * @typedef {{ payload: Uint8Array, transport: NoiseTransport, handshakeHash: Uint8Array }} HandshakeResult
 */

/**
 * The phone's side of one handshake: write message 1 once, then read
 * message 2.
 * @typedef {{ writeMessage1(payload: Uint8Array): Promise<Uint8Array>, readMessage2(message: Uint8Array): Promise<HandshakeResult> }} NoiseInitiator
 */

/**
 * The initiator's phases. `writing1` and `reading2` mean a call owns the
 * state until it settles.
 * @typedef {'initial' | 'writing1' | 'afterMessage1' | 'reading2' | 'complete' | 'failed'} InitiatorPhase
 */

/**
 * An X25519 private key, with its public half as raw bytes.
 * @typedef {{ privateKey: CryptoKey, publicKey: Uint8Array<ArrayBuffer> }} DHKeyPair
 */

/** The largest Noise message, which matches the relay's 64 KiB frame limit. */
export const MAX_MESSAGE_LENGTH = 65535;
/** The largest transport plaintext: a full message less the 16-byte tag. */
export const MAX_PLAINTEXT_LENGTH = 65519;

const TAG_BYTES = 16;
const KEY_BYTES = 32;
const ROOM_ID_BYTES = 32;
const DH_BYTES = 32;
const HASH_BYTES = 32;
const PSK_BYTES = 32;
// Message 1 is `e`, the encrypted `s` and the encrypted payload; message 2 is
// `e` and the encrypted payload. Each encryption adds a tag.
const MESSAGE1_OVERHEAD = DH_BYTES + (DH_BYTES + TAG_BYTES) + TAG_BYTES;
const MESSAGE2_OVERHEAD = DH_BYTES + TAG_BYTES;
const MAX_MESSAGE1_PAYLOAD = MAX_MESSAGE_LENGTH - MESSAGE1_OVERHEAD;
const PROTOCOL_NAMES = Object.freeze({
  IKpsk2: 'Noise_IKpsk2_25519_AESGCM_SHA256',
  IK: 'Noise_IK_25519_AESGCM_SHA256',
});
// Web Crypto has no raw import for an X25519 private key, so the 32 bytes go
// in a PKCS#8 wrapper (RFC 8410): this DER header, then the key.
const X25519_PKCS8_PREFIX = Uint8Array.from([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20,
]);
const PROLOGUE_LABEL = 'tbd-phone/1';
// Noise reserves the largest 64-bit counter, so an operation at it fails.
const RESERVED_NONCE = 2n ** 64n - 1n;
const NO_ASSOCIATED_DATA = new Uint8Array(0);

const subtle = globalThis.crypto.subtle;
const utf8Encoder = new TextEncoder();

export class NoiseError extends Error {
  /** @param {NoiseErrorCode} code */
  constructor(code) {
    super(code);
    this.name = 'NoiseError';
    /** @readonly */
    this.code = code;
  }
}

/**
 * The handshake prologue both sides must match byte for byte: UTF-8
 * `tbd-phone/1` followed by the 32 raw room-ID bytes, never their base64url
 * text.
 * @param {Uint8Array} roomID 32 bytes
 * @returns {Uint8Array}
 * @throws {NoiseError} `invalidRoomID` unless the room ID is 32 bytes
 */
export function phonePrologue(roomID) {
  if (roomID.length !== ROOM_ID_BYTES) {
    throw new NoiseError('invalidRoomID');
  }
  const label = utf8Encoder.encode(PROLOGUE_LABEL);
  const prologue = new Uint8Array(label.length + roomID.length);
  prologue.set(label);
  prologue.set(roomID, label.length);
  return prologue;
}

/**
 * Builds a transport from raw keys. The handshake makes one from its split
 * keys; the vector tests make one at any nonce.
 * @param {{ sendKey: Uint8Array, receiveKey: Uint8Array, sendNonce?: bigint, receiveNonce?: bigint }} options
 *   keys are 32 raw bytes, copied; nonces are the next counter in each direction
 * @returns {Promise<NoiseTransport>}
 * @throws {RangeError} for a missing or wrong-size key, or a nonce outside 0 through 2^64 - 1
 */
export async function createTransport({ sendKey, receiveKey, sendNonce = 0n, receiveNonce = 0n }) {
  // A null key would make a cipher state that passes data through unencrypted.
  if (sendKey == null || receiveKey == null) {
    throw new RangeError('a transport needs a send key and a receive key');
  }
  const send = new CipherState(sendKey, sendNonce);
  const receive = new CipherState(receiveKey, receiveNonce);
  await Promise.all([send.prepare('encrypt'), receive.prepare('decrypt')]);
  return Object.freeze({
    /** @param {Uint8Array} plaintext */
    async encrypt(plaintext) {
      if (plaintext.length > MAX_PLAINTEXT_LENGTH) {
        throw new NoiseError('messageTooLong');
      }
      return send.encrypt(NO_ASSOCIATED_DATA, plaintext);
    },
    /** @param {Uint8Array} ciphertext */
    async decrypt(ciphertext) {
      if (ciphertext.length > MAX_MESSAGE_LENGTH) {
        throw new NoiseError('messageTooLong');
      }
      return receive.decrypt(NO_ASSOCIATED_DATA, ciphertext);
    },
  });
}

/**
 * The phone's side of the `IKpsk2` (pairing) or `IK` (reconnect) handshake.
 * Message 1 carries the tokens `e, es, s, ss`; message 2 carries
 * `e, ee, se`, then `psk` for `IKpsk2`. Reading message 2 completes the
 * handshake.
 *
 * Phases advance synchronously when a call is made, before its first await:
 * - A call made while another is in flight rejects `invalidState` and changes
 *   nothing, so it never disturbs the call in flight.
 * - `writeMessage1` works once. Otherwise it rejects `invalidState` and
 *   leaves the initiator failed, as any other rejection of it does; once
 *   failed, every call rejects `invalidState`.
 * - `readMessage2` is atomic. It runs on a copy of the symmetric state (`h`,
 *   `ck`, the cipher's key and nonce) and keeps the copy only on success, so
 *   a rejected frame (a stale one from a replaced peer, say) leaves the state
 *   exactly as it was, and the real message 2 can still be read. The
 *   responder's ephemeral key lives only inside the attempt, and its static
 *   key is fixed at creation. A call in the wrong phase rejects
 *   `invalidState` and changes nothing.
 *
 * Every byte array is copied when it is passed in.
 *
 * @param {{ pattern: NoisePattern, localStatic: CryptoKeyPair | Uint8Array, remoteStatic: CryptoKey | Uint8Array,
 *           psk?: Uint8Array | null, prologue: Uint8Array, ephemeral?: CryptoKeyPair | Uint8Array | null }} options
 *   - `localStatic`: the phone's X25519 key pair, or its 32 raw private-key bytes.
 *   - `remoteStatic`: the laptop's public key, as an extractable X25519
 *     `CryptoKey` or 32 raw bytes.
 *   - `psk`: the 32-byte pairing secret for `IKpsk2`; null or absent for `IK`.
 *   - `prologue`: from `phonePrologue`.
 *   - `ephemeral`: for vector tests only; a fresh key pair is made when absent.
 * @returns {Promise<NoiseInitiator>}
 * @throws {NoiseError} `invalidPSK` when the PSK does not fit the pattern, and
 *   `invalidPublicKey` when raw `remoteStatic` bytes are not 32 long
 * @throws {RangeError} for an unknown pattern, or raw private-key bytes that are not 32 long
 * @throws {TypeError} for a prologue that is not a `Uint8Array`, or a key of the wrong kind
 */
export async function createInitiator({ pattern, localStatic, remoteStatic, psk = null, prologue, ephemeral = null }) {
  if (pattern !== 'IKpsk2' && pattern !== 'IK') {
    throw new RangeError(`unknown handshake pattern ${String(pattern)}`);
  }
  const usesPSK = pattern === 'IKpsk2';
  if (usesPSK ? psk === null || psk.length !== PSK_BYTES : psk !== null) {
    throw new NoiseError('invalidPSK');
  }
  if (!(prologue instanceof Uint8Array)) {
    throw new TypeError('the prologue must be a Uint8Array');
  }
  // Copy every byte input before the first await.
  const pskBytes = psk === null ? null : copyBytes(psk);
  const prologueBytes = copyBytes(prologue);
  const [s, rs, e] = await Promise.all([
    importKeyPair(localStatic, 'localStatic'),
    importRemoteStatic(remoteStatic),
    ephemeral === null ? generateKeyPair() : importKeyPair(ephemeral, 'ephemeral'),
  ]);

  let symmetric = await SymmetricState.initialize(PROTOCOL_NAMES[pattern]);
  await symmetric.mixHash(prologueBytes);
  // The `<- s` pre-message: the phone knows the laptop's static key.
  await symmetric.mixHash(rs.bytes);
  /** @type {InitiatorPhase} */
  let phase = 'initial';

  return Object.freeze({
    /**
     * @param {Uint8Array} payload at most 65,439 bytes
     * @returns {Promise<Uint8Array>} message 1, 96 bytes longer than the payload
     */
    async writeMessage1(payload) {
      if (phase === 'writing1' || phase === 'reading2') {
        throw new NoiseError('invalidState');
      }
      if (phase !== 'initial') {
        phase = 'failed';
        throw new NoiseError('invalidState');
      }
      phase = 'writing1';
      try {
        if (payload.length > MAX_MESSAGE1_PAYLOAD) {
          throw new NoiseError('messageTooLong');
        }
        const input = copyBytes(payload);
        const next = symmetric.copy();
        // e
        await next.mixHash(e.publicKey);
        if (usesPSK) {
          await next.mixKey(e.publicKey);
        }
        // es
        await next.mixKey(await dh(e.privateKey, rs.key));
        // s
        const encryptedStatic = await next.encryptAndHash(s.publicKey);
        // ss
        await next.mixKey(await dh(s.privateKey, rs.key));
        const encryptedPayload = await next.encryptAndHash(input);
        symmetric = next;
        phase = 'afterMessage1';
        return concatBytes(e.publicKey, encryptedStatic, encryptedPayload);
      } catch (error) {
        phase = 'failed';
        throw error;
      }
    },

    /**
     * @param {Uint8Array} message 48 through 65,535 bytes
     * @returns {Promise<HandshakeResult>}
     */
    async readMessage2(message) {
      if (phase !== 'afterMessage1') {
        throw new NoiseError('invalidState');
      }
      phase = 'reading2';
      try {
        if (message.length > MAX_MESSAGE_LENGTH) {
          throw new NoiseError('messageTooLong');
        }
        if (message.length < MESSAGE2_OVERHEAD) {
          throw new NoiseError('messageTooShort');
        }
        const input = copyBytes(message);
        // Every step runs on this copy, and each awaits the one before it, so
        // no operation on the copy is still running when it is kept or dropped.
        const next = symmetric.copy();
        // e
        const remoteEphemeralBytes = input.slice(0, DH_BYTES);
        const remoteEphemeral = await importPublicKey(remoteEphemeralBytes);
        await next.mixHash(remoteEphemeralBytes);
        if (usesPSK) {
          await next.mixKey(remoteEphemeralBytes);
        }
        // ee
        await next.mixKey(await dh(e.privateKey, remoteEphemeral));
        // se
        await next.mixKey(await dh(s.privateKey, remoteEphemeral));
        // psk
        if (pskBytes !== null) {
          await next.mixKeyAndHash(pskBytes);
        }
        const payload = await next.decryptAndHash(input.subarray(DH_BYTES));
        const [sendKey, receiveKey] = await next.split();
        const transport = await createTransport({ sendKey, receiveKey });
        symmetric = next;
        phase = 'complete';
        return { payload, transport, handshakeHash: copyBytes(next.h) };
      } catch (error) {
        // This call owns the state while it is `reading2`: an overlapping call
        // changes nothing, so restoring the phase cannot undo another's work.
        phase = 'afterMessage1';
        throw error;
      }
    },
  });
}

/**
 * Noise's CipherState with the AESGCM cipher, by the daemon's
 * `NoiseCipherState` rules:
 * - with no key, encrypt and decrypt return a copy of their input;
 * - at the reserved nonce, both fail with `nonceExhausted` before any work;
 * - decrypt fails with `messageTooShort` for input shorter than the tag, and
 *   with `decryptFailed` when the tag does not verify;
 * - the nonce advances only when an operation succeeds.
 *
 * Operations run one at a time in call order. Each reads the key and `nonce`
 * when it starts, after the one before it has settled, so overlapping calls
 * never share a nonce. Inputs are copied when the call is made.
 *
 * `key` is an accessor over a private copy: the setter copies the bytes and
 * drops the cached Web Crypto key, and the getter returns a fresh copy, so
 * writing into an array never changes the key in use. `nonce` is a plain
 * field. Save and restore the pair only while no operation is in flight,
 * because a running operation writes `nonce + 1n` when it finishes.
 */
class CipherState {
  /** @type {Uint8Array<ArrayBuffer> | null} 32 raw bytes, or null for no key */
  #key = null;
  /** @type {bigint} the counter the next operation uses */
  nonce;
  #queue = new SerialQueue();
  /** @type {{ key: Uint8Array, usage: KeyUsage, cryptoKey: Promise<CryptoKey> } | null} */
  #imported = null;

  /**
   * @param {Uint8Array | null} key 32 raw bytes, copied; null for no key
   * @param {bigint} [nonce]
   * @throws {RangeError} for a key that is not 32 bytes, or a nonce outside 0 through 2^64 - 1
   */
  constructor(key, nonce = 0n) {
    if (typeof nonce !== 'bigint' || nonce < 0n || nonce > RESERVED_NONCE) {
      throw new RangeError('a nonce must be a bigint from 0 through 2^64 - 1');
    }
    this.key = key;
    this.nonce = nonce;
  }

  /** @returns {Uint8Array<ArrayBuffer> | null} a copy of the 32 key bytes, or null for no key */
  get key() {
    return this.#key === null ? null : copyBytes(this.#key);
  }

  /**
   * @param {Uint8Array | null} key 32 raw bytes, copied; null for no key
   * @throws {RangeError} for a key that is not 32 bytes
   */
  set key(key) {
    if (key !== null && key.length !== KEY_BYTES) {
      throw new RangeError(`a cipher key must be ${KEY_BYTES} bytes, got ${key.length}`);
    }
    this.#key = key === null ? null : copyBytes(key);
    this.#imported = null;
  }

  /**
   * Imports the current key for one usage now, so the first operation does
   * not wait for it. Does nothing without a key.
   * @param {KeyUsage} usage
   * @returns {Promise<void>}
   */
  async prepare(usage) {
    if (this.#key !== null) {
      await this.#cryptoKey(this.#key, usage);
    }
  }

  /**
   * @param {Uint8Array} ad associated data
   * @param {Uint8Array} plaintext
   * @returns {Promise<Uint8Array>} the encrypted bytes followed by the 16-byte tag
   */
  encrypt(ad, plaintext) {
    const associatedData = copyBytes(ad);
    const input = copyBytes(plaintext);
    return this.#queue.run(async () => {
      const key = this.#key;
      const nonce = this.nonce;
      if (key === null) {
        return input;
      }
      if (nonce === RESERVED_NONCE) {
        throw new NoiseError('nonceExhausted');
      }
      const cryptoKey = await this.#cryptoKey(key, 'encrypt');
      const sealed = await subtle.encrypt(gcmParams(nonce, associatedData), cryptoKey, input);
      this.nonce = nonce + 1n;
      return new Uint8Array(sealed);
    });
  }

  /**
   * @param {Uint8Array} ad associated data
   * @param {Uint8Array} ciphertext the encrypted bytes followed by the 16-byte tag
   * @returns {Promise<Uint8Array>}
   */
  decrypt(ad, ciphertext) {
    const associatedData = copyBytes(ad);
    const input = copyBytes(ciphertext);
    return this.#queue.run(async () => {
      const key = this.#key;
      const nonce = this.nonce;
      if (key === null) {
        return input;
      }
      if (nonce === RESERVED_NONCE) {
        throw new NoiseError('nonceExhausted');
      }
      if (input.length < TAG_BYTES) {
        throw new NoiseError('messageTooShort');
      }
      const cryptoKey = await this.#cryptoKey(key, 'decrypt');
      let opened;
      try {
        opened = await subtle.decrypt(gcmParams(nonce, associatedData), cryptoKey, input);
      } catch (error) {
        if (error instanceof DOMException && error.name === 'OperationError') {
          throw new NoiseError('decryptFailed');
        }
        throw error;
      }
      this.nonce = nonce + 1n;
      return new Uint8Array(opened);
    });
  }

  /**
   * The key imported non-extractable for one usage, cached until `key` is
   * set or another usage is asked for. `key` is the private copy, which
   * nothing writes into, so its identity names its bytes.
   * @param {Uint8Array} key
   * @param {KeyUsage} usage
   * @returns {Promise<CryptoKey>}
   */
  #cryptoKey(key, usage) {
    if (this.#imported === null || this.#imported.key !== key || this.#imported.usage !== usage) {
      const cryptoKey = subtle.importKey('raw', copyBytes(key), { name: 'AES-GCM' }, false, [usage]);
      this.#imported = { key, usage, cryptoKey };
    }
    return this.#imported.cryptoKey;
  }
}

/**
 * Runs asynchronous operations one at a time, in call order. Each starts once
 * the one before it settles, whether that succeeded or failed, so a failure
 * never stalls the operations behind it.
 */
class SerialQueue {
  /** @type {Promise<unknown>} */
  #tail = Promise.resolve();

  /**
   * @template T
   * @param {() => Promise<T>} operation
   * @returns {Promise<T>}
   */
  run(operation) {
    const result = this.#tail.then(operation, operation);
    this.#tail = result;
    return result;
  }
}

/**
 * Noise's SymmetricState for SHA-256 (revision 34, section 5.2). `h` and `ck`
 * are replaced, never written into, and each operation awaits the one before
 * it, so `copy()` between calls captures the whole state.
 */
class SymmetricState {
  /**
   * @param {Uint8Array<ArrayBuffer>} h the handshake hash
   * @param {Uint8Array<ArrayBuffer>} ck the chaining key
   * @param {CipherState} cipher
   */
  constructor(h, ck, cipher) {
    this.h = h;
    this.ck = ck;
    this.cipher = cipher;
  }

  /**
   * `h` is the protocol name zero-padded to 32 bytes, or its hash if longer;
   * `ck` starts equal to it, and the cipher has no key.
   * @param {string} protocolName
   * @returns {Promise<SymmetricState>}
   */
  static async initialize(protocolName) {
    const name = utf8Encoder.encode(protocolName);
    let h = new Uint8Array(HASH_BYTES);
    if (name.length <= HASH_BYTES) {
      h.set(name);
    } else {
      h = await sha256(name);
    }
    return new SymmetricState(h, copyBytes(h), new CipherState(null));
  }

  /**
   * An independent copy, with its own cipher state. Call it only while no
   * operation on this state is in flight.
   * @returns {SymmetricState}
   */
  copy() {
    return new SymmetricState(copyBytes(this.h), copyBytes(this.ck), new CipherState(this.cipher.key, this.cipher.nonce));
  }

  /** @param {Uint8Array} data */
  async mixHash(data) {
    this.h = await sha256(concatBytes(this.h, data));
  }

  /** @param {Uint8Array} inputKeyMaterial */
  async mixKey(inputKeyMaterial) {
    const [ck, key] = await hkdf(this.ck, inputKeyMaterial, 2);
    this.ck = ck;
    this.cipher = new CipherState(key);
  }

  /** @param {Uint8Array} inputKeyMaterial */
  async mixKeyAndHash(inputKeyMaterial) {
    const [ck, hashInput, key] = await hkdf(this.ck, inputKeyMaterial, 3);
    this.ck = ck;
    await this.mixHash(hashInput);
    this.cipher = new CipherState(key);
  }

  /**
   * @param {Uint8Array} plaintext
   * @returns {Promise<Uint8Array>}
   */
  async encryptAndHash(plaintext) {
    const ciphertext = await this.cipher.encrypt(this.h, plaintext);
    await this.mixHash(ciphertext);
    return ciphertext;
  }

  /**
   * @param {Uint8Array} ciphertext
   * @returns {Promise<Uint8Array>}
   */
  async decryptAndHash(ciphertext) {
    const plaintext = await this.cipher.decrypt(this.h, ciphertext);
    await this.mixHash(ciphertext);
    return plaintext;
  }

  /**
   * The two transport keys: initiator to responder, then responder to
   * initiator.
   * @returns {Promise<Uint8Array<ArrayBuffer>[]>}
   */
  async split() {
    return hkdf(this.ck, new Uint8Array(0), 2);
  }
}

/**
 * Noise's HKDF over HMAC-SHA256: a temporary key from the chaining key and
 * the input, then each output is the HMAC of the one before it and its
 * 1-based index byte.
 * @param {Uint8Array} chainingKey 32 bytes
 * @param {Uint8Array} inputKeyMaterial
 * @param {2 | 3} outputs
 * @returns {Promise<Uint8Array<ArrayBuffer>[]>}
 */
async function hkdf(chainingKey, inputKeyMaterial, outputs) {
  const tempKey = await hmacSHA256(chainingKey, inputKeyMaterial);
  /** @type {Uint8Array<ArrayBuffer>[]} */
  const results = [];
  let previous = new Uint8Array(0);
  for (let index = 1; index <= outputs; index += 1) {
    previous = await hmacSHA256(tempKey, concatBytes(previous, Uint8Array.of(index)));
    results.push(previous);
  }
  return results;
}

/**
 * HMAC-SHA256. Noise's keys here are always 32 bytes, and Web Crypto refuses
 * an empty HMAC key.
 * @param {Uint8Array} key
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array<ArrayBuffer>>}
 */
async function hmacSHA256(key, data) {
  const hmacKey = await subtle.importKey('raw', copyBytes(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await subtle.sign('HMAC', hmacKey, copyBytes(data)));
}

/**
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array<ArrayBuffer>>}
 */
async function sha256(data) {
  return new Uint8Array(await subtle.digest('SHA-256', copyBytes(data)));
}

/**
 * X25519. Web Crypto fails with `OperationError` when the result is all
 * zeros, which a low-order public key gives; the zero check repeats it, as
 * the daemon does, without stopping at the first non-zero byte.
 * @param {CryptoKey} privateKey
 * @param {CryptoKey} publicKey
 * @returns {Promise<Uint8Array<ArrayBuffer>>}
 * @throws {NoiseError} `invalidPublicKey`
 */
async function dh(privateKey, publicKey) {
  let bits;
  try {
    bits = await subtle.deriveBits({ name: 'X25519', public: publicKey }, privateKey, DH_BYTES * 8);
  } catch (error) {
    if (error instanceof DOMException && error.name === 'OperationError') {
      throw new NoiseError('invalidPublicKey');
    }
    throw error;
  }
  const shared = new Uint8Array(bits);
  let any = 0;
  for (const byte of shared) {
    any |= byte;
  }
  if (shared.length !== DH_BYTES || any === 0) {
    throw new NoiseError('invalidPublicKey');
  }
  return shared;
}

/**
 * Imports 32 raw bytes as an X25519 public key.
 * @param {Uint8Array} bytes
 * @returns {Promise<CryptoKey>}
 * @throws {NoiseError} `invalidPublicKey` when Web Crypto refuses the bytes
 */
async function importPublicKey(bytes) {
  try {
    return await subtle.importKey('raw', copyBytes(bytes), { name: 'X25519' }, true, []);
  } catch (error) {
    if (error instanceof DOMException && error.name === 'DataError') {
      throw new NoiseError('invalidPublicKey');
    }
    throw error;
  }
}

/**
 * The laptop's static key as a `CryptoKey` and as the raw bytes the
 * handshake hash takes in.
 * @param {CryptoKey | Uint8Array} key an extractable X25519 public key, or 32 raw bytes
 * @returns {Promise<{ key: CryptoKey, bytes: Uint8Array<ArrayBuffer> }>}
 */
async function importRemoteStatic(key) {
  if (key instanceof Uint8Array) {
    if (key.length !== DH_BYTES) {
      throw new NoiseError('invalidPublicKey');
    }
    const bytes = copyBytes(key);
    return { key: await importPublicKey(bytes), bytes };
  }
  if (!isX25519Key(key, 'public')) {
    throw new TypeError('remoteStatic must be an X25519 public CryptoKey or 32 raw bytes');
  }
  return { key, bytes: new Uint8Array(await subtle.exportKey('raw', key)) };
}

/**
 * A key pair with its public half as raw bytes. Raw private-key bytes are
 * imported through PKCS#8, and their public half read from the JWK export,
 * because Web Crypto cannot derive a public key from a private `CryptoKey`.
 * @param {CryptoKeyPair | Uint8Array} key
 * @param {string} name the option's name, for errors
 * @returns {Promise<DHKeyPair>}
 */
async function importKeyPair(key, name) {
  if (key instanceof Uint8Array) {
    if (key.length !== DH_BYTES) {
      throw new RangeError(`${name} must be ${DH_BYTES} raw private-key bytes, got ${key.length}`);
    }
    const der = new Uint8Array(X25519_PKCS8_PREFIX.length + DH_BYTES);
    der.set(X25519_PKCS8_PREFIX);
    der.set(key, X25519_PKCS8_PREFIX.length);
    const privateKey = await subtle.importKey('pkcs8', der, { name: 'X25519' }, true, ['deriveBits']);
    const { x } = await subtle.exportKey('jwk', privateKey);
    const publicKey = x === undefined ? null : base64urlDecode(x);
    if (publicKey === null || publicKey.length !== DH_BYTES) {
      throw new TypeError(`${name}: Web Crypto gave no 32-byte public key`);
    }
    return { privateKey, publicKey: copyBytes(publicKey) };
  }
  if (key == null || !isX25519Key(key.privateKey, 'private') || !isX25519Key(key.publicKey, 'public')) {
    throw new TypeError(`${name} must be an X25519 CryptoKeyPair or 32 raw private-key bytes`);
  }
  return { privateKey: key.privateKey, publicKey: new Uint8Array(await subtle.exportKey('raw', key.publicKey)) };
}

/**
 * A fresh ephemeral key pair, whose private half cannot be exported.
 * @returns {Promise<DHKeyPair>}
 */
async function generateKeyPair() {
  const pair = /** @type {CryptoKeyPair} */ (await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']));
  return importKeyPair(pair, 'ephemeral');
}

/**
 * @param {unknown} key
 * @param {KeyType} type
 * @returns {key is CryptoKey}
 */
function isX25519Key(key, type) {
  return key instanceof CryptoKey && key.type === type && key.algorithm.name === 'X25519';
}

/**
 * @param {...Uint8Array} parts
 * @returns {Uint8Array<ArrayBuffer>}
 */
function concatBytes(...parts) {
  const joined = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  return joined;
}

/**
 * AES-GCM parameters for one Noise operation: a 12-byte IV of 4 zero bytes
 * and the counter as a big-endian UInt64, and a 128-bit tag. The IV is a new
 * array that nothing else holds.
 * @param {bigint} nonce
 * @param {Uint8Array<ArrayBuffer>} associatedData
 * @returns {AesGcmParams}
 */
function gcmParams(nonce, associatedData) {
  const iv = new Uint8Array(12);
  new DataView(iv.buffer).setBigUint64(4, nonce, false);
  return { name: 'AES-GCM', iv, additionalData: associatedData, tagLength: TAG_BYTES * 8 };
}

/**
 * Every byte array from a caller reaches Web Crypto through this copy. A
 * fresh array satisfies the `BufferSource` type, which needs an ArrayBuffer
 * rather than any ArrayBufferLike, and a caller that reuses its buffer cannot
 * change the bytes while an operation is queued or running. The copy holds
 * only the view's bytes, so a view into a larger buffer is safe.
 * @param {Uint8Array} bytes
 * @returns {Uint8Array<ArrayBuffer>}
 */
function copyBytes(bytes) {
  return new Uint8Array(bytes);
}
