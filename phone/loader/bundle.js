// Assembles the app bundle from `bundle.chunk` messages (plan 3 change 3): chunks arrive in
// index order, `size` counts the compressed bytes, and `sha256` hashes the inflated bytes.
// Nothing comes out of an assembler until `finish()` has inflated the bundle, checked its
// hash and decoded it, so a damaged or partial bundle never reaches the cache.

import { MAX_BUNDLE_COMPRESSED, MAX_BUNDLE_TEXT, MAX_CHUNK_BYTES } from './constants.js';

/**
 * Why a bundle was refused.
 * - `welcome`: the assembler was given a bad `sha256` or `size`.
 * - `sha256`: a chunk names another bundle.
 * - `count`: a chunk's `count` differs from the first chunk's, or exceeds `size`.
 * - `order`: a chunk's `index` is not the number of chunks received so far.
 * - `base64`: a chunk's `data` is not strict base64.
 * - `chunkSize`: a chunk decodes to no bytes or more than MAX_CHUNK_BYTES.
 * - `size`: the compressed total passes `size`, or falls short of it at the last chunk.
 * - `tooLarge`: the compressed total passes MAX_BUNDLE_COMPRESSED, or the inflated bundle
 *   passes MAX_BUNDLE_TEXT.
 * - `incomplete`: `finish()` before the last chunk.
 * - `state`: a chunk after the last one or after a failure, or a second `finish()`.
 * - `inflate`: the compressed bytes do not inflate, such as a cut-off or corrupt stream.
 * - `hash`: the inflated bytes do not hash to `sha256`.
 * - `utf8`: the inflated bytes are not UTF-8.
 * @typedef {'welcome' | 'sha256' | 'count' | 'order' | 'base64' | 'chunkSize' | 'size' | 'tooLarge'
 *   | 'incomplete' | 'state' | 'inflate' | 'hash' | 'utf8'} BundleErrorReason
 */

/** @typedef {import('./protocol.js').ChunkMessage} ChunkMessage */

const SHA256_HEX = /^[0-9a-f]{64}$/;
const STRICT_BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
// Compressed bytes are fed to the decompressor this many at a time, one slice in flight. A
// browser inflates each written chunk whole before the reader can stop it, so the slice bounds
// how far past `maxBytes` one step can go: raw deflate expands at most about 1,032 times, so
// 4 KiB yields at most about 4 MiB.
const INFLATE_SLICE_BYTES = 4096;

export class BundleError extends Error {
  /** @param {BundleErrorReason} reason */
  constructor(reason) {
    super(`bundle: ${reason}`);
    this.name = 'BundleError';
    /** @readonly */
    this.reason = reason;
  }
}

export class BundleAssembler {
  #sha256;
  #size;
  /** @type {Uint8Array[]} */
  #chunks = [];
  #received = 0;
  #total = 0;
  /** @type {number | null} */
  #count = null;
  /** @type {'receiving' | 'complete' | 'finishing' | 'done' | 'failed'} */
  #state = 'receiving';

  /**
   * @param {{ sha256: string, size: number }} bundle the `bundle` of a parsed `welcome`
   * @throws {BundleError}
   */
  constructor({ sha256, size }) {
    if (typeof sha256 !== 'string' || !SHA256_HEX.test(sha256)
      || !Number.isInteger(size) || size < 1 || size > MAX_BUNDLE_COMPRESSED) {
      throw new BundleError('welcome');
    }
    this.#sha256 = sha256;
    this.#size = size;
  }

