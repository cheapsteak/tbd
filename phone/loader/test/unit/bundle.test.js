import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

import { BundleAssembler, BundleError, base64ToBytes, inflateRaw, sha256Hex } from '../../bundle.js';
import { MAX_BUNDLE_COMPRESSED, MAX_BUNDLE_TEXT, MAX_CHUNK_BYTES } from '../../constants.js';

/** @param {Uint8Array | string} data */
const sha256 = (data) => createHash('sha256').update(data).digest('hex');

/**
 * A bundle as the laptop sends it: `welcome.bundle` and its `bundle.chunk` messages.
 * @param {Uint8Array | string} content the inflated bundle, text or bytes
 * @param {{ chunkSize?: number, hash?: string, compressed?: Uint8Array }} [options]
 */
function makeBundle(content, { chunkSize = MAX_CHUNK_BYTES, hash = sha256(content), compressed } = {}) {
  const raw = compressed ?? new Uint8Array(deflateRawSync(content));
  const count = Math.ceil(raw.length / chunkSize);
  const chunks = Array.from({ length: count }, (_, index) => ({
    type: /** @type {const} */ ('bundle.chunk'),
    sha256: hash,
    index,
    count,
    data: Buffer.from(raw.subarray(index * chunkSize, (index + 1) * chunkSize)).toString('base64'),
  }));
  return { welcome: { sha256: hash, size: raw.length }, chunks, raw };
}

/**
 * Feeds every chunk and returns the assembler, asserting only the last one completes it.
 * @param {ReturnType<typeof makeBundle>} bundle
 */
function assemble({ welcome, chunks }) {
  const assembler = new BundleAssembler(welcome);
  chunks.forEach((chunk, i) => assert.equal(assembler.add(chunk), i === chunks.length - 1));
  return assembler;
}

/**
 * @param {() => unknown} fn
 * @param {string} reason
 */
function throwsReason(fn, reason) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof BundleError, String(error));
    assert.equal(error.reason, reason);
    return true;
  });
}

/**
 * @param {Promise<unknown>} promise
 * @param {string} reason
 */
async function rejectsReason(promise, reason) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof BundleError, String(error));
    assert.equal(error.reason, reason);
    return true;
  });
}

/** 300,000 characters that deflate to several chunks. */
const BIG_TEXT = randomBytes(225_000).toString('base64');

test('a 300,000-byte bundle split at 45,000 bytes assembles to its text', async () => {
  assert.equal(BIG_TEXT.length, 300_000);
  const bundle = makeBundle(BIG_TEXT);
  assert.ok(bundle.chunks.length >= 4, `${bundle.chunks.length} chunks`);
  assert.ok(bundle.chunks.slice(0, -1).every((c) => Buffer.from(c.data, 'base64').length === MAX_CHUNK_BYTES));
  assert.equal(await assemble(bundle).finish(), BIG_TEXT);
});

test('a one-chunk bundle and a one-byte-per-chunk bundle assemble', async () => {
  const text = 'globalThis.app = "é😀";\n';
  assert.equal(await assemble(makeBundle(text)).finish(), text);
  const bundle = makeBundle(text, { chunkSize: 1 });
  assert.equal(bundle.chunks.length, bundle.welcome.size);
  assert.equal(await assemble(bundle).finish(), text);
});

test('many small chunks of uneven sizes assemble to the bundle', async () => {
  // Random text barely compresses, so this is thousands of chunks.
  const text = randomBytes(12_000).toString('base64');
  const raw = new Uint8Array(deflateRawSync(text));
  const hash = sha256(text);
  /** @type {Uint8Array[]} */
  const pieces = [];
  for (let at = 0, size = 1; at < raw.length; at += size, size = (size % 7) + 1) {
    pieces.push(raw.subarray(at, at + size));
  }
  assert.ok(pieces.length > 2_000, `${pieces.length} chunks`);
  const chunks = pieces.map((piece, index) => ({
    type: /** @type {const} */ ('bundle.chunk'), sha256: hash, index, count: pieces.length,
    data: Buffer.from(piece).toString('base64'),
  }));
  assert.equal(await assemble({ welcome: { sha256: hash, size: raw.length }, chunks, raw }).finish(), text);

  const ones = makeBundle(text, { chunkSize: 1 });
  assert.equal(ones.chunks.length, ones.welcome.size);
  assert.ok(ones.chunks.length > 2_000);
  assert.equal(await assemble(ones).finish(), text);
});

