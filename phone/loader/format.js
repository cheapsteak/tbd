const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

/**
 * Formats a 6-digit confirmation code for display: '012345' becomes '012 345'.
 * @param {string} code
 * @returns {string}
 */
export function formatCode(code) {
  return `${code.slice(0, 3)} ${code.slice(3)}`;
}

/**
 * The "last connected" text of a laptop row. A time ahead of `nowMs`, from a clock that moved
 * back, reads as "Just now".
 * @param {number | null} atMs
 * @param {number} nowMs
 * @returns {string}
 */
export function formatLastConnected(atMs, nowMs) {
  if (atMs === null) return 'Never';
  const ago = nowMs - atMs;
  if (ago < MINUTE_MS) return 'Just now';
  if (ago < HOUR_MS) return `${Math.floor(ago / MINUTE_MS)} min ago`;
  if (ago < DAY_MS) return `${Math.floor(ago / HOUR_MS)} h ago`;
  const days = Math.floor(ago / DAY_MS);
  return days === 1 ? '1 day ago' : `${days} days ago`;
}
