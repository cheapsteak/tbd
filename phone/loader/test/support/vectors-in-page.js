// The channel's shared vectors, run against plan 1's modules wherever they load: in Node by
// vectors-in-page.test.js, and inside WebKit and Chromium by e2e/vectors.spec.js.
//
// The modules and the parsed vector files are passed in, so this file imports nothing: no
// `node:` module, no Buffer, no file reads. In a browser, the page imports the modules from
// the staged site and fetches the files from `/__test/vectors/`.
//
// Each case counts once in `checked`, pass or fail. A failing case adds one line to
// `failures`, which names the case and says what differed; an error thrown inside a case
// counts as that case's failure. A list that is missing counts nothing and is one failure.
// The cases mirror plan 1's own vector tests:
// - each cacophony vector, in the initiator role with its raw keys injected: message 1, the
//   message 2 payload, the handshake hash, and transport messages 2 to 5;
// - each framing message, through a transport made at its nonce, encrypted and decrypted;
// - the prologue;
// - each confirmation code;
// - each base64url valid and invalid text;
// - each valid and invalid pairing link, at the file's `now`.

/**
 * @typedef {object} ChannelVectorInput
 * @property {typeof import('../../channel/noise.js')} noise
 * @property {typeof import('../../channel/confirm.js')} confirm
 * @property {typeof import('../../channel/pairingLink.js')} pairingLink
 * @property {Record<string, any>} files each vector file's parsed JSON, keyed by its name:
 *   `noise-cacophony.json`, `framing.json`, `confirmation-code.json`, `pairing-link.json`
 */

/** @type {Record<string, 'IK' | 'IKpsk2'>} */
const PATTERNS = {
  Noise_IK_25519_AESGCM_SHA256: 'IK',
  Noise_IKpsk2_25519_AESGCM_SHA256: 'IKpsk2',
};
const DECIMAL = /^(0|[1-9][0-9]*)$/;
const HEX = /^(?:[0-9a-fA-F]{2})*$/;

const utf8 = new TextEncoder();

/**
 * Runs every case in the four vector files.
 * @param {ChannelVectorInput} input
 * @returns {Promise<{ failures: string[], checked: number }>}
 */
export async function runChannelVectors({ noise, confirm, pairingLink, files }) {
  /** @type {string[]} */
  const failures = [];
  let checked = 0;

  /**
   * One case: counted, and its first failure recorded under its name.
   * @param {string} name
   * @param {() => Promise<void> | void} body throws to fail
   */
  async function check(name, body) {
    checked += 1;
    try {
      await body();
    } catch (error) {
      failures.push(`${name}: ${describe(error)}`);
    }
  }

  /**
   * One case per item of a vector list, named `<label>[<index>]` and the item's own name.
   * @param {string} label
   * @param {() => unknown} read returns the list
   * @param {(item: any) => Promise<void> | void} body
   */
  async function eachCase(label, read, body) {
    let items;
    try {
      items = read();
    } catch (error) {
      failures.push(`${label}: ${describe(error)}`);
      return;
    }
    if (!Array.isArray(items)) {
      failures.push(`${label}: not a list`);
      return;
    }
    for (const [index, item] of items.entries()) {
      await check(`${label}[${index}]${caseName(item)}`, () => body(item));
    }
  }

  /**
   * @param {string} name
   * @returns {any} the file's parsed JSON
   */
  function file(name) {
    const parsed = files?.[name];
    if (parsed === null || typeof parsed !== 'object') {
      throw new Error(`${name} was not given`);
    }
    return parsed;
  }

  await eachCase('noise-cacophony.json vectors', () => file('noise-cacophony.json').vectors, async (v) => {
    const pattern = PATTERNS[v.protocol_name];
    if (pattern === undefined) {
      throw new Error(`unexpected protocol ${JSON.stringify(v.protocol_name)}`);
    }
    const initiator = await noise.createInitiator({
      pattern,
      localStatic: hex(v.init_static),
      remoteStatic: hex(v.init_remote_static),
      psk: v.init_psks ? hex(v.init_psks[0]) : null,
      prologue: hex(v.init_prologue),
      ephemeral: hex(v.init_ephemeral),
    });
    const m = v.messages;
    expectBytes('message 1', await initiator.writeMessage1(hex(m[0].payload)), hex(m[0].ciphertext));
    const { payload, transport, handshakeHash } = await initiator.readMessage2(hex(m[1].ciphertext));
    expectBytes('message 2 payload', payload, hex(m[1].payload));
    expectBytes('handshake hash', handshakeHash, hex(v.handshake_hash));
    for (let n = 2; n < 6; n += 1) {
      if (n % 2 === 0) {
        expectBytes(`transport message ${n}`, await transport.encrypt(hex(m[n].payload)), hex(m[n].ciphertext));
      } else {
        expectBytes(`transport message ${n}`, await transport.decrypt(hex(m[n].ciphertext)), hex(m[n].payload));
      }
    }
  });

  await eachCase('framing.json messages', () => file('framing.json').messages, async (m) => {
    const key = hex(file('framing.json').key);
    if (typeof m.nonce !== 'string' || !DECIMAL.test(m.nonce)) {
      throw new Error(`nonce ${JSON.stringify(m.nonce)} is not a decimal string`);
    }
    if (typeof m.plaintext !== 'string') {
      throw new Error('plaintext is not a string');
    }
    const nonce = BigInt(m.nonce);
    const transport = await noise.createTransport({ sendKey: key, receiveKey: key, sendNonce: nonce, receiveNonce: nonce });
    const plaintext = utf8.encode(m.plaintext);
    const ciphertext = hex(m.ciphertext);
    expectBytes('encrypt', await transport.encrypt(plaintext), ciphertext);
    expectBytes('decrypt', await transport.decrypt(ciphertext), plaintext);
  });

  await check('framing.json prologue', () => {
    const { prologue } = file('framing.json');
    const roomID = pairingLink.base64urlDecode(prologue.roomID);
    if (roomID === null) {
      throw new Error(`room ID ${JSON.stringify(prologue.roomID)} is not base64url`);
    }
    expectBytes('prologue', noise.phonePrologue(roomID), hex(prologue.prologue));
  });

  await eachCase('confirmation-code.json cases', () => file('confirmation-code.json').cases, async (c) => {
    expectEqual('code', await confirm.confirmationCode(hex(c.handshakeHash)), c.code);
  });

  await eachCase('pairing-link.json base64url.valid', () => file('pairing-link.json').base64url.valid, (c) => {
    const bytes = hex(c.hex);
    expectEqual('encode', pairingLink.base64urlEncode(bytes), c.text);
    const decoded = pairingLink.base64urlDecode(c.text);
    if (decoded === null) {
      throw new Error('decode gave null');
    }
    expectBytes('decode', decoded, bytes);
  });

  await eachCase('pairing-link.json base64url.invalid', () => file('pairing-link.json').base64url.invalid, (text) => {
    if (typeof text !== 'string') {
      throw new Error('the case is not a string');
    }
    const decoded = pairingLink.base64urlDecode(text);
    if (decoded !== null) {
      throw new Error(`decode gave ${toHex(decoded)}, expected null`);
    }
  });

  /** The file's `now`, in milliseconds. */
  const linkNow = () => {
    const { now } = file('pairing-link.json');
    if (typeof now !== 'number' || !Number.isFinite(now)) {
      throw new Error('pairing-link.json has no numeric now');
    }
    return now * 1000;
  };

  await eachCase('pairing-link.json valid', () => file('pairing-link.json').valid, (c) => {
    const link = pairingLink.parsePairingLink(c.url, { now: linkNow() });
    if (!sameJSON(link, c.link)) {
      throw new Error(`parsed ${JSON.stringify(link)}, expected ${JSON.stringify(c.link)}`);
    }
  });

  await eachCase('pairing-link.json invalid', () => file('pairing-link.json').invalid, (c) => {
    const now = linkNow();
    const expected = `${c.error}${c.field === undefined ? '' : `/${c.field}`}`;
    let link;
    try {
      link = pairingLink.parsePairingLink(c.url, { now });
    } catch (error) {
      if (!(error instanceof pairingLink.PairingLinkError)) {
        throw new Error(`threw ${describe(error)}, expected PairingLinkError ${expected}`);
      }
      if (error.code !== c.error || error.field !== c.field) {
        const got = `${error.code}${error.field === undefined ? '' : `/${error.field}`}`;
        throw new Error(`failed with ${got}, expected ${expected}`);
      }
      return;
    }
    throw new Error(`parsed ${JSON.stringify(link)}, expected ${expected}`);
  });

  return { failures, checked };
}

