// IndexedDB storage for paired laptops and cached bundles (spec sections 2 and 9).
//
// Three object stores:
// - `meta`, with out-of-line keys: `'wrapKey'` holds the AES-GCM key that wraps every phone
//   private key (keys.js). Private keys are stored only wrapped.
// - `laptops`: LaptopRecord, keyPath `id`.
// - `bundles`: BundleRecord, keyPath `['laptopID', 'sha256']`, index `byLaptop` on `laptopID`.
//
// Every method runs in one transaction and settles with it: it resolves once the transaction
// commits, and rejects on a request's `error`, the transaction's `error` or `abort`, or an
// exception while it runs (which aborts it, so nothing it wrote is kept). Every record read
// is validated, so a damaged record surfaces as an error, never as missing fields.

import { base64urlDecode, base64urlEncode } from './channel/pairingLink.js';
import {
  CACHED_BUNDLES_PER_LAPTOP, DB_NAME, DB_VERSION, MAX_BUNDLE_COMPRESSED, MAX_BUNDLE_TEXT,
} from './constants.js';
import { createWrapKey } from './keys.js';
import { isRoomID, relaySocketURL } from './links.js';

/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */
/** @typedef {import('./types.js').BundleRecord} BundleRecord */

/**
 * Issues one request inside a transaction. `onSuccess` runs inside the transaction, so it may
 * issue more requests; if it throws, the transaction aborts with that error.
 * @callback Ask
 * @param {IDBRequest} request
 * @param {(result: any) => void} [onSuccess]
 * @returns {void}
 */

const META = 'meta';
const LAPTOPS = 'laptops';
const BUNDLES = 'bundles';
const BY_LAPTOP = 'byLaptop';
const WRAP_KEY = 'wrapKey';

const KEY_BYTES = 32;
const IV_BYTES = 12;
const SHA256_HEX = /^[0-9a-f]{64}$/;

/** Another tab holds the database open at an older version, so this one cannot upgrade it. */
export class StoreBlockedError extends Error {
  constructor() {
    super('the loader database is open in another tab');
    this.name = 'StoreBlockedError';
  }
}

/**
 * Opens the loader's database, creating its stores on first use.
 *
 * A `blocked` open rejects with StoreBlockedError rather than waiting, because the tab
 * holding the database may be suspended and never answer; a connection that opens after that
 * is closed at once. This tab closes its own connection on `versionchange`, so a newer loader
 * in another tab can upgrade; every call on the store then rejects, and the page should
 * reload.
 * @param {IDBFactory} [indexedDB]
 * @returns {Promise<Store>}
 */
export function openStore(indexedDB = globalThis.indexedDB) {
  return new Promise((resolve, reject) => {
    let settled = false;
    /** @type {IDBOpenDBRequest} */
    let request;
    try {
      request = indexedDB.open(DB_NAME, DB_VERSION);
    } catch (error) {
      reject(error);
      return;
    }
    request.onupgradeneeded = (event) => {
      if (event.oldVersion < 1) {
        const db = request.result;
        db.createObjectStore(META);
        db.createObjectStore(LAPTOPS, { keyPath: 'id' });
        db.createObjectStore(BUNDLES, { keyPath: ['laptopID', 'sha256'] }).createIndex(BY_LAPTOP, 'laptopID');
      }
    };
    request.onsuccess = () => {
      const db = request.result;
      if (settled) {
        db.close();
        return;
      }
      settled = true;
      db.onversionchange = () => db.close();
      resolve(new Store(db));
    };
    request.onerror = () => {
      settled = true;
      reject(request.error);
    };
    request.onblocked = () => {
      settled = true;
      reject(new StoreBlockedError());
    };
  });
}

export class Store {
  #db;

  /** @param {IDBDatabase} db from `openStore` */
  constructor(db) {
    this.#db = db;
  }

