// Which screen the loader shows, as pure functions of what it knows, so that `main.js` only
// wires them to the DOM and node:test can check every case.

import { formatLastConnected } from './format.js';
import { MESSAGES } from './messages.js';

/** @typedef {import('./types.js').LaptopRecord} LaptopRecord */
/** @typedef {import('./types.js').DamagedLaptop} DamagedLaptop */
/** @typedef {import('./connection.js').ConnectionState} ConnectionState */
/** @typedef {import('./connection.js').FatalReason} FatalReason */
/** @typedef {import('./pairing.js').PairingFailure} PairingFailure */
/** @typedef {import('./presence.js').PresenceStatus} PresenceStatus */

/**
 * Where the loader starts without a pairing link: the pair screen with no laptops, straight to
 * the only laptop, and the Laptops screen for two or more, or whenever a record is damaged
 * (so the damaged row and its Forget can be seen; nothing is deleted on its own).
 * @param {{ laptops: LaptopRecord[], damaged: DamagedLaptop[] }} list from `listLaptops`
 * @returns {{ kind: 'pair' } | { kind: 'laptops' } | { kind: 'connect', record: LaptopRecord }}
 */
export function bootRoute({ laptops, damaged }) {
  if (damaged.length > 0) return { kind: 'laptops' };
  if (laptops.length === 0) return { kind: 'pair' };
  if (laptops.length === 1) return { kind: 'connect', record: laptops[0] };
  return { kind: 'laptops' };
}

/**
 * The order the Laptops screen and the strip's menu list laptops in: by name, then by ID. The
 * store returns key order, which follows a hash of each laptop's key and so looks random; this
 * order is one a person can predict, and it holds from visit to visit and through a switch.
 * @param {readonly LaptopRecord[]} laptops
 * @returns {LaptopRecord[]} a sorted copy
 */
export function sortLaptops(laptops) {
  return [...laptops].sort(
    (a, b) => a.laptopName.localeCompare(b.laptopName) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );
}

/**
 * The full screen for a connection state while no app frame exists, or null in `ready` (by
 * then the frame exists: `bundle` comes just before `ready`).
 * @param {ConnectionState} state
 * @returns {'connecting' | 'offline' | 'relay' | 'replaced' | null}
 */
export function connectionScreen(state) {
  switch (state) {
    case 'offline':
      return 'offline';
    case 'relayUnreachable':
      return 'relay';
    case 'replaced':
      return 'replaced';
    case 'ready':
      return null;
    default:
      // connecting, handshaking, loading, reconnecting
      return 'connecting';
  }
}

/**
 * Whether the header strip reads "Reconnecting…": while an app frame exists and the channel
 * is anything but `ready`. Before a frame exists, full screens say what is going on instead.
 * @param {boolean} hasFrame
 * @param {ConnectionState | null} state
 * @returns {boolean}
 */
export function stripReconnecting(hasFrame, state) {
  return hasFrame && state !== 'ready';
}

/**
 * The screen for a connection that ended for good.
 * @param {FatalReason} reason
 * @returns {'update' | 'reload' | 'removed'}
 */
export function fatalScreen(reason) {
  switch (reason) {
    case 'incompatibleLaptop':
      return 'update';
    case 'revoked':
      return 'removed';
    default:
      // incompatibleLoader, badBundle, protocol
      return 'reload';
  }
}

/**
 * The screen for a pairing that ended without a device, or null for the user's own Cancel.
 * @param {PairingFailure} reason
 * @returns {'denied' | 'expired' | 'pair-invalid' | 'pair-offline' | 'pair-relay' | null}
 */
export function pairingFailureScreen(reason) {
  switch (reason) {
    case 'denied':
      return 'denied';
    case 'expired':
      return 'expired';
    case 'offline':
      return 'pair-offline';
    case 'relayUnreachable':
      return 'pair-relay';
    case 'cancelled':
      return null;
    default:
      return 'pair-invalid';
  }
}

/**
 * "last connected …" text, lower case to follow a status word: "just now", "5 min ago",
 * "2 days ago". Null for a laptop never connected.
 * @param {number | null} atMs
 * @param {number} nowMs
 * @returns {string | null}
 */
export function lastConnectedText(atMs, nowMs) {
  if (atMs === null) return null;
  const text = formatLastConnected(atMs, nowMs);
  return text.charAt(0).toLowerCase() + text.slice(1);
}

/**
 * A laptop's status line, as the Laptops screen (`list`) or the strip's menu (`menu`) shows it.
 * The mocks read "Online · last connected now" in the list and just "Online" in the menu, and
 * "Offline · last connected 2 days ago" in both. Before the presence answer arrives, only the
 * last-connected time shows, with no dot, so nothing claims a status not yet known.
 * @param {PresenceStatus | undefined} status undefined while the presence check is out
 * @param {number | null} lastConnectedAt
 * @param {number} nowMs
 * @param {'list' | 'menu'} where
 * @returns {{ dot: 'on' | 'off' | null, text: string }}
 */
export function presenceLine(status, lastConnectedAt, nowMs, where) {
  const last = lastConnectedText(lastConnectedAt, nowMs);
  const since = last === null ? '' : ` · last connected ${last}`;
  switch (status) {
    case 'online':
      return { dot: 'on', text: where === 'menu' ? MESSAGES.online : `${MESSAGES.online}${since}` };
    case 'offline':
      return { dot: 'off', text: `${MESSAGES.offlineRow}${since}` };
    case 'relay':
      return { dot: null, text: where === 'menu' ? MESSAGES.relay : `${MESSAGES.relay}${since}` };
    default:
      return { dot: null, text: last === null ? 'Never connected' : `Last connected ${last}` };
  }
}