  /**
   * Adds the next chunk. Any failure leaves the assembler failed, holding no chunks.
   * @param {ChunkMessage} chunk a parsed `bundle.chunk`
   * @returns {boolean} true when this was the last chunk
   * @throws {BundleError}
   */
  add(chunk) {
    if (this.#state !== 'receiving') {
      throw this.#fail('state');
    }
    if (chunk.sha256 !== this.#sha256) throw this.#fail('sha256');
    // Every chunk carries at least one byte, so a count above `size` can never complete.
    if (this.#count === null && chunk.count > this.#size) throw this.#fail('count');
    if (this.#count !== null && chunk.count !== this.#count) throw this.#fail('count');
    if (chunk.index !== this.#received) throw this.#fail('order');
    let bytes;
    try {
      bytes = base64ToBytes(chunk.data);
    } catch (error) {
      throw this.#fail(error instanceof BundleError ? error.reason : 'base64');
    }
    if (bytes.length < 1 || bytes.length > MAX_CHUNK_BYTES) throw this.#fail('chunkSize');
    const total = this.#total + bytes.length;
    if (total > this.#size) throw this.#fail('size');
    if (total > MAX_BUNDLE_COMPRESSED) throw this.#fail('tooLarge');
    const last = chunk.index === chunk.count - 1;
    if (last && total !== this.#size) throw this.#fail('size');

    this.#count = chunk.count;
    this.#chunks.push(bytes);
    this.#received += 1;
    this.#total = total;
    if (last) {
      this.#state = 'complete';
    }
    return last;
  }

  /**
   * Inflates the bundle, checks its SHA-256 against the welcome's and only then decodes it.
   * One-shot: a second call, or any call after a failure, rejects with `state`.
   * @returns {Promise<string>} the bundle text, with any leading U+FEFF kept
   * @throws {BundleError}
   */
  async finish() {
    if (this.#state !== 'complete') {
      throw this.#fail(this.#state === 'receiving' ? 'incomplete' : 'state');
    }
    this.#state = 'finishing';
    const compressed = concat(this.#chunks, this.#total);
    this.#chunks = [];
    try {
      const inflated = await inflateRaw(compressed);
      if (await sha256Hex(inflated) !== this.#sha256) {
        throw new BundleError('hash');
      }
      let text;
      try {
        // `ignoreBOM` keeps a leading U+FEFF, so the runner, which re-encodes the text and
        // hashes it, gets the bytes that were hashed here.
        text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(inflated);
      } catch {
        throw new BundleError('utf8');
      }
      // A chunk that arrived while this ran failed the assembler; its text is not used.
      if (this.#state !== 'finishing') {
        throw new BundleError('state');
      }
      this.#state = 'done';
      return text;
    } catch (error) {
      throw this.#fail(error instanceof BundleError ? error.reason : 'inflate');
    }
  }

  /**
   * @param {BundleErrorReason} reason
   * @returns {BundleError}
   */
  #fail(reason) {
    this.#state = 'failed';
    this.#chunks = [];
    return new BundleError(reason);
  }
}

/**
 * Inflates raw-deflate bytes through `DecompressionStream('deflate-raw')`, feeding the input
 * in slices and reading the output as it comes. As soon as the output passes `maxBytes` it
 * cancels the reader, having kept at most `maxBytes`. In a browser the stream transforms a
 * slice only when the reader wants more, so it holds at most one slice's output beyond what
 * was read.
 * The hash, not this function, is what proves the bytes: whether bytes after the end of the
 * deflate stream are an error differs between engines.
 * @param {Uint8Array} bytes
 * @param {number} [maxBytes]
 * @returns {Promise<Uint8Array>}
 * @throws {BundleError} `tooLarge`, or `inflate` for bytes that do not inflate
 */
export async function inflateRaw(bytes, maxBytes = MAX_BUNDLE_TEXT) {
  const stream = new DecompressionStream('deflate-raw');
  const writer = stream.writable.getWriter();
  const reader = stream.readable.getReader();
  // A failed or cancelled stream rejects these writes; the reader reports why.
  feed(writer, bytes).catch(() => {});

  /** @type {Uint8Array[]} */
  const pieces = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        throw new BundleError('tooLarge');
      }
      pieces.push(value);
    }
  } catch (error) {
    reader.cancel().catch(() => {});
    throw error instanceof BundleError ? error : new BundleError('inflate');
  }
  return concat(pieces, total);
}

/**
 * Writes `bytes` in INFLATE_SLICE_BYTES slices, each after the last was taken, then closes.
 * @param {WritableStreamDefaultWriter<BufferSource>} writer
 * @param {Uint8Array} bytes
 */
async function feed(writer, bytes) {
  for (let at = 0; at < bytes.length; at += INFLATE_SLICE_BYTES) {
    await writer.write(/** @type {Uint8Array<ArrayBuffer>} */ (bytes.subarray(at, at + INFLATE_SLICE_BYTES)));
  }
  await writer.close();
}

/**
 * @param {Uint8Array} bytes
 * @returns {Promise<string>} lowercase hex
 */
export async function sha256Hex(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', /** @type {Uint8Array<ArrayBuffer>} */ (bytes)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

/**
 * Strict standard base64: only `A-Z a-z 0-9 + /`, at most two `=` at the end, and a length that
 * is a multiple of 4. No whitespace, which `atob` would skip.
 * @param {string} s
 * @returns {Uint8Array}
 * @throws {BundleError} `base64`
 */
export function base64ToBytes(s) {
  if (typeof s !== 'string' || !STRICT_BASE64.test(s) || s.length % 4 !== 0) {
    throw new BundleError('base64');
  }
  let binary;
  try {
    binary = atob(s);
  } catch {
    throw new BundleError('base64');
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * @param {Uint8Array[]} pieces
 * @param {number} total their summed length
 * @returns {Uint8Array}
 */
function concat(pieces, total) {
  const out = new Uint8Array(total);
  let at = 0;
  for (const piece of pieces) {
    out.set(piece, at);
    at += piece.length;
  }
  return out;
}