  /**
   * The wrap key. It is made and stored on first use and never replaced while one is
   * stored, because every wrapped key depends on it. A stored value that is not a
   * `CryptoKey` is no key, so it is replaced. When two tabs race, the first key stored wins.
   * @param {SubtleCrypto} subtle
   * @returns {Promise<CryptoKey>}
   */
  async wrapKey(subtle) {
    const stored = await this.#run([META], 'readonly', (tx, ask) => {
      /** @type {unknown} */
      let value;
      ask(tx.objectStore(META).get(WRAP_KEY), (result) => { value = result; });
      return () => value;
    });
    if (stored instanceof CryptoKey) {
      return stored;
    }
    const fresh = await createWrapKey(subtle);
    return this.#run([META], 'readwrite', (tx, ask) => {
      const meta = tx.objectStore(META);
      let key = fresh;
      ask(meta.get(WRAP_KEY), (result) => {
        if (result instanceof CryptoKey) {
          key = result;
        } else {
          ask(meta.put(fresh, WRAP_KEY));
        }
      });
      return () => key;
    });
  }

  /** @returns {Promise<LaptopRecord[]>} */
  listLaptops() {
    return this.#run([LAPTOPS], 'readonly', (tx, ask) => {
      /** @type {LaptopRecord[]} */
      let records = [];
      ask(tx.objectStore(LAPTOPS).getAll(), (values) => { records = values.map(validateLaptopRecord); });
      return () => records;
    });
  }

  /**
   * @param {string} id
   * @returns {Promise<LaptopRecord | null>}
   */
  getLaptop(id) {
    return this.#run([LAPTOPS], 'readonly', (tx, ask) => {
      /** @type {LaptopRecord | null} */
      let record = null;
      ask(tx.objectStore(LAPTOPS).get(id), (value) => {
        record = value === undefined ? null : validateLaptopRecord(value);
      });
      return () => record;
    });
  }

  /**
   * Adds or replaces a laptop.
   * @param {LaptopRecord} record
   * @returns {Promise<void>}
   * @throws {TypeError} for a record `validateLaptopRecord` refuses, before anything is written
   */
  async putLaptop(record) {
    const valid = validateLaptopRecord(record);
    await this.#run([LAPTOPS], 'readwrite', (tx, ask) => {
      ask(tx.objectStore(LAPTOPS).put(valid));
      return () => undefined;
    });
  }

  /**
   * Records a connection. A laptop forgotten meanwhile stays forgotten.
   * @param {string} id
   * @param {{ lastConnectedAt: number, laptopName: string }} update
   * @returns {Promise<void>}
   */
  async touchLaptop(id, { lastConnectedAt, laptopName }) {
    await this.#run([LAPTOPS], 'readwrite', (tx, ask) => {
      const laptops = tx.objectStore(LAPTOPS);
      ask(laptops.get(id), (value) => {
        if (value !== undefined) {
          ask(laptops.put(validateLaptopRecord({ ...validateLaptopRecord(value), lastConnectedAt, laptopName })));
        }
      });
      return () => undefined;
    });
  }

  /**
   * Deletes a laptop and every bundle cached for it, in one transaction.
   * @param {string} id
   * @returns {Promise<void>}
   */
  async forgetLaptop(id) {
    await this.#run([LAPTOPS, BUNDLES], 'readwrite', (tx, ask) => {
      ask(tx.objectStore(LAPTOPS).delete(id));
      const bundles = tx.objectStore(BUNDLES);
      ask(bundles.index(BY_LAPTOP).getAllKeys(id), (keys) => {
        for (const key of keys) {
          ask(bundles.delete(key));
        }
      });
      return () => undefined;
    });
  }

  /**
   * @param {string} laptopID
   * @param {string} sha256
   * @returns {Promise<BundleRecord | null>}
   */
  getBundle(laptopID, sha256) {
    return this.#run([BUNDLES], 'readonly', (tx, ask) => {
      /** @type {BundleRecord | null} */
      let record = null;
      ask(tx.objectStore(BUNDLES).get([laptopID, sha256]), (value) => {
        record = value === undefined ? null : validateBundleRecord(value);
      });
      return () => record;
    });
  }

  /**
   * Caches a bundle, then prunes that laptop's cache, in one transaction. The bundle just
   * written is always kept, even if its `usedAt` is older than the others' (a clock set
   * back), so it is never fetched only to be thrown away.
   * @param {BundleRecord} record
   * @returns {Promise<void>}
   * @throws {TypeError} for a record `validateBundleRecord` refuses, before anything is written
   */
  async putBundle(record) {
    const valid = validateBundleRecord(record);
    await this.#run([BUNDLES], 'readwrite', (tx, ask) => {
      const bundles = tx.objectStore(BUNDLES);
      ask(bundles.put(valid));
      ask(bundles.index(BY_LAPTOP).getAll(valid.laptopID), (/** @type {BundleRecord[]} */ records) => {
        const others = records.filter((other) => other.sha256 !== valid.sha256);
        for (const key of bundlesToPrune(others, valid.laptopID, CACHED_BUNDLES_PER_LAPTOP - 1)) {
          ask(bundles.delete(key));
        }
      });
      return () => undefined;
    });
  }

  /**
   * Sets a cached bundle's `usedAt`. A bundle pruned meanwhile stays pruned.
   * @param {string} laptopID
   * @param {string} sha256
   * @param {number} at milliseconds, from `clock.now()`
   * @returns {Promise<void>}
   */
  async markBundleUsed(laptopID, sha256, at) {
    await this.#run([BUNDLES], 'readwrite', (tx, ask) => {
      const bundles = tx.objectStore(BUNDLES);
      ask(bundles.get([laptopID, sha256]), (value) => {
        if (value !== undefined) {
          ask(bundles.put(validateBundleRecord({ ...validateBundleRecord(value), usedAt: at })));
        }
      });
      return () => undefined;
    });
  }

  /**
   * Runs `body` in one transaction. `body` issues requests through `ask` and returns a
   * function that reads the result, which is called once the transaction has committed.
   * The first failure is the rejection, and it aborts the transaction.
   * @template T
   * @param {string[]} names
   * @param {IDBTransactionMode} mode
   * @param {(tx: IDBTransaction, ask: Ask) => () => T} body
   * @returns {Promise<T>}
   */
  #run(names, mode, body) {
    return new Promise((resolve, reject) => {
      /** @type {IDBTransaction} */
      let tx;
      try {
        // `strict`: a write is on disk when it resolves, so a key just paired survives a
        // crash. An engine without durability hints ignores the option.
        tx = this.#db.transaction(names, mode, { durability: 'strict' });
      } catch (error) {
        reject(error);
        return;
      }
      let failed = false;
      /** @type {unknown} */
      let failure;
      /** @param {unknown} error */
      const record = (error) => {
        if (!failed) {
          failed = true;
          failure = error;
        }
      };
      /** @param {unknown} error */
      const abort = (error) => {
        record(error);
        try {
          tx.abort();
        } catch {
          // Already finished or aborting; its own event settles the promise.
        }
      };
      /** @type {Ask} */
      const ask = (request, onSuccess) => {
        // Not cancelled, so the error also aborts the transaction.
        request.onerror = () => record(request.error);
        request.onsuccess = () => {
          if (onSuccess === undefined) return;
          try {
            onSuccess(request.result);
          } catch (error) {
            abort(error);
          }
        };
      };
      /** @type {() => T} */
      let result = () => { throw new Error('the transaction did not run'); };
      tx.oncomplete = () => {
        if (failed) {
          reject(failure);
          return;
        }
        try {
          resolve(result());
        } catch (error) {
          reject(error);
        }
      };
      tx.onerror = (event) => record(/** @type {IDBRequest | null} */ (event.target)?.error ?? tx.error);
      tx.onabort = () => reject(failed ? failure : tx.error ?? new DOMException('the transaction was aborted', 'AbortError'));
      try {
        result = body(tx, ask);
      } catch (error) {
        abort(error);
      }
    });
  }
}