test('a bundle that starts with a byte-order mark keeps it, so the runner\'s hash matches', async () => {
  const text = '﻿globalThis.app = 1;\n';
  const bundle = makeBundle(text);
  const out = await assemble(bundle).finish();
  assert.equal(out, text);
  assert.equal(out.charCodeAt(0), 0xfeff);
  assert.equal(await sha256Hex(new TextEncoder().encode(out)), bundle.welcome.sha256);
});

test('the welcome must name a bundle', () => {
  const ok = { sha256: 'ab'.repeat(32), size: 10 };
  assert.doesNotThrow(() => new BundleAssembler(ok));
  assert.doesNotThrow(() => new BundleAssembler({ ...ok, size: MAX_BUNDLE_COMPRESSED }));
  for (const bad of [
    { ...ok, sha256: 'AB'.repeat(32) }, { ...ok, sha256: 'ab'.repeat(31) }, { ...ok, sha256: /** @type {any} */ (null) },
    { ...ok, size: 0 }, { ...ok, size: 1.5 }, { ...ok, size: MAX_BUNDLE_COMPRESSED + 1 }, { ...ok, size: /** @type {any} */ ('10') },
  ]) {
    throwsReason(() => new BundleAssembler(bad), 'welcome');
  }
});

test('each chunk must name the welcome\'s bundle', () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  const assembler = new BundleAssembler(welcome);
  assembler.add(chunks[0]);
  throwsReason(() => assembler.add({ ...chunks[1], sha256: 'cd'.repeat(32) }), 'sha256');
});

test('count is the same on every chunk, and no more than size', () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  const assembler = new BundleAssembler(welcome);
  assembler.add(chunks[0]);
  throwsReason(() => assembler.add({ ...chunks[1], count: chunks[1].count + 1 }), 'count');

  const small = makeBundle('x'.repeat(100), { chunkSize: 1 });
  throwsReason(() => new BundleAssembler(small.welcome).add({ ...small.chunks[0], count: small.welcome.size + 1 }), 'count');
});

test('chunks arrive in index order', () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  throwsReason(() => new BundleAssembler(welcome).add(chunks[1]), 'order');
  const repeat = new BundleAssembler(welcome);
  repeat.add(chunks[0]);
  throwsReason(() => repeat.add(chunks[0]), 'order');
  const skip = new BundleAssembler(welcome);
  skip.add(chunks[0]);
  throwsReason(() => skip.add(chunks[2]), 'order');
});

test('chunk data is strict base64 of 1 to 45,000 bytes', () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  throwsReason(() => new BundleAssembler(welcome).add({ ...chunks[0], data: `${chunks[0].data}\n` }), 'base64');
  throwsReason(() => new BundleAssembler(welcome).add({ ...chunks[0], data: '' }), 'chunkSize');

  const tooBig = makeBundle(BIG_TEXT, { chunkSize: MAX_CHUNK_BYTES + 1 });
  throwsReason(() => new BundleAssembler(tooBig.welcome).add(tooBig.chunks[0]), 'chunkSize');
});

test('the compressed total never passes size and equals it at the last chunk', () => {
  const bundle = makeBundle(BIG_TEXT);
  const { welcome, chunks } = bundle;
  // Size one byte short: the last chunk passes it.
  const short = new BundleAssembler({ ...welcome, size: welcome.size - 1 });
  chunks.slice(0, -1).forEach((chunk) => short.add(chunk));
  throwsReason(() => short.add(chunks.at(-1)), 'size');
  // Size one byte long: the last chunk falls short of it.
  const long = new BundleAssembler({ ...welcome, size: welcome.size + 1 });
  chunks.slice(0, -1).forEach((chunk) => long.add(chunk));
  throwsReason(() => long.add(chunks.at(-1)), 'size');
  // A size smaller than the first chunk fails on that chunk, before any later one arrives.
  throwsReason(() => new BundleAssembler({ ...welcome, size: 1000 }).add({ ...chunks[0], count: 2 }), 'size');
});

