// Noise for the phone channel: the AES-GCM cipher state, the transport and
// the prologue. The rules match the daemon's `NoiseCipherState`,
// `NoiseTransport` and `PhoneChannelPrologue`, and both sides check
// `phone/test-vectors/framing.json`.

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

/** The largest Noise message, which matches the relay's 64 KiB frame limit. */
export const MAX_MESSAGE_LENGTH = 65535;
/** The largest transport plaintext: a full message less the 16-byte tag. */
export const MAX_PLAINTEXT_LENGTH = 65519;

const TAG_BYTES = 16;
const KEY_BYTES = 32;
const ROOM_ID_BYTES = 32;
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
 * Noise's CipherState with the AESGCM cipher, by the daemon's
 * `NoiseCipherState` rules:
 * - with no key, encrypt and decrypt return a copy of their input;
 * - at the reserved nonce, both fail with `nonceExhausted` before any work;
 * - decrypt fails with `messageTooShort` for input shorter than the tag, and
 *   with `decryptFailed` when the tag does not verify;
 * - the nonce advances only when an operation succeeds.
 *
 * Operations run one at a time in call order. Each reads `key` and `nonce`
 * when it starts, after the one before it has settled, so overlapping calls
 * never share a nonce. Inputs are copied when the call is made.
 *
 * `key` and `nonce` are plain fields, so a handshake can save and restore
 * them between operations. Replace `key` with another array; never write
 * into it, because the imported Web Crypto key is cached against it.
 */
class CipherState {
  /** @type {Uint8Array | null} 32 raw bytes, or null for no key */
  key;
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
    if (key !== null && key.length !== KEY_BYTES) {
      throw new RangeError(`a cipher key must be ${KEY_BYTES} bytes, got ${key.length}`);
    }
    if (typeof nonce !== 'bigint' || nonce < 0n || nonce > RESERVED_NONCE) {
      throw new RangeError('a nonce must be a bigint from 0 through 2^64 - 1');
    }
    this.key = key === null ? null : copyBytes(key);
    this.nonce = nonce;
  }

  /**
   * Imports the current key for one usage now, so the first operation does
   * not wait for it. Does nothing without a key.
   * @param {KeyUsage} usage
   * @returns {Promise<void>}
   */
  async prepare(usage) {
    if (this.key !== null) {
      await this.#cryptoKey(this.key, usage);
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
      const { key, nonce } = this;
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
      const { key, nonce } = this;
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
   * replaced or another usage is asked for.
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