/**
 * A laptop's ID: the base64url of its 32-byte public key, 43 characters.
 * @param {Uint8Array} bytes
 * @returns {string}
 * @throws {TypeError} for anything but 32 bytes
 */
export function laptopIDFromKey(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length !== KEY_BYTES) {
    throw new TypeError('a laptop key is 32 bytes');
  }
  return base64urlEncode(bytes);
}

/**
 * Checks every field of a laptop record and returns a fresh record with only those fields,
 * its byte arrays copied.
 * @param {unknown} obj
 * @returns {LaptopRecord}
 * @throws {TypeError} naming the first field that is wrong
 */
export function validateLaptopRecord(obj) {
  const r = fields(obj, 'laptop');
  const laptopKey = bytes(r.laptopKey, 'laptopKey', (n) => n === KEY_BYTES);
  const phoneKey = bytes(r.phoneKey, 'phoneKey', (n) => n === KEY_BYTES);
  const wrappedKey = bytes(r.wrappedKey, 'wrappedKey', (n) => n > 0);
  const wrapIV = bytes(r.wrapIV, 'wrapIV', (n) => n === IV_BYTES);
  const { id, room, relay, laptopName, phoneName, pairedAt, lastConnectedAt } = r;
  if (id !== base64urlEncode(laptopKey)) {
    throw new TypeError('laptop record: id is not the base64url of laptopKey');
  }
  if (!isRoomID(room)) {
    throw new TypeError('laptop record: room is not a room ID');
  }
  if (typeof relay !== 'string' || !makesSocketURL(relay, room)) {
    throw new TypeError('laptop record: relay is not a relay origin');
  }
  if (typeof laptopName !== 'string' || typeof phoneName !== 'string') {
    throw new TypeError('laptop record: a name is not a string');
  }
  if (!isFiniteNumber(pairedAt)) {
    throw new TypeError('laptop record: pairedAt is not a finite number');
  }
  if (lastConnectedAt !== null && !isFiniteNumber(lastConnectedAt)) {
    throw new TypeError('laptop record: lastConnectedAt is neither a finite number nor null');
  }
  return {
    id, relay, room, laptopKey, laptopName, phoneName, phoneKey, wrappedKey, wrapIV, pairedAt, lastConnectedAt,
  };
}

