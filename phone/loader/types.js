/**
 * @typedef {object} LaptopRecord
 * @property {string} id base64url of laptopKey, 43 characters.
 * @property {string} relay Relay origin from the pairing link.
 * @property {string} room Room ID the device link joins. This is the room from the laptop's
 *   `paired` message, NOT the QR code's pairing room (the laptop closes that one).
 * @property {Uint8Array} laptopKey 32 bytes.
 * @property {string} laptopName
 * @property {string} phoneName
 * @property {Uint8Array} phoneKey Raw X25519 public key, 32 bytes.
 * @property {Uint8Array} wrappedKey AES-GCM-wrapped PKCS#8 private key.
 * @property {Uint8Array} wrapIV 12 bytes.
 * @property {number} pairedAt Milliseconds.
 * @property {number|null} lastConnectedAt Milliseconds, or null.
 */

/**
 * @typedef {object} BundleRecord
 * @property {string} laptopID
 * @property {string} sha256 Lowercase hex.
 * @property {string} text
 * @property {number} size
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
