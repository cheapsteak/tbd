// IndexedDB storage for paired laptops and cached bundles (spec sections 2 and 9).
//
// Three object stores:
// - `laptops`: LaptopRecord, keyPath `id`. Each record carries its own wrap key (keys.js);
//   the phone's private key is stored only wrapped under it.
// - `bundles`: a cached bundle's text, `{ laptopID, sha256, text }`.
// - `bundleMeta`: its size and last use, `{ laptopID, sha256, size, usedAt }`. Pruning and
//   `markBundleUsed` read and write only these small rows, never the text.
// Both bundle stores have keyPath `['laptopID', 'sha256']` and the index `byLaptop` on
// `laptopID`, and every write keeps the two in step.
//
// Every method runs in one transaction and settles with it: it resolves once the transaction
// commits, and rejects on a request's `error`, the transaction's `error` or `abort`, or an
// exception while it runs (which aborts it, so nothing it wrote is kept). No transaction
// awaits anything while it runs, so none commits early. Every record read is validated, so a
// damaged record surfaces as an error or as a damaged row, never as missing fields.
//
// A write that touches a laptop's keys (`putLaptop`, `forgetLaptop`) is `strict`: it resolves
// only once it is on disk, so a key just paired, or a laptop just forgotten, survives a crash.
// The bundle cache and the timestamps (`putBundle`, `markBundleUsed`, `touchLaptop`) are
// `relaxed`, and may resolve first: a lost write costs a bundle fetched or hashed again, or an
// older time, never a key.
//
// A damaged laptop record never blocks the loader: `listLaptops` reports it beside the good
// ones, and `forgetLaptop` deletes it by its key. Nothing here deletes a laptop record on its
// own.

import { base64urlDecode, base64urlEncode } from './channel/pairingLink.js';
import {
  CACHED_BUNDLES_PER_LAPTOP, DB_NAME, DB_VERSION, MAX_BUNDLE_COMPRESSED, MAX_BUNDLE_TEXT,
} from './constants.js';
import { IV_BYTES, KEY_BYTES, isWrapKey } from './keys.js';
import { isRoomID, relaySocketURL } from './links.js';
import { isSHA256 } from './protocol.js';

/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */
/** @typedef {import('./types.js').DamagedLaptop} DamagedLaptop */
/** @typedef {import('./types.js').BundleRecord} BundleRecord */
/** @typedef {import('./types.js').BundleMeta} BundleMeta */
/** @typedef {import('./types.js').BundleText} BundleText */

/**
 * One stored row as read: its key, and its value or the error reading it.
 * @typedef {{ key: IDBValidKey, value: unknown, error?: unknown }} StoredRow
 */

/**
 * Issues one request inside a transaction. `onSuccess` runs inside the transaction, so it may
 * issue more requests; if it throws, the transaction aborts with that error. Without
 * `onError`, a failed request aborts the transaction; with it, the failure is handled there
 * and the transaction goes on.
 * @callback Ask
 * @param {IDBRequest} request
 * @param {(result: any) => void} [onSuccess]
 * @param {(error: unknown) => void} [onError]
 * @returns {void}
 */

const LAPTOPS = 'laptops';
const BUNDLES = 'bundles';
const BUNDLE_META = 'bundleMeta';
const BY_LAPTOP = 'byLaptop';

/** Another tab holds the database open at an older version, so this one cannot upgrade it. */
export class StoreBlockedError extends Error {
  constructor() {
    super('the loader database is open in another tab');
    this.name = 'StoreBlockedError';
  }
}

/** A stored laptop record that cannot be read or fails validation. */
export class DamagedRecordError extends Error {
  /**
   * @param {IDBValidKey} key the record's key, which `forgetLaptop` takes
   * @param {string | null} laptopName the record's `laptopName` if it is a string
   * @param {unknown} [cause]
   */
  constructor(key, laptopName, cause) {
    super('a stored laptop record is damaged', { cause });
    this.name = 'DamagedRecordError';
    /** @readonly */
    this.key = key;
    /** @readonly */
    this.laptopName = laptopName;
  }
}