/**
 * Checks every field of a cached bundle and returns a fresh record with only those fields.
 * @param {unknown} obj
 * @returns {BundleRecord}
 * @throws {TypeError} naming the first field that is wrong
 */
export function validateBundleRecord(obj) {
  const { laptopID, sha256, text, size, usedAt } = fields(obj, 'bundle');
  if (typeof laptopID !== 'string' || base64urlDecode(laptopID)?.length !== KEY_BYTES) {
    throw new TypeError('bundle record: laptopID is not a laptop ID');
  }
  if (typeof sha256 !== 'string' || !SHA256_HEX.test(sha256)) {
    throw new TypeError('bundle record: sha256 is not lowercase hex SHA-256');
  }
  // A string never has more UTF-16 units than its UTF-8 bytes.
  if (typeof text !== 'string' || text.length > MAX_BUNDLE_TEXT) {
    throw new TypeError('bundle record: text is not a bundle');
  }
  if (!Number.isInteger(size) || /** @type {number} */ (size) < 1 || /** @type {number} */ (size) > MAX_BUNDLE_COMPRESSED) {
    throw new TypeError('bundle record: size is not a compressed size');
  }
  if (!isFiniteNumber(usedAt)) {
    throw new TypeError('bundle record: usedAt is not a finite number');
  }
  return { laptopID, sha256, text, size: /** @type {number} */ (size), usedAt };
}

/**
 * The keys of one laptop's cached bundles that fall outside the `keep` most recently used.
 * Records are ordered by `usedAt` descending, ties by `sha256` ascending; a `usedAt` that is
 * not a finite number counts as least recently used. Other laptops' records are ignored.
 * @param {ReadonlyArray<Pick<BundleRecord, 'laptopID' | 'sha256' | 'usedAt'>>} records
 * @param {string} laptopID
 * @param {number} [keep]
 * @returns {Array<[string, string]>} `[laptopID, sha256]` keys to delete
 * @throws {RangeError} for a `keep` that is not a non-negative integer
 */
export function bundlesToPrune(records, laptopID, keep = CACHED_BUNDLES_PER_LAPTOP) {
  if (!Number.isInteger(keep) || keep < 0) {
    throw new RangeError('keep must be a non-negative integer');
  }
  /** @param {{ usedAt: number }} record */
  const lastUse = (record) => (Number.isFinite(record.usedAt) ? record.usedAt : -Infinity);
  return records
    .filter((record) => record.laptopID === laptopID)
    .sort((a, b) => compare(lastUse(b), lastUse(a)) || compare(a.sha256, b.sha256))
    .slice(keep)
    .map((record) => /** @type {[string, string]} */ ([laptopID, record.sha256]));
}

/**
 * @param {number | string} a
 * @param {number | string} b
 * @returns {number}
 */
function compare(a, b) {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

/**
 * @param {unknown} obj
 * @param {string} kind
 * @returns {Record<string, unknown>}
 */
function fields(obj, kind) {
  if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) {
    throw new TypeError(`${kind} record: not an object`);
  }
  return /** @type {Record<string, unknown>} */ (obj);
}

/**
 * @param {unknown} value
 * @param {string} name
 * @param {(length: number) => boolean} sizeOK
 * @returns {Uint8Array}
 */
function bytes(value, name, sizeOK) {
  if (!(value instanceof Uint8Array) || !sizeOK(value.length)) {
    throw new TypeError(`laptop record: ${name} is not a Uint8Array of the right size`);
  }
  return new Uint8Array(value);
}

/**
 * @param {unknown} value
 * @returns {value is number}
 */
function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * @param {string} relay
 * @param {string} room
 * @returns {boolean}
 */
function makesSocketURL(relay, room) {
  try {
    relaySocketURL(relay, room);
    return true;
  } catch {
    return false;
  }
}
