/**
 * A paired laptop, as stored in the `laptops` store (store.js).
 * @typedef {object} LaptopRecord
 * @property {string} id base64url of laptopKey, 43 characters.
 * @property {string} relay Relay origin from the pairing link.
 * @property {string} room Room ID the device link joins. This is the room from the laptop's
 *   `paired` message, NOT the QR code's pairing room (the laptop closes that one).
 * @property {Uint8Array} laptopKey 32 bytes.
 * @property {string} laptopName
 * @property {string} phoneName
 * @property {Uint8Array} phoneKey Raw X25519 public key, 32 bytes.
 * @property {CryptoKey} wrapKey This laptop's own wrap key: AES-GCM 256, not extractable,
 *   usages exactly `wrapKey` and `unwrapKey` (keys.js `createWrappedPhoneKey`).
 * @property {Uint8Array} wrappedKey The phone's PKCS#8 private key wrapped under `wrapKey`,
 *   with the additional data `tbd-phone/1 key <id> <base64url phoneKey>`.
 * @property {Uint8Array} wrapIV 12 bytes.
 * @property {number} pairedAt Milliseconds.
 * @property {number|null} lastConnectedAt Milliseconds, or null.
 */

/**
 * A stored laptop record that cannot be read or fails validation, as `listLaptops` reports
 * it. `forgetLaptop(key)` deletes it.
 * @typedef {object} DamagedLaptop
 * @property {IDBValidKey} key The record's key in the `laptops` store.
 * @property {string|null} laptopName The stored `laptopName`, if it is a string.
 */

/**
 * A cached bundle, as `putBundle` takes it and `getBundle` returns it. It is stored as two
 * rows: a BundleText and a BundleMeta.
 * @typedef {object} BundleRecord
 * @property {string} laptopID
 * @property {string} sha256 Lowercase hex.
 * @property {string} text
 * @property {number} size Compressed bytes.
 * @property {number} usedAt Milliseconds.
 */

/**
 * A cached bundle's text, as stored in the `bundles` store.
 * @typedef {object} BundleText
 * @property {string} laptopID
 * @property {string} sha256 Lowercase hex.
 * @property {string} text
 */

/**
 * A cached bundle's size and last use, as stored in the `bundleMeta` store.
 * @typedef {object} BundleMeta
 * @property {string} laptopID
 * @property {string} sha256 Lowercase hex.
 * @property {number} size Compressed bytes.
 * @property {number} usedAt Milliseconds.
 */

/**
 * @typedef {object} WebSocketLike
 * @property {string} binaryType
 * @property {number} readyState
 * @property {(data: string | ArrayBufferLike | ArrayBufferView) => void} send
 * @property {(code?: number, reason?: string) => void} close
 * @property {((ev: any) => void) | null} onopen
 * @property {((ev: any) => void) | null} onmessage
 * @property {((ev: any) => void) | null} onclose
 * @property {((ev: any) => void) | null} onerror
 */

/**
 * Loader-to-app environment message.
 * @typedef {object} EnvMessage
 * @property {'env'} t
 * @property {{top: number, right: number, bottom: number, left: number}} safeArea
 * @property {{width: number, height: number, offsetTop: number, offsetLeft: number, scale: number}} viewport
 * @property {{width: number, height: number}} layout
 * @property {'light'|'dark'} colorScheme
 */

/**
 * A message on the runner/app MessagePort.
 * @typedef {{t: 'app', body: object}
 *   | {t: 'channel', state: 'up'|'down'}
 *   | EnvMessage
 *   | {t: 'sendFailed', reason: 'offline'|'tooLarge'}
 *   | {t: 'openLink', url: string}
 *   | {t: 'started'}
 *   | {t: 'fault', reason: 'hash'|'script'}} PortMessage
 */

export {};