/**
 * Opens the loader's database, creating its stores on first use.
 *
 * A `blocked` open rejects with StoreBlockedError rather than waiting, because the tab
 * holding the database may be suspended and never answer; a connection that opens after that
 * is closed at once. See `Store.onClosed` for a connection that closes later.
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
      // Any change to the stored shapes that an older loader's validators would reject must
      // bump DB_VERSION and upgrade here. The bump closes older tabs through `versionchange`
      // ("Reload this page"); without it they would read the new records as damaged.
      if (event.oldVersion < 1) {
        const db = request.result;
        db.createObjectStore(LAPTOPS, { keyPath: 'id' });
        for (const name of [BUNDLES, BUNDLE_META]) {
          db.createObjectStore(name, { keyPath: ['laptopID', 'sha256'] }).createIndex(BY_LAPTOP, 'laptopID');
        }
      }
    };
    request.onsuccess = () => {
      const db = request.result;
      if (settled) {
        db.close();
        return;
      }
      settled = true;
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
  /** @type {'versionchange' | 'close' | null} */
  #closedBy = null;

  /**
   * Called once when the connection closes under the store, after which every method
   * rejects and the page should offer "Reload this page". The reason is `'versionchange'`
   * when a newer loader in another tab needs to upgrade (this tab has closed its connection
   * so that it can), or `'close'` when the browser closed it (site data cleared, a storage
   * failure). Set it as soon as `openStore` resolves; `closed` tells a later reader.
   * @type {((reason: 'versionchange' | 'close') => void) | null}
   */
  onClosed = null;

  /** @param {IDBDatabase} db from `openStore` */
  constructor(db) {
    this.#db = db;
    db.onversionchange = () => {
      db.close();
      this.#closed('versionchange');
    };
    db.onclose = () => this.#closed('close');
  }

  /**
   * Why the connection closed, or null while it is open.
   * @returns {'versionchange' | 'close' | null}
   */
  get closed() {
    return this.#closedBy;
  }

  /**
   * Every laptop, in key order: the records that validate, and the keys (with the stored
   * `laptopName`, if it is a string) of those that do not. A record that cannot even be read
   * is damaged too, so one bad record never hides the others.
   * @returns {Promise<{ laptops: LaptopRecord[], damaged: DamagedLaptop[] }>}
   */
  listLaptops() {
    return this.#run([LAPTOPS], 'readonly', 'default', (tx, ask) => {
      const laptops = tx.objectStore(LAPTOPS);
      /** @type {StoredRow[]} */
      let rows = [];
      readRows(ask, laptops.getAllKeys(), laptops, (read) => { rows = read; });
      return () => readLaptopRows(rows);
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
    await this.#run([LAPTOPS], 'readwrite', 'strict', (tx, ask) => {
      ask(tx.objectStore(LAPTOPS).put(valid));
      return () => undefined;
    });
  }

  /**
   * Records a connection, keeping every other field of the stored record, including any a
   * newer loader added. A laptop forgotten meanwhile stays forgotten.
   * @param {string} id
   * @param {{ lastConnectedAt: number, laptopName: string }} update
   * @returns {Promise<void>}
   * @throws {DamagedRecordError} for a stored record that fails validation; it is left as is
   * @throws {TypeError} for an update the record cannot take
   */
  async touchLaptop(id, update) {
    await this.#run([LAPTOPS], 'readwrite', 'relaxed', (tx, ask) => {
      const laptops = tx.objectStore(LAPTOPS);
      ask(laptops.get(id), (value) => {
        if (value !== undefined) {
          ask(laptops.put(touchedLaptop(id, value, update)));
        }
      });
      return () => undefined;
    });
  }

  /**
   * Deletes a laptop record by its key, damaged or not, and, for a string key, every bundle
   * cached under it, in one transaction.
   * @param {IDBValidKey} key a laptop `id`, or a `DamagedLaptop`'s `key`
   * @returns {Promise<void>}
   * @throws {TypeError} for a key range, which would delete more than one laptop
   */
  async forgetLaptop(key) {
    const Range = globalThis.IDBKeyRange;
    if (Range !== undefined && key instanceof Range) {
      throw new TypeError('forgetLaptop takes one key, not a range');
    }
    await this.#run([LAPTOPS, BUNDLES, BUNDLE_META], 'readwrite', 'strict', (tx, ask) => {
      ask(tx.objectStore(LAPTOPS).delete(key));
      if (typeof key === 'string') {
        for (const name of [BUNDLES, BUNDLE_META]) {
          const store = tx.objectStore(name);
          ask(store.index(BY_LAPTOP).getAllKeys(key), (/** @type {IDBValidKey[]} */ keys) => {
            for (const bundleKey of keys) {
              ask(store.delete(bundleKey));
            }
          });
        }
      }
      return () => undefined;
    });
  }

  /**
   * A cached bundle, or null when it is not cached, or its rows cannot be read, fail
   * validation, or do not match the key (the caller then fetches it again).
   * @param {string} laptopID
   * @param {string} sha256
   * @returns {Promise<BundleRecord | null>}
   */
  getBundle(laptopID, sha256) {
    return this.#run([BUNDLES, BUNDLE_META], 'readonly', 'default', (tx, ask) => {
      const key = [laptopID, sha256];
      /** @type {unknown} */
      let meta;
      /** @type {unknown} */
      let text;
      const unread = () => {};
      // The text is read only when its small meta row is there.
      ask(tx.objectStore(BUNDLE_META).get(key), (value) => {
        meta = value;
        if (value !== undefined) {
          ask(tx.objectStore(BUNDLES).get(key), (stored) => { text = stored; }, unread);
        }
      }, unread);
      return () => bundleFromRows(laptopID, sha256, text, meta);
    });
  }

  /**
   * Caches a bundle, then prunes that laptop's cache, in one transaction, and only while the
   * laptop is stored: a Forget in another tab during the download leaves no bundle behind.
   * The bundle just written is always kept, even if its `usedAt` is older than the others' (a
   * clock set back), so it is never fetched only to be thrown away.
   * @param {BundleRecord} record
   * @returns {Promise<boolean>} whether it was written
   * @throws {TypeError} for a record `validateBundleRecord` refuses, before anything is written
   */
  async putBundle(record) {
    const { laptopID, sha256, text, size, usedAt } = validateBundleRecord(record);
    return this.#run([LAPTOPS, BUNDLES, BUNDLE_META], 'readwrite', 'relaxed', (tx, ask) => {
      const bundles = tx.objectStore(BUNDLES);
      const meta = tx.objectStore(BUNDLE_META);
      let written = false;
      ask(tx.objectStore(LAPTOPS).count(laptopID), (/** @type {number} */ count) => {
        if (count === 0) {
          return;
        }
        written = true;
        ask(bundles.put({ laptopID, sha256, text }));
        ask(meta.put({ laptopID, sha256, size, usedAt }));
        readRows(ask, meta.index(BY_LAPTOP).getAllKeys(laptopID), meta, (metaRows) => {
          ask(bundles.index(BY_LAPTOP).getAllKeys(laptopID), (/** @type {IDBValidKey[]} */ textKeys) => {
            const doomed = bundleCacheDeletions(laptopID, sha256, metaRows, textKeys);
            for (const key of doomed.meta) {
              ask(meta.delete(key));
            }
            for (const key of doomed.text) {
              ask(bundles.delete(key));
            }
          });
        });
      });
      return () => written;
    });
  }

  /**
   * Sets a cached bundle's `usedAt`, keeping the rest of its meta row. A bundle pruned
   * meanwhile stays pruned.
   * @param {string} laptopID
   * @param {string} sha256
   * @param {number} at milliseconds, from `clock.now()`
   * @returns {Promise<void>}
   * @throws {TypeError} for a damaged meta row or an `at` that is not a finite number
   */
  async markBundleUsed(laptopID, sha256, at) {
    await this.#run([BUNDLE_META], 'readwrite', 'relaxed', (tx, ask) => {
      const meta = tx.objectStore(BUNDLE_META);
      ask(meta.get([laptopID, sha256]), (value) => {
        if (value === undefined) {
          return;
        }
        const stored = validateBundleMeta(value);
        if (stored.laptopID !== laptopID || stored.sha256 !== sha256) {
          throw new TypeError('bundle meta: the row does not match its key');
        }
        const next = { .../** @type {object} */ (value), usedAt: at };
        validateBundleMeta(next);
        ask(meta.put(next));
      });
      return () => undefined;
    });
  }

  /** @param {'versionchange' | 'close'} reason */
  #closed(reason) {
    if (this.#closedBy !== null) {
      return;
    }
    this.#closedBy = reason;
    this.onClosed?.(reason);
  }

  /**
   * Runs `body` in one transaction. `body` issues requests through `ask` and returns a
   * function that reads the result, which is called once the transaction has committed.
   * The first failure is the rejection, and it aborts the transaction.
   * @template T
   * @param {string[]} names
   * @param {IDBTransactionMode} mode
   * @param {IDBTransactionDurability} durability `strict` for a write of keys, `relaxed` for
   *   the cache and timestamps, `default` for a read (see the top of this file). An engine
   *   without durability hints ignores it.
   * @param {(tx: IDBTransaction, ask: Ask) => () => T} body
   * @returns {Promise<T>}
   */
  #run(names, mode, durability, body) {
    return new Promise((resolve, reject) => {
      /** @type {IDBTransaction} */
      let tx;
      try {
        tx = this.#db.transaction(names, mode, { durability });
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
      const ask = (request, onSuccess, onError) => {
        request.onerror = (event) => {
          if (onError === undefined) {
            // Not cancelled, so the error also aborts the transaction.
            record(request.error);
            return;
          }
          // Handled here: cancelled so the transaction goes on, and kept from its onerror.
          event.preventDefault();
          event.stopPropagation();
          try {
            onError(request.error ?? new DOMException('the request failed', 'UnknownError'));
          } catch (error) {
            abort(error);
          }
        };
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
 * Reads every row whose key `keysRequest` lists, one `get` each, so that a row which cannot
 * be read (a value that no longer deserializes) comes back with its `error` instead of
 * failing the transaction. `done` runs inside the transaction, with the rows in key order.
 * @param {Ask} ask
 * @param {IDBRequest<IDBValidKey[]>} keysRequest
 * @param {IDBObjectStore} store the store the keys belong to
 * @param {(rows: StoredRow[]) => void} done
 */
function readRows(ask, keysRequest, store, done) {
  ask(keysRequest, (/** @type {IDBValidKey[]} */ keys) => {
    /** @type {StoredRow[]} */
    const rows = keys.map((key) => ({ key, value: undefined }));
    let pending = rows.length;
    const settle = () => {
      pending -= 1;
      if (pending === 0) done(rows);
    };
    if (pending === 0) {
      done(rows);
      return;
    }
    for (const row of rows) {
      ask(store.get(row.key), (value) => {
        row.value = value;
        settle();
      }, (error) => {
        row.error = error;
        settle();
      });
    }
  });
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
 * its byte arrays copied (the wrap key, which cannot be copied, is the same object). Fields it
 * does not know are ignored, so a record a newer loader extended still reads.
 * @param {unknown} obj
 * @returns {LaptopRecord}
 * @throws {TypeError} naming the first field that is wrong
 */
export function validateLaptopRecord(obj) {
  const r = fields(obj, 'laptop record');
  const laptopKey = bytes(r.laptopKey, 'laptopKey', (n) => n === KEY_BYTES);
  const phoneKey = bytes(r.phoneKey, 'phoneKey', (n) => n === KEY_BYTES);
  const wrappedKey = bytes(r.wrappedKey, 'wrappedKey', (n) => n > 0);
  const wrapIV = bytes(r.wrapIV, 'wrapIV', (n) => n === IV_BYTES);
  const { id, room, relay, laptopName, phoneName, wrapKey, pairedAt, lastConnectedAt } = r;
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
  if (!isWrapKey(wrapKey)) {
    throw new TypeError('laptop record: wrapKey is not a non-extractable AES-GCM 256 wrap key');
  }
  if (!isFiniteNumber(pairedAt)) {
    throw new TypeError('laptop record: pairedAt is not a finite number');
  }
  if (lastConnectedAt !== null && !isFiniteNumber(lastConnectedAt)) {
    throw new TypeError('laptop record: lastConnectedAt is neither a finite number nor null');
  }
  return {
    id, relay, room, laptopKey, laptopName, phoneName, phoneKey, wrapKey, wrappedKey, wrapIV, pairedAt, lastConnectedAt,
  };
}

/**
 * One stored laptop row as a record: `listLaptops` and `touchLaptop` read every row through
 * this. A row is damaged when it could not be read, fails `validateLaptopRecord`, or has an
 * `id` other than the key it is stored under.
 * @param {IDBValidKey} key
 * @param {unknown} value
 * @param {unknown} [error] the error reading the row, if it could not be read
 * @returns {LaptopRecord}
 * @throws {DamagedRecordError} for a damaged row
 */
export function laptopFromRow(key, value, error) {
  try {
    if (error !== undefined) {
      throw error;
    }
    const record = validateLaptopRecord(value);
    if (record.id !== key) {
      throw new TypeError('laptop record: id is not the key it is stored under');
    }
    return record;
  } catch (cause) {
    throw new DamagedRecordError(key, storedLaptopName(value), cause);
  }
}

/**
 * Splits stored laptop rows into good records and damaged ones, keeping their order.
 * @param {ReadonlyArray<StoredRow>} rows
 * @returns {{ laptops: LaptopRecord[], damaged: DamagedLaptop[] }}
 */
export function readLaptopRows(rows) {
  /** @type {LaptopRecord[]} */
  const laptops = [];
  /** @type {DamagedLaptop[]} */
  const damaged = [];
  for (const { key, value, error } of rows) {
    try {
      laptops.push(laptopFromRow(key, value, error));
    } catch (problem) {
      if (!(problem instanceof DamagedRecordError)) {
        throw problem;
      }
      damaged.push({ key: problem.key, laptopName: problem.laptopName });
    }
  }
  return { laptops, damaged };
}

/**
 * What `touchLaptop` writes over the stored row: every stored field, including any this
 * loader does not know, with the new `lastConnectedAt` and `laptopName`.
 * @param {IDBValidKey} key
 * @param {unknown} stored the stored value, unchanged
 * @param {{ lastConnectedAt: number, laptopName: string }} update
 * @returns {Record<string, unknown>}
 * @throws {DamagedRecordError} for a stored row that is damaged
 * @throws {TypeError} for an update the record cannot take
 */
export function touchedLaptop(key, stored, { lastConnectedAt, laptopName }) {
  laptopFromRow(key, stored);
  const next = { .../** @type {object} */ (stored), lastConnectedAt, laptopName };
  validateLaptopRecord(next);
  return next;
}

/**
 * Checks every field of a cached bundle and returns a fresh record with only those fields.
 * @param {unknown} obj
 * @returns {BundleRecord}
 * @throws {TypeError} naming the first field that is wrong
 */
export function validateBundleRecord(obj) {
  const r = fields(obj, 'bundle record');
  return {
    ...bundleKeyFields(r, 'bundle record'), text: bundleText(r.text, 'bundle record'), ...bundleUse(r, 'bundle record'),
  };
}

/**
 * A cached bundle from its two stored rows, or null when either is missing, fails
 * validation, or does not match the key asked for.
 * @param {string} laptopID
 * @param {string} sha256
 * @param {unknown} text the `bundles` row
 * @param {unknown} meta the `bundleMeta` row
 * @returns {BundleRecord | null}
 */
export function bundleFromRows(laptopID, sha256, text, meta) {
  try {
    const t = validateBundleText(text);
    const m = validateBundleMeta(meta);
    if (t.laptopID !== laptopID || t.sha256 !== sha256 || m.laptopID !== laptopID || m.sha256 !== sha256) {
      return null;
    }
    return { laptopID, sha256, text: t.text, size: m.size, usedAt: m.usedAt };
  } catch (error) {
    if (error instanceof TypeError) {
      return null;
    }
    throw error;
  }
}

/**
 * Which rows of one laptop's bundle cache to delete once `sha256` has just been written for
 * it. Kept: that bundle, and the `CACHED_BUNDLES_PER_LAPTOP - 1` most recently used others
 * whose meta rows validate (`bundlesToPrune`'s order). Every other row of that laptop goes,
 * in both stores: pruned bundles, damaged or unreadable meta rows, and text rows that have no
 * kept meta row.
 * @param {string} laptopID
 * @param {string} sha256 the bundle just written
 * @param {ReadonlyArray<StoredRow>} metaRows that laptop's `bundleMeta` rows
 * @param {ReadonlyArray<IDBValidKey>} textKeys that laptop's `bundles` keys
 * @returns {{ meta: IDBValidKey[], text: IDBValidKey[] }}
 */
export function bundleCacheDeletions(laptopID, sha256, metaRows, textKeys) {
  /** @type {BundleMeta[]} */
  const others = [];
  // An unreadable row has no value, so it fails validation like a damaged one.
  for (const { key, value } of metaRows) {
    try {
      const meta = validateBundleMeta(value);
      if (isBundleKey(key, meta.laptopID, meta.sha256) && meta.laptopID === laptopID && meta.sha256 !== sha256) {
        others.push(meta);
      }
    } catch (problem) {
      if (!(problem instanceof TypeError)) throw problem;
    }
  }
  const pruned = new Set(bundlesToPrune(others, laptopID, CACHED_BUNDLES_PER_LAPTOP - 1).map(([, sha]) => sha));
  const kept = new Set([sha256, ...others.map((meta) => meta.sha256).filter((sha) => !pruned.has(sha))]);
  /** @param {IDBValidKey} key */
  const doomed = (key) => !(Array.isArray(key) && key.length === 2 && key[0] === laptopID
    && typeof key[1] === 'string' && kept.has(key[1]));
  return { meta: metaRows.map((row) => row.key).filter(doomed), text: textKeys.filter(doomed) };
}

/**
 * The keys of one laptop's cached bundles that fall outside the `keep` most recently used.
 * Records are ordered by `usedAt` descending, ties by `sha256` ascending; a `usedAt` that is
 * not a finite number counts as least recently used. Other laptops' records are ignored.
 * @param {ReadonlyArray<Pick<BundleMeta, 'laptopID' | 'sha256' | 'usedAt'>>} records
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
 * @param {unknown} obj
 * @returns {BundleText}
 * @throws {TypeError}
 */
function validateBundleText(obj) {
  const r = fields(obj, 'bundle text');
  return { ...bundleKeyFields(r, 'bundle text'), text: bundleText(r.text, 'bundle text') };
}

/**
 * @param {unknown} obj
 * @returns {BundleMeta}
 * @throws {TypeError}
 */
function validateBundleMeta(obj) {
  const r = fields(obj, 'bundle meta');
  return { ...bundleKeyFields(r, 'bundle meta'), ...bundleUse(r, 'bundle meta') };
}

/**
 * @param {Record<string, unknown>} r
 * @param {string} kind
 * @returns {{ laptopID: string, sha256: string }}
 */
function bundleKeyFields(r, kind) {
  const { laptopID, sha256 } = r;
  if (typeof laptopID !== 'string' || base64urlDecode(laptopID)?.length !== KEY_BYTES) {
    throw new TypeError(`${kind}: laptopID is not a laptop ID`);
  }
  if (!isSHA256(sha256)) {
    throw new TypeError(`${kind}: sha256 is not lowercase hex SHA-256`);
  }
  return { laptopID, sha256 };
}

/**
 * @param {unknown} text
 * @param {string} kind
 * @returns {string}
 */
function bundleText(text, kind) {
  // A string never has more UTF-16 units than its UTF-8 bytes.
  if (typeof text !== 'string' || text.length > MAX_BUNDLE_TEXT) {
    throw new TypeError(`${kind}: text is not a bundle`);
  }
  return text;
}

/**
 * @param {Record<string, unknown>} r
 * @param {string} kind
 * @returns {{ size: number, usedAt: number }}
 */
function bundleUse(r, kind) {
  const { size, usedAt } = r;
  if (typeof size !== 'number' || !Number.isInteger(size) || size < 1 || size > MAX_BUNDLE_COMPRESSED) {
    throw new TypeError(`${kind}: size is not a compressed size`);
  }
  if (!isFiniteNumber(usedAt)) {
    throw new TypeError(`${kind}: usedAt is not a finite number`);
  }
  return { size, usedAt };
}

/**
 * @param {IDBValidKey} key
 * @param {string} laptopID
 * @param {string} sha256
 * @returns {boolean}
 */
function isBundleKey(key, laptopID, sha256) {
  return Array.isArray(key) && key.length === 2 && key[0] === laptopID && key[1] === sha256;
}

/**
 * @param {unknown} value
 * @returns {string | null}
 */
function storedLaptopName(value) {
  if (typeof value !== 'object' || value === null) {
    return null;
  }
  const { laptopName } = /** @type {{ laptopName?: unknown }} */ (value);
  return typeof laptopName === 'string' ? laptopName : null;
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
    throw new TypeError(`${kind}: not an object`);
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
