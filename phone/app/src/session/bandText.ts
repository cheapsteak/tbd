/**
 * The text of the band under the session header (spec section 8.3; mock `sessionHTML`), as a
 * pure function of the status and the time now, so its tests need no clock.
 *
 * An error or a rate limit shows the daemon's reason as it comes. A rate limit with no reason,
 * which is every local one, says when the limit lifts (unless that time has passed), in the phone's own time: the time alone
 * when it lifts today, else after a short weekday, the laptop's own style. An error with no
 * reason shows its status word, so the band is never empty.
 */

import type { PhoneStatus } from '../protocol/types.ts';
import { STATUS } from '../state/status.ts';

const UNKNOWN_TEXT = "TBD cannot read this tab's status, so it shows as Unknown.";
const EXITED_TEXT = 'This session has exited. Restart it on the laptop.';
const RATE_LIMIT_TEXT = 'Usage limit reached.';
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const;
const DAY_MS = 86_400_000;

/**
 * The band's text for `status`, or null for a status with no band. `now` and `timeZone` (an
 * IANA name; the phone's own zone when left out) decide whether a rate limit lifts today.
 */
export function bandText(status: PhoneStatus, now: number, timeZone?: string): string | null {
  const reason = status.reason !== undefined && status.reason !== '' ? status.reason : null;
  switch (status.chip) {
    case 'error':
      return reason ?? STATUS.error.word;
    case 'rateLimited':
      return reason ?? rateLimitText(status.untilAt, now, timeZone);
    case 'unknown':
      return UNKNOWN_TEXT;
    case 'exited':
      return EXITED_TEXT;
    default:
      return null;
  }
}

/** A rate limit's line when the daemon gave no reason. */
function rateLimitText(untilAt: number | undefined, now: number, timeZone: string | undefined): string {
  if (untilAt === undefined || untilAt <= now) return RATE_LIMIT_TEXT;
  const until = wallClock(untilAt, timeZone);
  const today = wallClock(now, timeZone);
  const day = until.day === today.day ? '' : `${WEEKDAYS[until.weekday]} `;
  return `${RATE_LIMIT_TEXT} It resets at ${day}${clockTime(until.hour, until.minute)}.`;
}

/** A time of day as `3:00 pm`, `12:05 am`. */
function clockTime(hour: number, minute: number): string {
  const h = hour % 12 === 0 ? 12 : hour % 12;
  return `${h}:${String(minute).padStart(2, '0')} ${hour < 12 ? 'am' : 'pm'}`;
}

interface WallClock {
  /** The calendar day, as days since 1 January 1970. */
  day: number;
  /** 0 for Sunday to 6 for Saturday. */
  weekday: number;
  hour: number;
  minute: number;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

/** The formatter for `timeZone` (the phone's own zone when undefined), built once. */
function formatter(timeZone: string | undefined): Intl.DateTimeFormat {
  const key = timeZone ?? '';
  let f = formatters.get(key);
  if (f === undefined) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric',
    });
    formatters.set(key, f);
  }
  return f;
}

/**
 * What a clock in `timeZone` reads at `ms`. Intl gives the fields as numbers in a fixed locale
 * and a 24-hour cycle; the text around them is built by hand, so the phone's locale never
 * changes it.
 */
function wallClock(ms: number, timeZone: string | undefined): WallClock {
  const parts = formatter(timeZone).formatToParts(ms);
  const field = (type: Intl.DateTimeFormatPartTypes): number => Number(parts.find((p) => p.type === type)?.value);
  const day = Date.UTC(field('year'), field('month') - 1, field('day')) / DAY_MS;
  return { day, weekday: new Date(day * DAY_MS).getUTCDay(), hour: field('hour'), minute: field('minute') };
}
