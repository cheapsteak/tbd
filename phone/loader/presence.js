// Whether each paired laptop is in its room, from the relay's presence endpoint (relay API v1:
// `GET /v1/rooms/<room>/presence` answers `200 {"laptop": true|false}`). The laptops list and
// the header strip's menu use it instead of joining the room: a phone socket would replace the
// one another tab holds (close 4000), so a status check must never open one.

import { isSoonAfter, startVisibleTimer, systemClock } from './clock.js';
import { RESUME_COALESCE_MS, SIGNAL_TIMEOUT_MS } from './constants.js';
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
 * A screen's presence checks: `status` is a laptop's last answer, and `recheck` asks every
 * laptop again on a return to the page.
 * @typedef {object} PresenceChecks
 * @property {(id: string) => PresenceStatus | undefined} status
 * @property {() => void} recheck
 * @property {() => void} abort cancels every request still out; nothing is reported after it
 */

/**
 * Checks every laptop at once. Each answer goes to `onResult` as it arrives, until `abort()`.
 *
 * `recheck()` asks every laptop again, whatever its last answer: after a long lock, a laptop
 * that read online may have gone to sleep, and one that read offline may be back. A request
 * still out, perhaps frozen while the page was hidden, is cancelled and asked again, except
 * one asked less than RESUME_COALESCE_MS before, which is left running: the two events one
 * return to the page can fire ask once, not twice. `status` keeps a laptop's last answer
 * until the new one arrives.
 * @param {ReadonlyArray<{ id: string, relay: string, room: string }>} laptops
 * @param {{ fetch: FetchLike, visibility: Visibility, clock?: Clock,
 *   onResult: (id: string, status: PresenceStatus) => void }} options
 * @returns {PresenceChecks}
 */
export function checkPresence(laptops, { fetch, visibility, clock = systemClock, onResult }) {
  /** @type {Map<string, PresenceStatus>} */
  const statuses = new Map();
  /** @type {Map<string, { controller: AbortController, askedAt: number }>} The requests still out. */
  const asking = new Map();
  let aborted = false;
  /** @param {{ id: string, relay: string, room: string }} laptop */
  const ask = ({ id, relay, room }) => {
    const controller = new AbortController();
    asking.set(id, { controller, askedAt: clock.now() });
    fetchPresence({ fetch, relay, room, visibility, clock, signal: controller.signal }).then((status) => {
      if (controller.signal.aborted) return;
      asking.delete(id);
      statuses.set(id, status);
      onResult(id, status);
    });
  };
  for (const laptop of laptops) ask(laptop);
  return {
    status: (id) => statuses.get(id),
    recheck() {
      if (aborted) return;
      const now = clock.now();
      for (const laptop of laptops) {
        const out = asking.get(laptop.id);
        if (out !== undefined) {
          if (isSoonAfter(out.askedAt, now, RESUME_COALESCE_MS)) continue;
          out.controller.abort();
        }
        ask(laptop);
      }
    },
    abort() {
      aborted = true;
      for (const { controller } of asking.values()) controller.abort();
      asking.clear();
    },
  };
}
