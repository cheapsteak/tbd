// Every timing, size and version constant of the phone loader, defined once.
// Message-size limits are not redefined here: modules that need the per-message
// budget import MAX_PLAINTEXT_LENGTH from ./channel/noise.js directly.

export const LOADER_VERSION = '1.0.0';
export const LOADER_PROTOCOLS = Object.freeze([1]);

export const KEEPALIVE_MS = 30_000;
export const RESUME_PONG_TIMEOUT_MS = 3_000;
// A return to the page can fire both `pageshow` and `visibilitychange`. A resume this soon
// after the one that opened a socket keeps that socket while it connects; a later resume
// replaces it at once, since it may have frozen while the page was hidden in between.
export const RESUME_COALESCE_MS = 1_000;
export const RECONNECT_MIN_MS = 1_000;
export const RECONNECT_MAX_MS = 60_000;

export const SIGNAL_TIMEOUT_MS = 10_000;
export const HANDSHAKE_TIMEOUT_MS = 10_000;
// A handshake with no message 2 within HANDSHAKE_TIMEOUT_MS is retried on a fresh socket, through
// the backoff, this many times: a lost message 1 or 2 gets through on a retry. After the last one
// goes unanswered too, the connection reads offline and waits on its open socket for the laptop's
// next `peer-joined`, so a laptop that no longer knows this phone gets 1 + HANDSHAKE_RETRIES
// message 1s, not one per backoff step for as long as the page is open. A return to the page,
// and Try again, start a new round.
export const HANDSHAKE_RETRIES = 3;
// Right after pairing, a laptop that is away or does not answer reads `connecting`, not
// `offline`, for one full signal wait plus one handshake: the laptop's device link may join the
// new room any time within a signal wait, and its first handshake may lose message 2. The
// grace's end shows offline only for a laptop that is away; a retry that is pending, or a
// handshake under way, reads offline only from its own outcome.
export const PAIRED_GRACE_MS = SIGNAL_TIMEOUT_MS + HANDSHAKE_TIMEOUT_MS;
export const CACHE_READ_TIMEOUT_MS = 3_000;
// A store request the page waits on with nothing else to show (opening the store, listing
// the laptops, saving or forgetting one) that takes longer shows "Reload this page". Only time
// while the page is visible counts. The strip menu's read only closes the menu.
export const STORE_TIMEOUT_MS = 10_000;
export const RUNNER_START_TIMEOUT_MS = 10_000;
export const PAIRING_EXPIRY_GRACE_MS = 120_000;

export const CACHED_BUNDLES_PER_LAPTOP = 2;
export const MAX_CHUNK_BYTES = 45_000;
export const MAX_BUNDLE_COMPRESSED = 4 * 1024 * 1024;
export const MAX_BUNDLE_TEXT = 16 * 1024 * 1024;

export const DEVICE_NAME_MAX = 64;
// The most UTF-8 bytes a laptop's name may take: the limit a pairing link's `name` has
// (MAX_NAME_BYTES in channel/pairingLink.js), applied to the name message 2 reports too.
export const LAPTOP_NAME_MAX_BYTES = 256;

export const QR_INTERVAL_MS = 250;
export const QR_MAX_EDGE = 640;

export const DB_NAME = 'tbd-loader';
export const DB_VERSION = 1;
