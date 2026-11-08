// Tests bandText.ts: the text of the band under the session header, for each stopped status,
// with the time now and the time zone given, so no test reads the clock or the machine's zone.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneStatus } from '../protocol/types.ts';
import { bandText } from './bandText.ts';

/** Friday 7 August 2026, 10:00 UTC. */
const NOW = Date.UTC(2026, 7, 7, 10, 0);
const HOUR = 3_600_000;

function rate(extra: Partial<PhoneStatus> = {}): PhoneStatus {
  return { chip: 'rateLimited', changedAt: NOW - HOUR, ...extra };
}

/** A UTC time on 7 August 2026, or `days` after it. */
function at(hour: number, minute: number, days = 0): number {
  return Date.UTC(2026, 7, 7 + days, hour, minute);
}

test("a rate limit's reason from the daemon wins, shown as it comes", () => {
  const status = rate({ reason: 'Usage limit reached. It resets at 3:00 pm.', untilAt: at(18, 0, 2) });
  assert.equal(bandText(status, NOW, 'UTC'), 'Usage limit reached. It resets at 3:00 pm.');
});

test('a rate limit that lifts today says the time alone', () => {
  for (const [hour, minute, text] of [
    [0, 5, '12:05 am'],
    [9, 30, '9:30 am'],
    [12, 0, '12:00 pm'],
    [15, 0, '3:00 pm'],
    [23, 59, '11:59 pm'],
  ] as const) {
    assert.equal(bandText(rate({ untilAt: at(hour, minute) }), NOW, 'UTC'), `Usage limit reached. It resets at ${text}.`);
  }
});

test('a rate limit that lifts on another day names the weekday', () => {
  assert.equal(bandText(rate({ untilAt: at(15, 0, 1) }), NOW, 'UTC'), 'Usage limit reached. It resets at Sat 3:00 pm.');
  assert.equal(bandText(rate({ untilAt: at(0, 0, 3) }), NOW, 'UTC'), 'Usage limit reached. It resets at Mon 12:00 am.');
  // Seven days on is the same weekday, and still not today.
  assert.equal(bandText(rate({ untilAt: at(15, 0, 7) }), NOW, 'UTC'), 'Usage limit reached. It resets at Fri 3:00 pm.');
  // A time already past on an earlier day is named the same way.
  assert.equal(bandText(rate({ untilAt: at(15, 0, -1) }), NOW, 'UTC'), 'Usage limit reached. It resets at Thu 3:00 pm.');
});

test("the day and the time are the phone's own, in its time zone", () => {
  // 02:30 UTC on Saturday is 7:30 pm on Friday in Los Angeles (UTC-7 in August), the day NOW
  // falls on there too: today.
  const untilAt = at(2, 30, 1);
  assert.equal(bandText(rate({ untilAt }), NOW, 'America/Los_Angeles'), 'Usage limit reached. It resets at 7:30 pm.');
  // In UTC it is the next day.
  assert.equal(bandText(rate({ untilAt }), NOW, 'UTC'), 'Usage limit reached. It resets at Sat 2:30 am.');
  // 23:00 UTC on Friday is already Saturday in Tokyo (UTC+9), where NOW is still Friday.
  assert.equal(bandText(rate({ untilAt: at(23, 0) }), NOW, 'Asia/Tokyo'), 'Usage limit reached. It resets at Sat 8:00 am.');
});

test('a rate limit with no reason and no end says the limit alone', () => {
  assert.equal(bandText(rate(), NOW, 'UTC'), 'Usage limit reached.');
  // An empty reason is no reason.
  assert.equal(bandText(rate({ reason: '' }), NOW, 'UTC'), 'Usage limit reached.');
});

test('an error shows its reason, or its status word when it has none', () => {
  assert.equal(bandText({ chip: 'error', changedAt: NOW, reason: 'The agent reported an error.' }, NOW, 'UTC'), 'The agent reported an error.');
  assert.equal(bandText({ chip: 'error', changedAt: NOW }, NOW, 'UTC'), 'Error');
  assert.equal(bandText({ chip: 'error', changedAt: NOW, reason: '' }, NOW, 'UTC'), 'Error');
});

test('an unknown status and an exited session have a line each, whatever the reason', () => {
  assert.equal(bandText({ chip: 'unknown', changedAt: NOW, reason: 'No hook.' }, NOW, 'UTC'), "TBD cannot read this tab's status, so it shows as Unknown.");
  assert.equal(bandText({ chip: 'exited', changedAt: NOW }, NOW, 'UTC'), 'This session has exited. Restart it on the laptop.');
});

test('the other statuses have no band', () => {
  for (const chip of ['waitingForYou', 'working', 'idle', 'parked'] as const) {
    assert.equal(bandText({ chip, changedAt: NOW, reason: 'Why.', untilAt: at(15, 0) }, NOW, 'UTC'), null, chip);
  }
});

test("with no time zone, the phone's own zone is used", () => {
  const untilAt = at(15, 0);
  const local = new Date(untilAt);
  const h = local.getHours();
  const time = `${h % 12 === 0 ? 12 : h % 12}:${String(local.getMinutes()).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`;
  const sameDay = new Date(NOW).toDateString() === local.toDateString();
  const day = sameDay ? '' : `${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][local.getDay()]} `;
  assert.equal(bandText(rate({ untilAt }), NOW), `Usage limit reached. It resets at ${day}${time}.`);
});