test('the inflated bytes must hash to sha256, checked before decoding', async () => {
  const text = 'globalThis.app = 1;\n';
  await rejectsReason(assemble(makeBundle(text, { hash: sha256('something else') })).finish(), 'hash');
  // Not UTF-8 and the wrong hash: the hash fails first.
  const notUTF8 = Uint8Array.of(0x61, 0xff, 0x62);
  await rejectsReason(assemble(makeBundle(notUTF8, { hash: sha256('a') })).finish(), 'hash');
  // Not UTF-8 with the right hash: decoding fails.
  await rejectsReason(assemble(makeBundle(notUTF8)).finish(), 'utf8');
});

test('bytes that are not one complete deflate stream fail to inflate', async () => {
  const raw = new Uint8Array(deflateRawSync('globalThis.app = 1;\n'.repeat(50)));
  await rejectsReason(assemble(makeBundle('x', { compressed: raw.subarray(0, raw.length - 4) })).finish(), 'inflate');
  await rejectsReason(assemble(makeBundle('x', { compressed: Uint8Array.of(0xff, 0xff, 0xff, 0xff) })).finish(), 'inflate');
});

test('an inflated bundle over 16 MiB is too large', async () => {
  const text = 'a'.repeat(MAX_BUNDLE_TEXT + 1);
  await rejectsReason(assemble(makeBundle(text)).finish(), 'tooLarge');
  await rejectsReason(assemble(makeBundle('a'.repeat(17 * 1024 * 1024))).finish(), 'tooLarge');
  const atCap = new Uint8Array(MAX_BUNDLE_TEXT).fill(0x61);
  assert.equal((await inflateRaw(new Uint8Array(deflateRawSync(atCap)))).length, MAX_BUNDLE_TEXT);
});

test('inflateRaw takes up to maxBytes and refuses one byte more', async () => {
  const raw = new Uint8Array(deflateRawSync(Buffer.alloc(100_000, 7)));
  assert.equal((await inflateRaw(raw, 100_000)).length, 100_000);
  await rejectsReason(inflateRaw(raw, 99_999), 'tooLarge');
});

/**
 * Swaps in a stand-in DecompressionStream for one test. It is a plain TransformStream, which is
 * how browsers gate DecompressionStream: a written chunk is transformed only once the reader
 * wants more. Each input byte becomes 1,024 output bytes, like a deflate bomb.
 * @param {(stats: { consumed: number, produced: number }) => Promise<void>} body
 */
async function withExpandingStream(body) {
  const real = globalThis.DecompressionStream;
  const stats = { consumed: 0, produced: 0 };
  // @ts-ignore - a stand-in for the test
  globalThis.DecompressionStream = class {
    /** @param {string} format */
    constructor(format) {
      assert.equal(format, 'deflate-raw');
      return new TransformStream({
        transform(chunk, controller) {
          stats.consumed += chunk.byteLength;
          for (let i = 0; i < chunk.byteLength; i += 64) {
            const piece = new Uint8Array(Math.min(64, chunk.byteLength - i) * 1024);
            stats.produced += piece.length;
            controller.enqueue(piece);
          }
        },
      });
    }
  };
  try {
    await body(stats);
  } finally {
    globalThis.DecompressionStream = real;
  }
}

