// The prompt card end to end (spec sections 4.4 and 8.3), in WebKit as an iPhone and in Chromium
// as an Android phone: a question card's options, Other, steps and review, multi-select, Hide,
// a session that cannot answer, a refused answer, and one send per gesture.
//
// Every test that answers checks the exact `prompt.answer` params the fake laptop got: the
// session the route shows, the prompt's ID, and the answer `questionAnswer` builds. mock.json
// holds four prompts: a single-select question on Login redirect fix, three questions on
// Onboarding copy, a multi-select question on Settings screen, and a permission on SSE
// reconnect. A scenario variation is built here from mock.json and loaded as an object, never
// written into mock.json.

import { readFileSync } from 'node:fs';

import { app, expect, hostCall, hostRequests, openApp, openSessionByName, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));

/** Login redirect fix's Claude session and its question. */
const LOGIN_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000102' };
const LOGIN_PROMPT = '00000000-0000-4000-8000-0000000000E1';
const LOGIN_QUESTION = 'Add a test for open-redirect attempts too?';
/** Onboarding copy's Claude session and its three questions. */
const ONBOARDING_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-00000000010B' };
const ONBOARDING_PROMPT = '00000000-0000-4000-8000-0000000000E3';
/** Settings screen's Claude session and its multi-select question. */
const SETTINGS_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-00000000010C' };
const SETTINGS_PROMPT = '00000000-0000-4000-8000-0000000000E4';
const SETTINGS_QUESTION = 'Which settings should move to the new screen?';
/** The daemon's reason while the laptop's "answer prompts" setting is off (`PhoneSessionStatus.answerTurnedOffReason`). */
const ANSWERING_OFF = "Answering prompts is turned off in TBD's settings on the laptop.";

/**
 * The params of every `prompt.answer` that reached the fake laptop, in order.
 * @param {Page} page
 */
async function answers(page) {
  return (await hostRequests(page)).filter((r) => r.method === 'prompt.answer').map((r) => r.params);
}

/**
 * The dock's card.
 * @param {Page} page
 */
function card(page) {
  return app(page).locator('.dock .card');
}

/**
 * mock.json with the session whose terminal is `terminalID` changed by `edit`.
 * @param {string} terminalID
 * @param {(session: any) => void} edit
 */
function withSession(terminalID, edit) {
  const scenario = structuredClone(MOCK);
  for (const row of scenario.rows) {
    for (const session of row.sessions) if (session.ref.terminalID === terminalID) edit(session);
  }
  return scenario;
}

test("one question: a tap sends the option's label under the question's text", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const c = card(page);
  await expect(c).toHaveAttribute('role', 'region');
  await expect(c).toHaveAttribute('aria-label', 'Question');
  await expect(c.locator('.c-head')).toContainText('Claude asks');
  await expect(c.locator('.c-head')).not.toContainText(' of ');
  await expect(c.locator('.steps')).toHaveCount(0);
  await expect(c.locator('.q')).toHaveText(LOGIN_QUESTION);
  const yes = c.locator('button.opt', { hasText: 'Yes, add the test' });
  await expect(yes.locator('small')).toHaveText('Covers next=https://… and next=//… links');
  await expect(c.locator('button.opt.ghost')).toHaveText('Other answer…');
  await yes.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Yes, add the test' } } },
  ]);
});

test('a double click on an option posts one prompt.answer', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await card(page).locator('button.opt', { hasText: 'No, this is enough' }).dblclick();
  await expect.poll(() => answers(page)).toHaveLength(1);
  // The laptop resolved it: the card is gone, and nothing else was posted meanwhile.
  await expect(card(page)).toHaveCount(0);
  await page.waitForTimeout(300);
  expect(await answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'No, this is enough' } } },
  ]);
});

test('while the answer is on its way every choice is disabled', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await hostCall(page, 'hold', 'prompt.answer');
  const c = card(page);
  await c.locator('button.opt', { hasText: 'Yes, add the test' }).click();
  await expect.poll(() => answers(page)).toHaveLength(1);
  for (const option of await c.locator('button.opt').all()) await expect(option).toBeDisabled();
  // A tap on a disabled option does nothing: Playwright refuses it, so dispatch the click.
  await c.locator('button.opt', { hasText: 'No, this is enough' }).dispatchEvent('click');
  await hostCall(page, 'release', 'prompt.answer');
  await expect(card(page)).toHaveCount(0);
  expect(await answers(page)).toHaveLength(1);
});

test('Other sends the typed text, and a blank Other is no answer', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const c = card(page);
  await c.getByRole('button', { name: 'Other answer…' }).click();
  const text = c.getByRole('textbox', { name: 'Type your answer' });
  await expect(text).toBeFocused();
  await expect(text).toHaveAttribute('placeholder', 'Type your answer');
  await expect(c.getByRole('button', { name: 'Other answer…' })).toHaveCount(0);
  const send = c.getByRole('button', { name: 'Send answer' });
  await expect(send).toBeDisabled();
  await text.fill('   ');
  await expect(send).toBeDisabled();
  // Cancel closes the form and brings "Other answer…" back.
  await c.getByRole('button', { name: 'Cancel' }).click();
  await expect(text).toHaveCount(0);
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await text.fill('Only if it takes under ten minutes.');
  await send.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Only if it takes under ten minutes.' } } },
  ]);
});

