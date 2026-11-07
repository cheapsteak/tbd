// Every timing, size and version constant of the phone loader, defined once.
// Message-size limits are not redefined here: modules that need the per-message
// budget import MAX_PLAINTEXT_LENGTH from ./channel/noise.js directly.

export const LOADER_VERSION = '1.0.0';
export const LOADER_PROTOCOLS = Object.freeze([1]);

export const KEEPALIVE_MS = 30_000;
export const RESUME_PONG_TIMEOUT_MS = 3_000;
export const RECONNECT_MIN_MS = 1_000;
export const RECONNECT_MAX_MS = 60_000;

export const SIGNAL_TIMEOUT_MS = 10_000;
export const HANDSHAKE_TIMEOUT_MS = 10_000;
export const RUNNER_START_TIMEOUT_MS = 10_000;
export const PAIRING_EXPIRY_GRACE_MS = 120_000;

export const CACHED_BUNDLES_PER_LAPTOP = 2;
export const MAX_CHUNK_BYTES = 45_000;
export const MAX_BUNDLE_COMPRESSED = 4 * 1024 * 1024;
export const MAX_BUNDLE_TEXT = 16 * 1024 * 1024;

export const DEVICE_NAME_MAX = 64;

export const QR_INTERVAL_MS = 250;
export const QR_MAX_EDGE = 640;

export const DB_NAME = 'tbd-loader';
export const DB_VERSION = 1;