test('inflateRaw feeds the input in slices and stops at the first slice past maxBytes', async () => {
  await withExpandingStream(async (stats) => {
    const input = new Uint8Array(256 * 1024); // would expand to 256 MiB
    await rejectsReason(inflateRaw(input, 1024 * 1024), 'tooLarge');
    await new Promise((resolve) => setTimeout(resolve, 20));
    // One slice (4 KiB, 4 MiB out) is enough to pass 1 MiB; nothing more is fed after it.
    assert.ok(stats.consumed <= 8 * 1024, `consumed ${stats.consumed} of ${input.length}`);
    assert.ok(stats.produced <= 8 * 1024 * 1024, `produced ${stats.produced}`);
  });
});

test('inflateRaw stops reading a real deflate bomb once the output passes maxBytes', async () => {
  const bomb = new Uint8Array(deflateRawSync(Buffer.alloc(64 * 1024 * 1024)));
  let read = 0;
  const real = globalThis.DecompressionStream;
  // @ts-ignore - counts what the reader takes from the real stream
  globalThis.DecompressionStream = class {
    /** @param {CompressionFormat} format */
    constructor(format) {
      const inner = new real(format);
      return {
        writable: inner.writable,
        readable: inner.readable.pipeThrough(new TransformStream({
          transform(chunk, controller) {
            read += chunk.byteLength;
            controller.enqueue(chunk);
          },
        })),
      };
    }
  };
  try {
    await rejectsReason(inflateRaw(bomb, 1024 * 1024), 'tooLarge');
  } finally {
    globalThis.DecompressionStream = real;
  }
  assert.ok(read > 1024 * 1024 && read < 2 * 1024 * 1024, `read ${read}`);
});

test('a failed finish leaves nothing usable', async () => {
  const assembler = assemble(makeBundle('globalThis.app = 1;\n', { hash: sha256('other') }));
  await rejectsReason(assembler.finish(), 'hash');
  await rejectsReason(assembler.finish(), 'state');
});

test('finish is one-shot, and needs every chunk', async () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  const partial = new BundleAssembler(welcome);
  partial.add(chunks[0]);
  await rejectsReason(partial.finish(), 'incomplete');
  // The failed finish also ended the transfer.
  throwsReason(() => partial.add(chunks[1]), 'state');

  const done = assemble({ welcome, chunks });
  assert.equal(await done.finish(), BIG_TEXT);
  await rejectsReason(done.finish(), 'state');
});

test('a chunk after the last one fails the bundle, even while finishing', async () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  const extra = { ...chunks[0], index: chunks.length };
  const complete = assemble({ welcome, chunks });
  throwsReason(() => complete.add(extra), 'state');
  await rejectsReason(complete.finish(), 'state');

  const finishing = assemble({ welcome, chunks });
  const result = finishing.finish();
  throwsReason(() => finishing.add(extra), 'state');
  await rejectsReason(result, 'state');
});

test('a failed chunk fails every later one', () => {
  const { welcome, chunks } = makeBundle(BIG_TEXT);
  const assembler = new BundleAssembler(welcome);
  throwsReason(() => assembler.add(chunks[1]), 'order');
  throwsReason(() => assembler.add(chunks[0]), 'state');
});

test('base64ToBytes is strict', () => {
  assert.deepEqual(base64ToBytes('QUJD'), Uint8Array.of(65, 66, 67));
  assert.deepEqual(base64ToBytes('QUI='), Uint8Array.of(65, 66));
  assert.deepEqual(base64ToBytes('QQ=='), Uint8Array.of(65));
  assert.deepEqual(base64ToBytes('+/+/'), Uint8Array.of(0xfb, 0xff, 0xbf));
  assert.deepEqual(base64ToBytes(''), new Uint8Array(0));
  for (const bad of ['QUJD\n', ' QUJD', 'QU JD', 'QUJ', 'QUJDQ', 'Q===', 'QU=D', '=QUJ', '-_-_', 'QUJD====', 'QUJé']) {
    throwsReason(() => base64ToBytes(bad), 'base64');
  }
});

test('sha256Hex is lowercase hex', async () => {
  assert.equal(await sha256Hex(new Uint8Array(0)), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  assert.equal(await sha256Hex(new TextEncoder().encode(BIG_TEXT)), sha256(BIG_TEXT));
});