/**
 * The text that names a case after its index: its description, protocol, nonce or text.
 * @param {unknown} item
 */
function caseName(item) {
  if (typeof item === 'string') return ` ${JSON.stringify(item)}`;
  if (item === null || typeof item !== 'object') return '';
  const fields = /** @type {Record<string, unknown>} */ (item);
  if (typeof fields.description === 'string') return ` (${fields.description})`;
  if (typeof fields.protocol_name === 'string') return ` (${fields.protocol_name})`;
  if (typeof fields.nonce === 'string') return ` (nonce ${fields.nonce})`;
  if (typeof fields.text === 'string') return ` ${JSON.stringify(fields.text)}`;
  return '';
}

/**
 * Lowercase or uppercase hex text as bytes. Anything else throws, so a damaged vector fails
 * its case instead of decoding to something.
 * @param {unknown} text
 * @returns {Uint8Array}
 */
function hex(text) {
  if (typeof text !== 'string' || !HEX.test(text)) {
    throw new Error(`not hex: ${JSON.stringify(text)}`);
  }
  const bytes = new Uint8Array(text.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = parseInt(text.slice(2 * i, 2 * i + 2), 16);
  }
  return bytes;
}

/** @param {Uint8Array} bytes */
function toHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * @param {string} what
 * @param {unknown} actual
 * @param {Uint8Array} expected
 */
function expectBytes(what, actual, expected) {
  if (!(actual instanceof Uint8Array)) {
    throw new Error(`${what} is not a Uint8Array`);
  }
  if (actual.length !== expected.length || actual.some((b, i) => b !== expected[i])) {
    throw new Error(`${what} is ${toHex(actual)}, expected ${toHex(expected)}`);
  }
}

/**
 * @param {string} what
 * @param {unknown} actual
 * @param {unknown} expected
 */
function expectEqual(what, actual, expected) {
  if (!Object.is(actual, expected)) {
    throw new Error(`${what} is ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
  }
}

/**
 * Deep equality for JSON values: the same own keys, and equal values under each.
 * @param {unknown} a
 * @param {unknown} b
 * @returns {boolean}
 */
function sameJSON(a, b) {
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') {
    return Object.is(a, b);
  }
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const left = /** @type {Record<string, unknown>} */ (a);
  const right = /** @type {Record<string, unknown>} */ (b);
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length
    && keys.every((key) => Object.prototype.hasOwnProperty.call(right, key) && sameJSON(left[key], right[key]));
}

/** @param {unknown} error */
function describe(error) {
  return error instanceof Error ? `${error.name}: ${error.message}` : String(error);
}
