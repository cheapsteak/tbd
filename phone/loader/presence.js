// Whether each paired laptop is in its room, from the relay's presence endpoint (relay API v1:
// `GET /v1/rooms/<room>/presence` answers `200 {"laptop": true|false}`). The laptops list and
// the header strip's menu use it instead of joining the room: a phone socket would replace the
// one another tab holds (close 4000), so a status check must never open one.

import { startVisibleTimer, systemClock } from './clock.js';
import { SIGNAL_TIMEOUT_MS } from './constants.js';
import { relayPresenceURL } from './links.js';
import { isPlainObject } from './objects.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./clock.js').Visibility} Visibility */

/**
 * `relay` stands for "Can't reach the relay": a network error, a timeout, a status other than
 * 200, or a body that is not `{"laptop": boolean}`.
 * @typedef {'online' | 'offline' | 'relay'} PresenceStatus
 */

/**
 * @typedef {(url: string, init: RequestInit) => Promise<{ status: number, json(): Promise<unknown> }>} FetchLike
 */

/**
 * A laptop's presence from the endpoint's parsed JSON body. Other fields are ignored, so a
 * newer relay can add some.
 * @param {unknown} body
 * @returns {PresenceStatus}
 */
export function readPresenceBody(body) {
  if (!isPlainObject(body)) return 'relay';
  const { laptop } = body;
  if (typeof laptop !== 'boolean') return 'relay';
  return laptop ? 'online' : 'offline';
}

/**
 * Asks the relay whether the laptop is in `room`. Gives up once the page has been visible for
 * SIGNAL_TIMEOUT_MS, counted on `clock` (`startVisibleTimer`: iOS freezes a hidden page with
 * its requests in flight, so time while hidden never counts), or when `signal` aborts. Never
 * rejects.
 * @param {{ fetch: FetchLike, relay: string, room: string, visibility: Visibility, clock?: Clock,
 *   signal?: AbortSignal }} options
 * @returns {Promise<PresenceStatus>}
 */
export async function fetchPresence({ fetch, relay, room, visibility, clock = systemClock, signal }) {
  let url;
  try {
    url = relayPresenceURL(relay, room);
  } catch {
    return 'relay';
  }
  if (signal?.aborted) return 'relay';
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  /** @type {Promise<PresenceStatus>} */
  const gaveUp = new Promise((resolve) => {
    controller.signal.addEventListener('abort', () => resolve('relay'), { once: true });
  });
  const cancelTimer = startVisibleTimer(SIGNAL_TIMEOUT_MS, visibility, abort, clock);
  const ask = async () => {
    try {
      const response = await fetch(url, {
        cache: 'no-store',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
        redirect: 'error',
        signal: controller.signal,
      });
      if (response.status !== 200) return 'relay';
      return readPresenceBody(await response.json());
    } catch {
      return 'relay';
    }
  };
  try {
    // The race also bounds a fetch, or a body read, that does not heed the signal.
    return await Promise.race([ask(), gaveUp]);
  } finally {
    cancelTimer();
    signal?.removeEventListener('abort', abort);
    controller.abort();
  }
}

/**
 * Checks every laptop at once. Each answer goes to `onResult` as it arrives, until `abort()`,
 * which also cancels the requests still out.
 * @param {ReadonlyArray<{ id: string, relay: string, room: string }>} laptops
 * @param {{ fetch: FetchLike, visibility: Visibility, clock?: Clock,
 *   onResult: (id: string, status: PresenceStatus) => void }} options
 * @returns {{ abort(): void }}
 */
export function checkPresence(laptops, { fetch, visibility, clock = systemClock, onResult }) {
  const controller = new AbortController();
  for (const { id, relay, room } of laptops) {
    fetchPresence({ fetch, relay, room, visibility, clock, signal: controller.signal }).then((status) => {
      if (!controller.signal.aborted) onResult(id, status);
    });
  }
  return { abort: () => controller.abort() };
}