test('three questions step through, then the review sends all three', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  const head = c.locator('.c-head');
  const steps = c.getByRole('progressbar');
  await expect(head).toContainText('Claude asks · 1 of 3');
  await expect(steps.locator('i')).toHaveCount(3);
  await expect(steps.locator('i.on')).toHaveCount(1);
  await expect(steps).toHaveAttribute('aria-valuenow', '1');
  await expect(c.locator('.q')).toHaveText('Which tone should the welcome screen use?');
  await expect(c.getByRole('button', { name: 'Back' })).toHaveCount(0);
  await c.getByRole('button', { name: 'Friendly and short' }).click();

  await expect(head).toContainText('Claude asks · 2 of 3');
  await expect(steps.locator('i.on')).toHaveCount(2);
  await expect(c.locator('.q')).toHaveText('How many onboarding steps?');
  await c.getByRole('button', { name: '3 steps' }).click();

  await expect(head).toContainText('Claude asks · 3 of 3');
  await expect(c.locator('.q')).toHaveText('Can people skip onboarding?');
  // Back returns to the question before, and a new pick replaces the old.
  await c.getByRole('button', { name: 'Back' }).click();
  await expect(c.locator('.q')).toHaveText('How many onboarding steps?');
  await c.getByRole('button', { name: '4 steps' }).click();
  await c.getByRole('button', { name: 'Yes, show a Skip button' }).click();

  await expect(c).toHaveAttribute('aria-label', 'Questions');
  await expect(head).toContainText('Claude asks · 3 of 3');
  await expect(c.locator('.q')).toHaveText('Send these answers?');
  const review = c.locator('.review button');
  await expect(review).toHaveText(['ToneFriendly and short', 'Steps4 steps', 'SkipYes, show a Skip button']);
  await expect(review.nth(1).locator('small')).toHaveText('Steps');
  // A tap on a review row returns to its question; the answer stays recorded.
  await review.nth(0).click();
  await expect(c.locator('.q')).toHaveText('Which tone should the welcome screen use?');
  await c.getByRole('button', { name: 'Plain and formal' }).click();
  await c.getByRole('button', { name: '4 steps' }).click();
  await c.getByRole('button', { name: 'Yes, show a Skip button' }).click();
  expect(await answers(page)).toEqual([]);
  await c.getByRole('button', { name: 'Send answers' }).click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: ONBOARDING_REF,
      promptID: ONBOARDING_PROMPT,
      answer: {
        kind: 'question',
        answers: {
          'Which tone should the welcome screen use?': 'Plain and formal',
          'How many onboarding steps?': '4 steps',
          'Can people skip onboarding?': 'Yes, show a Skip button',
        },
      },
    },
  ]);
});

test('an Other value in a multi-step prompt is recorded, and the review shows it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('  5 steps, with a tour  ');
  await c.getByRole('button', { name: 'Send answer' }).click();
  await expect(c.locator('.q')).toHaveText('Can people skip onboarding?');
  await c.getByRole('button', { name: 'No, every step is required' }).click();
  await expect(c.locator('.review button').nth(1)).toHaveText('Steps5 steps, with a tour');
  expect(await answers(page)).toEqual([]);
  await c.getByRole('button', { name: 'Send answers' }).click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: ONBOARDING_REF,
      promptID: ONBOARDING_PROMPT,
      answer: {
        kind: 'question',
        answers: {
          'Which tone should the welcome screen use?': 'Friendly and short',
          'How many onboarding steps?': '5 steps, with a tour',
          'Can people skip onboarding?': 'No, every step is required',
        },
      },
    },
  ]);
});

test('multi-select sends the picked labels in option order', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Settings screen');
  const c = card(page);
  await expect(c.locator('.q')).toHaveText(SETTINGS_QUESTION);
  await expect(c.locator('label.chk')).toHaveCount(5);
  await expect(c.locator('label.chk', { hasText: 'Storage' }).locator('small')).toHaveText('Only on the old preferences page today');
  const send = c.locator('.c-actions .btn.pri');
  await expect(send).toHaveText('Send answer');
  await expect(send).toBeDisabled();
  await c.getByRole('checkbox', { name: 'Privacy' }).check();
  await c.getByRole('checkbox', { name: 'Notifications' }).check();
  await expect(send).toHaveText('Send 2 selected');
  await c.getByRole('checkbox', { name: 'Account' }).check();
  await c.getByRole('checkbox', { name: 'Account' }).uncheck();
  await expect(send).toHaveText('Send 2 selected');
  await send.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SETTINGS_REF, promptID: SETTINGS_PROMPT, answer: { kind: 'question', answers: { [SETTINGS_QUESTION]: 'Notifications, Privacy' } } },
  ]);
});

test('Other on a multi-select question follows the picked labels', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Settings screen');
  const c = card(page);
  await c.getByRole('checkbox', { name: 'Privacy' }).check();
  await c.getByRole('checkbox', { name: 'Notifications' }).check();
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('Billing');
  await c.getByRole('button', { name: 'Send answer' }).click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: SETTINGS_REF,
      promptID: SETTINGS_PROMPT,
      answer: { kind: 'question', answers: { [SETTINGS_QUESTION]: 'Notifications, Privacy, Billing' } },
    },
  ]);
});

test('Hide shows the one-line strip, and Show brings the card back as it was', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  await expect(c.locator('.c-head')).toContainText('2 of 3');
  await c.getByRole('button', { name: 'Hide' }).click();
  await expect(c).toHaveCount(0);
  const strip = app(page).locator('.dock button.card-strip');
  await expect(strip).toHaveText('Question waitingShow');
  await expect(strip.locator('svg')).toHaveCount(2);
  await strip.click();
  await expect(strip).toHaveCount(0);
  await expect(c.locator('.c-head')).toContainText('2 of 3');
  await expect(c.locator('.q')).toHaveText('How many onboarding steps?');
});

test("a session that cannot answer shows the question and the laptop's reason, and no choices", async ({ page, appHost }) => {
  await openApp(page, appHost, {
    scenario: withSession(LOGIN_REF.terminalID, (s) => { s.capabilities.answer = { available: false, reason: ANSWERING_OFF }; }),
  });
  await openSessionByName(page, 'Login redirect fix');
  const c = card(page);
  await expect(c.locator('.c-head')).toContainText('Claude asks');
  await expect(c.locator('.q')).toHaveText(LOGIN_QUESTION);
  await expect(c.locator('.dock-note')).toHaveText(ANSWERING_OFF);
  await expect(c.locator('button.opt')).toHaveCount(0);
  await expect(c.locator('input, textarea')).toHaveCount(0);
  await page.waitForTimeout(200);
  expect(await answers(page)).toEqual([]);
});

test("a session that can answer again shows the choices once the list says so", async ({ page, appHost }) => {
  const scenario = withSession(LOGIN_REF.terminalID, (s) => { s.capabilities.answer = { available: false, reason: ANSWERING_OFF }; });
  await openApp(page, appHost, { scenario });
  await openSessionByName(page, 'Login redirect fix');
  const c = card(page);
  await expect(c.locator('.dock-note')).toHaveText(ANSWERING_OFF);
  const row = structuredClone(scenario.rows.find((/** @type {any} */ r) => r.name === 'Login redirect fix'));
  row.sessions[0].capabilities.answer = { available: true };
  await hostCall(page, 'emit', 'sessions.changed', { rows: [row], removedRowIDs: [] });
  await expect(c.locator('.dock-note')).toHaveCount(0);
  await c.getByRole('button', { name: 'Yes, add the test' }).click();
  await expect.poll(() => answers(page)).toHaveLength(1);
});

test("a refused answer shows the laptop's words and offers the choices again", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await hostCall(page, 'setReply', 'prompt.answer', { error: { code: 'refused', message: 'The laptop refused the answer.' } });
  const c = card(page);
  await c.getByRole('button', { name: 'Yes, add the test' }).click();
  const refusal = c.locator('.refusal');
  await expect(refusal).toHaveText('The laptop refused the answer.');
  await expect(refusal).toHaveAttribute('role', 'alert');
  await expect(refusal.locator('svg')).toHaveCount(1);
  // Above the choices.
  expect(await c.evaluate((el) => {
    const r = el.querySelector('.refusal');
    const opts = el.querySelector('.opts');
    return r !== null && opts !== null && (r.compareDocumentPosition(opts) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
  })).toBe(true);
  await hostCall(page, 'setReply', 'prompt.answer', null);
  await c.getByRole('button', { name: 'No, this is enough' }).click();
  await expect.poll(() => answers(page)).toHaveLength(2);
  expect((await answers(page))[1]).toEqual(
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'No, this is enough' } } },
  );
});

test("a new prompt never inherits the last one's picks", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  await expect(c.locator('.c-head')).toContainText('2 of 3');
  // The laptop's set now holds another prompt with the same questions, and the first closed
  // with no resolution: its card goes, and the new one starts at its first question.
  const next = structuredClone(MOCK.prompts[`local:${ONBOARDING_REF.terminalID}`][0]);
  next.id = 'onboarding-second';
  await hostCall(page, 'emit', 'prompt.changed', { session: ONBOARDING_REF, prompts: [next] });
  await expect(c.locator('.c-head')).toContainText('1 of 3');
  await expect(c.locator('.q')).toHaveText('Which tone should the welcome screen use?');
  await expect(c.getByRole('button', { name: 'Back' })).toHaveCount(0);
});
