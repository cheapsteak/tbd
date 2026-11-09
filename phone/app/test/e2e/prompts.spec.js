// The prompt card end to end (spec sections 4.4 and 8.3), in WebKit as an iPhone and in Chromium
// as an Android phone: a question card's options, Other, steps and review, multi-select, Hide,
// a session that cannot answer, a refused answer, and one send per gesture. Then the permission
// card: Yes, the session rule, Deny with a message, and the keyboard. Then no tap landing on
// what the user has not seen: a card that appeared or changed holds its choices at first, the
// focus leaves the button pressed, and what the user did on a card outlasts a card that took its
// place. Last, who answered: the Answered card, the card that says someone else answered first,
// and the receipts the transcript keeps ("Answered on this phone: …", "Answered on the laptop",
// "Answered on another phone"). After the card, the composer: Send and its label, a refusal,
// one send per gesture, the text kept while sending, the note when a session cannot take
// messages, the card and the composer together, Send staying put under the card, the growing
// textarea, the keyboard, and Send waiting when it first shows or changes its label. Every test
// that sends checks the exact `message.send` params.
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
/** SSE reconnect's Claude session and its permission prompt. */
const SSE_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000109' };
const SSE_PROMPT = '00000000-0000-4000-8000-0000000000E2';
const SSE_KEY = `local:${SSE_REF.terminalID}`;
const SSE_TARGET = 'npm run test:integration -- --grep "reconnects after 30 s idle" --reporter=dot && git diff --stat origin/main...HEAD';
/** The daemon's reason while the laptop's "answer prompts" setting is off (`PhoneSessionStatus.answerTurnedOffReason`). */
const ANSWERING_OFF = "Answering prompts is turned off in TBD's settings on the laptop.";
/** `TAP_GUARD_MS` (src/ui/tapGuard.ts) and Dock.tsx's `OPENING_MS`. */
const TAP_GUARD_MS = 500;
const OPENING_MS = 1000;
/** Onboarding copy's three questions, by text, and the answer that gives each its first option. */
const TONE = 'Which tone should the welcome screen use?';
const STEPS = 'How many onboarding steps?';
const SKIP = 'Can people skip onboarding?';
const ONBOARDING_ANSWER = {
  kind: 'question',
  answers: { [TONE]: 'Friendly and short', [STEPS]: '3 steps', [SKIP]: 'Yes, show a Skip button' },
};

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

/**
 * mock.json with SSE reconnect's open prompts replaced by `prompts`, each laid over the mock's
 * permission prompt.
 * @param {...object} prompts
 */
function withSSEPrompts(...prompts) {
  const scenario = structuredClone(MOCK);
  const base = MOCK.prompts[SSE_KEY][0];
  scenario.prompts[SSE_KEY] = prompts.map((p) => ({ ...base, ...p }));
  return scenario;
}

/**
 * mock.json with Onboarding copy's open prompts replaced by `prompts`, each laid over the mock's
 * three-question prompt.
 * @param {...object} prompts
 */
function withOnboardingPrompts(...prompts) {
  const scenario = structuredClone(MOCK);
  const key = `local:${ONBOARDING_REF.terminalID}`;
  const base = MOCK.prompts[key][0];
  scenario.prompts[key] = prompts.map((p) => structuredClone({ ...base, ...p }));
  return scenario;
}

/**
 * The centre of `locator`'s box.
 * @param {import('@playwright/test').Locator} locator
 */
async function centre(locator) {
  const box = await locator.boundingBox();
  if (box === null) throw new Error('no box');
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/**
 * Whether the point `at` lies inside `locator`'s box.
 * @param {import('@playwright/test').Locator} locator
 * @param {{ x: number, y: number }} at
 */
async function covers(locator, at) {
  const box = await locator.boundingBox();
  return box !== null && at.x >= box.x && at.x <= box.x + box.width && at.y >= box.y && at.y <= box.y + box.height;
}

/**
 * A tap at the centre of `locator` at once, as a finger gives it: no wait for it to be enabled,
 * as Playwright's `click` makes.
 * @param {Page} page
 * @param {import('@playwright/test').Locator} locator
 */
async function tap(page, locator) {
  const at = await centre(locator);
  await page.mouse.click(at.x, at.y);
  return at;
}

/**
 * A double tap at the centre of `locator`, returning where it landed.
 * @param {Page} page
 * @param {import('@playwright/test').Locator} locator
 */
async function doubleTap(page, locator) {
  const at = await centre(locator);
  await page.mouse.dblclick(at.x, at.y);
  return at;
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
  expect(await answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Yes, add the test' } } },
  ]);
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

test('Done in a multi-select Other form records the text after the picked labels, and only Send N selected sends', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Settings screen');
  const c = card(page);
  await c.getByRole('checkbox', { name: 'Privacy' }).check();
  await c.getByRole('checkbox', { name: 'Notifications' }).check();
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('Billing');
  await expect(c.locator('.c-actions button')).toHaveText(['Cancel', 'Done']);
  await c.getByRole('button', { name: 'Done' }).click();
  // Back on the checkboxes, the Other value ticked after the options, and nothing sent.
  await expect(c.getByRole('textbox', { name: 'Type your answer' })).toHaveCount(0);
  await expect(c.locator('label.chk')).toHaveCount(6);
  await expect(c.locator('label.chk').last()).toHaveText('Billing');
  await expect(c.getByRole('checkbox', { name: 'Billing' })).toBeChecked();
  await expect(c.getByRole('checkbox', { name: 'Privacy' })).toBeChecked();
  await expect(c.getByRole('button', { name: 'Other answer…' })).toBeVisible();
  const send = c.getByRole('button', { name: 'Send 3 selected' });
  await expect(send).toBeEnabled();
  expect(await answers(page)).toEqual([]);
  await send.click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: SETTINGS_REF,
      promptID: SETTINGS_PROMPT,
      answer: { kind: 'question', answers: { [SETTINGS_QUESTION]: 'Notifications, Privacy, Billing' } },
    },
  ]);
});

test('a multi-select Other leaves the answer when its box is unticked, or its text cleared', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Settings screen');
  const c = card(page);
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('  Billing ');
  await c.getByRole('button', { name: 'Done' }).click();
  const billing = c.getByRole('checkbox', { name: 'Billing' });
  await expect(billing).toBeChecked();
  const send = c.locator('.c-actions .btn.pri');
  await expect(send).toHaveText('Send 1 selected');
  await expect(send).toBeEnabled();
  // Unticked, the Other value is no part of the answer; its box stays, to tick again.
  await billing.uncheck();
  await expect(billing).not.toBeChecked();
  await expect(send).toHaveText('Send answer');
  await expect(send).toBeDisabled();
  await billing.check();
  await expect(send).toHaveText('Send 1 selected');
  await c.getByRole('checkbox', { name: 'Privacy' }).check();
  await expect(send).toHaveText('Send 2 selected');
  // Cleared, Done takes the value and its box away; Done takes blank text for that.
  await c.getByRole('button', { name: 'Other answer…' }).click();
  const text = c.getByRole('textbox', { name: 'Type your answer' });
  await expect(text).toHaveValue('  Billing ');
  await text.fill('');
  const done = c.getByRole('button', { name: 'Done' });
  await expect(done).toBeEnabled();
  await done.click();
  await expect(billing).toHaveCount(0);
  await expect(c.locator('label.chk')).toHaveCount(5);
  await expect(send).toHaveText('Send 1 selected');
  expect(await answers(page)).toEqual([]);
  await send.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SETTINGS_REF, promptID: SETTINGS_PROMPT, answer: { kind: 'question', answers: { [SETTINGS_QUESTION]: 'Privacy' } } },
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
  // The choices came where the reason was, so they wait at first.
  await expect(c.getByRole('button', { name: 'Yes, add the test' })).toBeDisabled();
  await c.getByRole('button', { name: 'Yes, add the test' }).click();
  await expect.poll(() => answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Yes, add the test' } } },
  ]);
});

test("a refused answer shows the laptop's words and offers the choices again", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await hostCall(page, 'setReply', 'prompt.answer', { error: { code: 'refused', message: 'The laptop refused the answer.' } });
  const c = card(page);
  await c.getByRole('button', { name: 'Yes, add the test' }).click();
  const refusal = c.locator('.refusal');
  await expect(refusal).toHaveText('The laptop refused the answer.');
  // The refusal moved the choices down, so they wait at first.
  await expect(c.getByRole('button', { name: 'No, this is enough' })).toBeDisabled();
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
  await expect.poll(() => answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Yes, add the test' } } },
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'No, this is enough' } } },
  ]);
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

test('a new prompt shows expanded though the last one was hidden', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await card(page).getByRole('button', { name: 'Hide' }).click();
  const strip = app(page).locator('.dock button.card-strip');
  await expect(strip).toHaveText('Question waitingShow');
  // The laptop's set now holds another prompt, and the hidden one closed with no resolution.
  const next = { ...structuredClone(MOCK.prompts[`local:${LOGIN_REF.terminalID}`][0]), id: 'login-second' };
  await hostCall(page, 'emit', 'prompt.changed', { session: LOGIN_REF, prompts: [next] });
  const c = card(page);
  await expect(c.locator('.q')).toHaveText(LOGIN_QUESTION);
  await expect(strip).toHaveCount(0);
  await c.getByRole('button', { name: 'No, this is enough' }).click();
  await expect.poll(() => answers(page)).toEqual([
    { session: LOGIN_REF, promptID: 'login-second', answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'No, this is enough' } } },
  ]);
});

test('a permission shows the tool, its summary and target, and Yes allows', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await expect(c).toHaveAttribute('role', 'region');
  await expect(c).toHaveAttribute('aria-label', 'Permission prompt');
  await expect(c.locator('.c-head')).toHaveText('PermissionHide');
  await expect(c.locator('.perm-tool')).toHaveText('Bash');
  await expect(c.locator('.perm-tool svg')).toHaveCount(1);
  await expect(c.locator('.perm-desc')).toHaveText('Run the reconnect integration tests, then show which files changed');
  await expect(c.locator('pre.perm-target')).toHaveText(SSE_TARGET);
  await expect(c.locator('button.opt')).toHaveText(['Yes', "Yes, and don't ask again this sessionBash(npm run test:integration:*)", 'No']);
  await expect(c.locator('button.opt.pri')).toHaveText('Yes');
  await expect(c.locator('button.opt.danger')).toHaveText('No');
  await c.locator('button.opt.pri').click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'allow' } },
  ]);
});

test('the session rule lists each rule as sent, and allows for the session', async ({ page, appHost }) => {
  await openApp(page, appHost, {
    scenario: withSSEPrompts({ suggestions: ['Bash(npm run test:integration:*)', 'Bash(git diff:*)'] }),
  });
  await openSessionByName(page, 'SSE reconnect');
  const rule = card(page).getByRole('button', { name: /^Yes, and don't ask again this session/ });
  await expect(rule.locator('small')).toHaveText(['Bash(npm run test:integration:*)', 'Bash(git diff:*)']);
  await rule.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'allow_always' } },
  ]);
});

test('a permission that offers no session rule has no rule choice, and a cut target ends in "…"', async ({ page, appHost }) => {
  await openApp(page, appHost, {
    scenario: withSSEPrompts({ allowAlways: false, suggestions: undefined, target: 'npm run test:integration -- --grep', targetTruncated: true }),
  });
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await expect(c.locator('pre.perm-target')).toHaveText('npm run test:integration -- --grep…');
  await expect(c.locator('button.opt')).toHaveText(['Yes', 'No']);
});

test('Deny sends the message, trimmed', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await c.getByRole('button', { name: 'No' }).click();
  await expect(c.locator('button.opt')).toHaveCount(0);
  const text = c.getByLabel('Tell Claude what to do instead (optional)');
  await expect(text).toBeFocused();
  await expect(c.locator('label.perm-desc')).toHaveText('Tell Claude what to do instead (optional)');
  // Back returns to the choices, and the text stays for the next time.
  await text.fill('  Run only the unit tests for now. ');
  await c.getByRole('button', { name: 'Back' }).click();
  await expect(text).toHaveCount(0);
  await c.getByRole('button', { name: 'No' }).click();
  await expect(text).toHaveValue('  Run only the unit tests for now. ');
  const deny = c.locator('.c-actions .btn.danger');
  await expect(deny).toHaveText('Deny');
  await deny.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'deny', message: 'Run only the unit tests for now.' } },
  ]);
});

test('a blank Deny sends no message', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await c.getByRole('button', { name: 'No' }).click();
  await c.getByLabel('Tell Claude what to do instead (optional)').fill(' \n ');
  await c.getByRole('button', { name: 'Deny' }).click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'deny' } },
  ]);
});

test('the deny form sits above the keyboard', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await c.getByRole('button', { name: 'No' }).click();
  const text = c.getByLabel('Tell Claude what to do instead (optional)');
  await expect(text).toBeFocused();
  const { width, height } = /** @type {{ width: number, height: number }} */ (page.viewportSize());
  await hostCall(page, 'sendEnv', {
    safeArea: { top: 0, right: 0, bottom: 0, left: 0 },
    viewport: { width, height: height - 336, offsetTop: 0, offsetLeft: 0, scale: 1 },
    layout: { width, height },
  });
  const dock = app(page).locator('.dock');
  await expect.poll(() => dock.evaluate((el) => getComputedStyle(el).paddingBottom)).toBe('346px');
  await expect(text).toBeFocused();
  // The textarea and Deny end above the keyboard's top edge, once the card has scrolled to its
  // end after the layout the keyboard brought.
  for (const el of [text, c.getByRole('button', { name: 'Deny' })]) {
    await expect.poll(() => el.evaluate((node) => node.getBoundingClientRect().bottom <= window.innerHeight - 336)).toBe(true);
  }
  await hostCall(page, 'sendEnv', null);
});

test('a permission the session cannot answer shows its text and the reason, and no choices', async ({ page, appHost }) => {
  await openApp(page, appHost, {
    scenario: withSession(SSE_REF.terminalID, (s) => { s.capabilities.answer = { available: false, reason: ANSWERING_OFF }; }),
  });
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await expect(c.locator('.perm-tool')).toHaveText('Bash');
  await expect(c.locator('pre.perm-target')).toHaveText(SSE_TARGET);
  await expect(c.locator('.dock-note')).toHaveText(ANSWERING_OFF);
  await expect(c.locator('button.opt')).toHaveCount(0);
  await page.waitForTimeout(200);
  expect(await answers(page)).toEqual([]);
});

test('Hide shows "Permission waiting"', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  await card(page).getByRole('button', { name: 'Hide' }).click();
  const strip = app(page).locator('.dock button.card-strip');
  await expect(strip).toHaveText('Permission waitingShow');
  await strip.click();
  await expect(card(page).locator('.perm-tool')).toHaveText('Bash');
});

test("no tap lands on the next permission before it has been on screen for 500 ms", async ({ page, appHost }) => {
  const second = { id: 'sse-second', summary: 'Show the reconnect log', target: 'tail -n 50 logs/stream.log' };
  await openApp(page, appHost, { scenario: withSSEPrompts({ id: SSE_PROMPT }, second) });
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  const yes = c.locator('button.opt.pri');
  // The card there as the session opens is not held: a tap the moment it shows answers it.
  await expect(c.locator('pre.perm-target')).toHaveText(SSE_TARGET);
  expect(await yes.isEnabled()).toBe(true);
  const at = await tap(page, yes);
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'allow' } },
  ]);
  // Its answer takes it down, and the second takes its place: a tap there at once, as the
  // second half of a double tap, lands on a disabled button and sends nothing.
  await c.locator('pre.perm-target', { hasText: second.target }).waitFor();
  expect(await covers(yes, at)).toBe(true);
  await page.mouse.click(at.x, at.y);
  await expect(yes).toBeDisabled();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'allow' } },
  ]);
  // Once it has been on screen for 500 ms, a tap answers it.
  await expect(yes).toBeEnabled();
  await page.mouse.click(at.x, at.y);
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'allow' } },
    { session: SSE_REF, promptID: 'sse-second', answer: { kind: 'permission', decision: 'allow' } },
  ]);
});

test('a card that comes a while after the session opened holds its choices at first', async ({ page, appHost }) => {
  await openApp(page, appHost, { scenario: withSSEPrompts() });
  await openSessionByName(page, 'SSE reconnect');
  // The user reads the transcript; then a permission comes, and the dock grows over the rows.
  await page.waitForTimeout(OPENING_MS + 500);
  await expect(card(page)).toHaveCount(0);
  await hostCall(page, 'emit', 'prompt.changed', { session: SSE_REF, prompts: [MOCK.prompts[SSE_KEY][0]] });
  const yes = card(page).locator('button.opt.pri');
  await yes.waitFor();
  const at = await tap(page, yes);
  await expect(yes).toBeDisabled();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await answers(page)).toEqual([]);
  await expect(yes).toBeEnabled();
  await page.mouse.click(at.x, at.y);
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'allow' } },
  ]);
});

test('a double tap on Show sends nothing, though the review it expands has Send answers there', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  for (const label of ['Friendly and short', '3 steps', 'Yes, show a Skip button']) await c.getByRole('button', { name: label }).click();
  await expect(c.locator('.q')).toHaveText('Send these answers?');
  await c.getByRole('button', { name: 'Hide' }).click();
  const at = await doubleTap(page, app(page).locator('.dock button.card-strip span'));
  const send = c.getByRole('button', { name: 'Send answers' });
  await expect(send).toBeVisible();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await answers(page)).toEqual([]);
  // The second tap fell on Send answers, which waited.
  expect(await covers(send, at)).toBe(true);
  await send.click();
  await expect.poll(() => answers(page)).toEqual([{ session: ONBOARDING_REF, promptID: ONBOARDING_PROMPT, answer: ONBOARDING_ANSWER }]);
});

test('a double tap on Show sends nothing, though the deny form it expands has Deny there', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await c.getByRole('button', { name: 'No' }).click();
  await c.getByRole('button', { name: 'Hide' }).click();
  const at = await doubleTap(page, app(page).locator('.dock button.card-strip span'));
  const deny = c.getByRole('button', { name: 'Deny' });
  await expect(deny).toBeVisible();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await answers(page)).toEqual([]);
  expect(await covers(deny, at)).toBe(true);
  await deny.click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'deny' } },
  ]);
});

test('opening the deny form holds Deny at first', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  await tap(page, card(page).getByRole('button', { name: 'No' }));
  const deny = card(page).getByRole('button', { name: 'Deny' });
  await expect(deny).toBeDisabled();
  await expect(deny).toBeEnabled();
  expect(await answers(page)).toEqual([]);
});

test('opening the Other form holds its buttons at first', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await tap(page, card(page).getByRole('button', { name: 'Other answer…' }));
  const cancel = card(page).getByRole('button', { name: 'Cancel' });
  await expect(cancel).toBeDisabled();
  await expect(cancel).toBeEnabled();
  expect(await answers(page)).toEqual([]);
});

test("a double tap on a step's last send lands on the review, which waits", async ({ page, appHost }) => {
  const multi = { header: 'Sections', text: 'Which sections?', multiSelect: true, options: [{ label: 'Account' }, { label: 'Billing' }] };
  const base = MOCK.prompts[`local:${ONBOARDING_REF.terminalID}`][0];
  await openApp(page, appHost, { scenario: withOnboardingPrompts({ questions: [base.questions[0], multi] }) });
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  await c.getByRole('checkbox', { name: 'Account' }).check();
  const at = await doubleTap(page, c.getByRole('button', { name: 'Send 1 selected' }));
  const send = c.getByRole('button', { name: 'Send answers' });
  await expect(send).toBeVisible();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await answers(page)).toEqual([]);
  expect(await covers(send, at)).toBe(true);
  await send.click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: ONBOARDING_REF,
      promptID: ONBOARDING_PROMPT,
      answer: { kind: 'question', answers: { [TONE]: 'Friendly and short', 'Which sections?': 'Account' } },
    },
  ]);
});

test('a double tap on an option answers its question only, never the next one unread', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  const three = c.getByRole('button', { name: '3 steps' });
  await expect(three).toBeEnabled();
  const at = await doubleTap(page, three);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  // The second tap fell on the next question's first option, which waited.
  await expect(c.locator('.c-head')).toContainText('3 of 3');
  await expect(c.locator('.q')).toHaveText(SKIP);
  const skip = c.getByRole('button', { name: 'Yes, show a Skip button' });
  expect(await covers(skip, at)).toBe(true);
  await skip.click();
  await c.getByRole('button', { name: 'Send answers' }).click();
  await expect.poll(() => answers(page)).toEqual([{ session: ONBOARDING_REF, promptID: ONBOARDING_PROMPT, answer: ONBOARDING_ANSWER }]);
});

test("a double tap on Send answer in the last step's Other form lands on the review, which waits", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  await c.getByRole('button', { name: '3 steps' }).click();
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('Only after the first run');
  const sendOne = c.getByRole('button', { name: 'Send answer', exact: true });
  await expect(sendOne).toBeEnabled();
  const at = await doubleTap(page, sendOne);
  const send = c.getByRole('button', { name: 'Send answers' });
  await expect(send).toBeVisible();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await answers(page)).toEqual([]);
  expect(await covers(send, at)).toBe(true);
  await send.click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: ONBOARDING_REF,
      promptID: ONBOARDING_PROMPT,
      answer: { kind: 'question', answers: { [TONE]: 'Friendly and short', [STEPS]: '3 steps', [SKIP]: 'Only after the first run' } },
    },
  ]);
});

test('after a step the focus is on the next question, so Enter answers nothing', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).focus();
  await page.keyboard.press('Enter');
  await expect(c.locator('.c-head')).toContainText('2 of 3');
  await expect(c.locator('.q')).toBeFocused();
  await expect(c.getByRole('button', { name: '3 steps' })).toBeEnabled();
  await page.keyboard.press('Enter');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(200);
  await expect(c.locator('.c-head')).toContainText('2 of 3');
  await expect(c.locator('.q')).toHaveText(STEPS);
  await expect(c.locator('textarea')).toHaveCount(0);
  // Back moves the focus to the question too.
  await c.getByRole('button', { name: 'Back' }).focus();
  await page.keyboard.press('Enter');
  await expect(c.locator('.q')).toHaveText(TONE);
  await expect(c.locator('.q')).toBeFocused();
  expect(await answers(page)).toEqual([]);
});

test('Cancel on a multi-select Other keeps the Other value recorded before', async ({ page, appHost }) => {
  const multi = { header: 'Sections', text: 'Which sections?', multiSelect: true, options: [{ label: 'Account' }, { label: 'Billing' }] };
  const base = MOCK.prompts[`local:${ONBOARDING_REF.terminalID}`][0];
  await openApp(page, appHost, { scenario: withOnboardingPrompts({ questions: [multi, base.questions[1]] }) });
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('checkbox', { name: 'Account' }).check();
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('Privacy');
  await c.getByRole('button', { name: 'Done' }).click();
  // Done stays on the question: only Send N selected moves on.
  await expect(c.locator('.q')).toHaveText('Which sections?');
  await expect(c.getByRole('checkbox', { name: 'Privacy' })).toBeChecked();
  await c.getByRole('button', { name: 'Send 2 selected' }).click();
  await expect(c.locator('.q')).toHaveText(STEPS);
  await c.getByRole('button', { name: 'Back' }).click();
  // The form opens with the recorded text; Cancel closes it and the value stays.
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await expect(c.getByRole('textbox', { name: 'Type your answer' })).toHaveValue('Privacy');
  await c.getByRole('button', { name: 'Cancel' }).click();
  await expect(c.getByRole('checkbox', { name: 'Privacy' })).toBeChecked();
  await c.getByRole('button', { name: 'Send 2 selected' }).click();
  await c.getByRole('button', { name: '3 steps' }).click();
  await expect(c.locator('.review button').nth(0)).toHaveText('SectionsAccount, Privacy');
  await c.getByRole('button', { name: 'Send answers' }).click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: ONBOARDING_REF,
      promptID: ONBOARDING_PROMPT,
      answer: { kind: 'question', answers: { 'Which sections?': 'Account, Privacy', [STEPS]: '3 steps' } },
    },
  ]);
});

/**
 * The transcript's receipt rows' texts.
 * @param {Page} page
 */
function receipts(page) {
  return app(page).locator('.tx .receipt');
}

test("answering leaves 'Answered on this phone: Yes, add the test' in the transcript", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await expect(receipts(page)).toHaveCount(0);
  await card(page).getByRole('button', { name: 'Yes, add the test' }).click();
  // The fake laptop resolves it as a phone's answer right after it replies delivered.
  await expect(receipts(page)).toHaveText(['Answered on this phone: Yes, add the test']);
  await expect(receipts(page).locator('svg')).toHaveCount(1);
  await expect(card(page)).toHaveCount(0);
  expect(await answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Yes, add the test' } } },
  ]);
});

test('an answer the laptop took shows Answered with its summary until the prompt closes', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Settings screen');
  await hostCall(page, 'setReply', 'prompt.answer', { result: { outcome: 'delivered' } });
  const c = card(page);
  await c.getByRole('checkbox', { name: 'Account' }).check();
  await c.getByRole('checkbox', { name: 'Notifications' }).check();
  await c.getByRole('button', { name: 'Send 2 selected' }).click();
  const done = app(page).locator('.dock .card.done');
  await expect(done).toHaveAttribute('role', 'status');
  await expect(done.locator('b')).toHaveText('Answered');
  expect(await answers(page)).toEqual([
    { session: SETTINGS_REF, promptID: SETTINGS_PROMPT, answer: { kind: 'question', answers: { [SETTINGS_QUESTION]: 'Notifications, Account' } } },
  ]);
  await expect(done.locator('small')).toHaveText('Notifications, Account');
  await expect(done.locator('.ok svg')).toHaveCount(1);
  await expect(done.locator('button')).toHaveCount(0);
  await expect(receipts(page)).toHaveCount(0);
  // The laptop closes it, naming no one: the receipt is this phone's, from its own answer.
  await hostCall(page, 'emit', 'prompt.changed', { session: SETTINGS_REF, prompts: [], resolved: [{ promptID: SETTINGS_PROMPT, answeredBy: 'unknown' }] });
  await expect(receipts(page)).toHaveText(['Answered on this phone: Notifications, Account']);
  await expect(done).toHaveCount(0);
});

test('a laptop answer shows the elsewhere card, and OK removes it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await expect(card(page).locator('.q')).toHaveText(LOGIN_QUESTION);
  await hostCall(page, 'emit', 'prompt.changed', { session: LOGIN_REF, prompts: [], resolved: [{ promptID: LOGIN_PROMPT, answeredBy: 'laptop' }] });
  const done = app(page).locator('.dock .card.done');
  await expect(done).toHaveAttribute('role', 'status');
  // OK came where the choices were, so it waits at first.
  await expect(done.getByRole('button', { name: 'OK' })).toBeDisabled();
  await expect(done.locator('b')).toHaveText('Already answered on the laptop');
  await expect(done.locator('small')).toHaveText('Someone answered this question at the laptop first.');
  await expect(receipts(page)).toHaveText(['Answered on the laptop']);
  await done.getByRole('button', { name: 'OK' }).click();
  await expect(app(page).locator('.dock .card, .dock .card-strip')).toHaveCount(0);
  await expect(receipts(page)).toHaveText(['Answered on the laptop']);
  expect(await answers(page)).toEqual([]);
});

test('a laptop answer to a permission says "permission"', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'SSE reconnect');
  await expect(card(page).locator('.perm-tool')).toHaveText('Bash');
  await hostCall(page, 'emit', 'prompt.changed', { session: SSE_REF, prompts: [], resolved: [{ promptID: SSE_PROMPT, answeredBy: 'laptop' }] });
  const done = app(page).locator('.dock .card.done');
  await expect(done.locator('b')).toHaveText('Already answered on the laptop');
  await expect(done.locator('small')).toHaveText('Someone answered this permission at the laptop first.');
});

test("another phone's answer reads 'Already answered on another phone' and 'Answered on another phone'", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await expect(card(page).locator('.q')).toHaveText(LOGIN_QUESTION);
  await hostCall(page, 'emit', 'prompt.changed', { session: LOGIN_REF, prompts: [], resolved: [{ promptID: LOGIN_PROMPT, answeredBy: 'phone' }] });
  const done = app(page).locator('.dock .card.done');
  await expect(done.locator('b')).toHaveText('Already answered on another phone');
  await expect(done.locator('small')).toHaveText('Someone answered this question on another phone first.');
  await expect(receipts(page)).toHaveText(['Answered on another phone']);
  await done.getByRole('button', { name: 'OK' }).click();
  await expect(done).toHaveCount(0);
});

test("an answer that lost the race reads as the laptop's, never as this phone's", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await hostCall(page, 'setReply', 'prompt.answer', { result: { outcome: 'already_resolved' } });
  await card(page).getByRole('button', { name: 'Yes, add the test' }).click();
  const done = app(page).locator('.dock .card.done');
  await expect(done.locator('b')).toHaveText('Already answered on the laptop');
  await hostCall(page, 'emit', 'prompt.changed', { session: LOGIN_REF, prompts: [], resolved: [{ promptID: LOGIN_PROMPT, answeredBy: 'laptop' }] });
  await expect(receipts(page)).toHaveText(['Answered on the laptop']);
  await expect(done.locator('b')).toHaveText('Already answered on the laptop');
  expect(await answers(page)).toEqual([
    { session: LOGIN_REF, promptID: LOGIN_PROMPT, answer: { kind: 'question', answers: { [LOGIN_QUESTION]: 'Yes, add the test' } } },
  ]);
});

test('after OK on an elsewhere card the next prompt shows, its choices held at first', async ({ page, appHost }) => {
  const second = { id: 'sse-second', summary: 'Show the reconnect log', target: 'tail -n 50 logs/stream.log' };
  await openApp(page, appHost, { scenario: withSSEPrompts({ id: SSE_PROMPT }, second) });
  await openSessionByName(page, 'SSE reconnect');
  await expect(card(page).locator('pre.perm-target')).toHaveText(SSE_TARGET);
  await hostCall(page, 'emit', 'prompt.changed', {
    session: SSE_REF, prompts: [{ ...MOCK.prompts[SSE_KEY][0], ...second }], resolved: [{ promptID: SSE_PROMPT, answeredBy: 'laptop' }],
  });
  const done = app(page).locator('.dock .card.done');
  await expect(done.locator('b')).toHaveText('Already answered on the laptop');
  await done.getByRole('button', { name: 'OK' }).click();
  const c = card(page);
  await expect(c.locator('pre.perm-target')).toHaveText(second.target);
  await expect(c.locator('button.opt.pri')).toBeDisabled();
  await expect(c.locator('button.opt.pri')).toBeEnabled();
  await c.locator('button.opt.pri').click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: 'sse-second', answer: { kind: 'permission', decision: 'allow' } },
  ]);
});

test("a card another prompt's elsewhere card displaced comes back as the user left it", async ({ page, appHost }) => {
  await openApp(page, appHost, { scenario: withOnboardingPrompts({}, { id: 'onboarding-second' }) });
  await openSessionByName(page, 'Onboarding copy');
  const c = card(page);
  await c.getByRole('button', { name: 'Friendly and short' }).click();
  await c.getByRole('button', { name: 'Other answer…' }).click();
  await c.getByRole('textbox', { name: 'Type your answer' }).fill('Five, with a tour');
  // The laptop answers the other prompt: its card waits for OK in this one's place.
  await hostCall(page, 'emit', 'prompt.changed', {
    session: ONBOARDING_REF,
    prompts: [MOCK.prompts[`local:${ONBOARDING_REF.terminalID}`][0]],
    resolved: [{ promptID: 'onboarding-second', answeredBy: 'laptop' }],
  });
  const done = app(page).locator('.dock .card.done');
  await expect(done.locator('b')).toHaveText('Already answered on the laptop');
  const ok = done.getByRole('button', { name: 'OK' });
  await expect(ok).toBeDisabled();
  await ok.click();
  await expect(c.locator('.c-head')).toContainText('2 of 3');
  await expect(c.getByRole('textbox', { name: 'Type your answer' })).toHaveValue('Five, with a tour');
  await c.getByRole('button', { name: 'Send answer' }).click();
  await c.getByRole('button', { name: 'No, every step is required' }).click();
  await c.getByRole('button', { name: 'Send answers' }).click();
  await expect.poll(() => answers(page)).toEqual([
    {
      session: ONBOARDING_REF,
      promptID: ONBOARDING_PROMPT,
      answer: { kind: 'question', answers: { [TONE]: 'Friendly and short', [STEPS]: 'Five, with a tour', [SKIP]: 'No, every step is required' } },
    },
  ]);
});

test("a hidden permission another prompt's elsewhere card displaced comes back hidden, its deny text kept", async ({ page, appHost }) => {
  const second = { id: 'sse-second', summary: 'Show the reconnect log', target: 'tail -n 50 logs/stream.log' };
  await openApp(page, appHost, { scenario: withSSEPrompts({ id: SSE_PROMPT }, second) });
  await openSessionByName(page, 'SSE reconnect');
  const c = card(page);
  await c.getByRole('button', { name: 'No' }).click();
  await c.getByLabel('Tell Claude what to do instead (optional)').fill('Use the cached log');
  await c.getByRole('button', { name: 'Hide' }).click();
  await hostCall(page, 'emit', 'prompt.changed', {
    session: SSE_REF, prompts: [MOCK.prompts[SSE_KEY][0]], resolved: [{ promptID: 'sse-second', answeredBy: 'phone' }],
  });
  const done = app(page).locator('.dock .card.done');
  await expect(done.locator('b')).toHaveText('Already answered on another phone');
  await done.getByRole('button', { name: 'OK' }).click();
  const strip = app(page).locator('.dock button.card-strip');
  await expect(strip).toHaveText('Permission waitingShow');
  await strip.click();
  await expect(c.locator('pre.perm-target')).toHaveText(SSE_TARGET);
  await expect(c.getByLabel('Tell Claude what to do instead (optional)')).toHaveValue('Use the cached log');
  await c.getByRole('button', { name: 'Deny' }).click();
  await expect.poll(() => answers(page)).toEqual([
    { session: SSE_REF, promptID: SSE_PROMPT, answer: { kind: 'permission', decision: 'deny', message: 'Use the cached log' } },
  ]);
});

// MARK: - The composer

/** main's Claude session (idle, no prompt), Checkout v2's Claude session (working), and Docs refresh's (parked). */
const MAIN_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000101' };
const CHECKOUT_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000103' };
const DOCS_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000106' };
/** The mock's refusal for a message sent while Claude works (mock 1265). */
const WORKING_REFUSAL = 'Not sent. Claude is still working. Send again when it stops.';

/**
 * The params of every `message.send` that reached the fake laptop, in order.
 * @param {Page} page
 */
async function messages(page) {
  return (await hostRequests(page)).filter((r) => r.method === 'message.send').map((r) => r.params);
}

/**
 * The composer's textarea.
 * @param {Page} page
 */
function field(page) {
  return app(page).locator('.dock .comp textarea.field');
}

/**
 * The composer's Send.
 * @param {Page} page
 */
function sendButton(page) {
  return app(page).locator('.dock .comp button.send');
}

/**
 * `locator`'s box, which must exist.
 * @param {import('@playwright/test').Locator} locator
 */
async function box(locator) {
  const b = await locator.boundingBox();
  if (b === null) throw new Error('no box');
  return b;
}

test('Send is disabled until there is text, and Enter is a new line', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  const text = field(page);
  await expect(text).toHaveAttribute('rows', '1');
  await expect(text).toHaveAttribute('placeholder', 'Message');
  await expect(text).toHaveAttribute('aria-label', 'Message');
  await expect(app(page).getByRole('textbox', { name: 'Message' })).toHaveCount(1);
  const send = sendButton(page);
  await expect(send).toHaveText('Send');
  await expect(send).toBeDisabled();
  for (const blank of ['   ', ' \n\n ']) {
    await text.fill(blank);
    await page.waitForTimeout(TAP_GUARD_MS);
    await expect(send).toBeDisabled();
  }
  await text.fill('Run the unit tests.');
  await expect(send).toBeEnabled();
  await text.fill('');
  await expect(send).toBeDisabled();
  // Enter types a new line; only the button sends.
  await text.fill('Run the unit tests.');
  await text.press('Enter');
  await text.press('Enter');
  await expect(text).toHaveValue('Run the unit tests.\n\n');
  await page.waitForTimeout(200);
  expect(await messages(page)).toEqual([]);
});

test('sending clears the text once the laptop accepts it, and the message shows in the transcript', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  const text = field(page);
  // Sent as typed: the leading spaces and the trailing new line go too.
  await text.fill('  Run the unit tests.\n');
  await sendButton(page).click();
  await expect.poll(() => messages(page)).toEqual([{ session: MAIN_REF, text: '  Run the unit tests.\n' }]);
  await expect(text).toHaveValue('');
  await expect(sendButton(page)).toBeDisabled();
  await expect(app(page).locator('.tx')).toContainText('Run the unit tests.');
  await expect(app(page).locator('.dock .refusal')).toHaveCount(0);
});

test("a working session's Send is enabled and sends: the laptop decides", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  await expect(app(page).locator('.s-head .t2a')).toContainText('Working');
  await field(page).fill('Also add a progress bar above the steps.');
  await expect(sendButton(page)).toHaveText('Send');
  await sendButton(page).click();
  await expect.poll(() => messages(page)).toEqual([{ session: CHECKOUT_REF, text: 'Also add a progress bar above the steps.' }]);
  await expect(field(page)).toHaveValue('');
});

test("a parked session's button reads Send and wake, and sending toasts that it wakes the session", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Docs refresh');
  const send = sendButton(page);
  await expect(send).toHaveText('Send and wake');
  await expect(send).toBeDisabled();
  await field(page).fill('Add a troubleshooting section too.');
  await send.click();
  await expect(app(page).locator('.toast')).toHaveText('Waking the session, then sending…');
  await expect.poll(() => messages(page)).toEqual([{ session: DOCS_REF, text: 'Add a troubleshooting section too.' }]);
  await expect(field(page)).toHaveValue('');
});

test("a refusal shows the laptop's reason and keeps the text; typing takes it down", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  await hostCall(page, 'setReply', 'message.send', { error: { code: 'refused', message: WORKING_REFUSAL } });
  const text = field(page);
  await text.fill('Also add a progress bar above the steps.');
  await sendButton(page).click();
  const refusal = app(page).locator('.dock > .refusal');
  await expect(refusal).toHaveText(WORKING_REFUSAL);
  await expect(refusal).toHaveAttribute('role', 'alert');
  await expect(refusal.locator('svg')).toHaveCount(1);
  await expect(text).toHaveValue('Also add a progress bar above the steps.');
  // Right above the composer.
  expect(await refusal.evaluate((el) => el.nextElementSibling?.classList.contains('comp'))).toBe(true);
  // Nothing was sent again.
  await page.waitForTimeout(300);
  expect(await messages(page)).toEqual([{ session: CHECKOUT_REF, text: 'Also add a progress bar above the steps.' }]);
  await expect(sendButton(page)).toBeEnabled();
  await text.press('End');
  await text.pressSequentially(' Please.');
  await expect(refusal).toHaveCount(0);
  await expect(text).toHaveValue('Also add a progress bar above the steps. Please.');
});

test('a double click on Send posts one message.send, and the text stays editable while it is on its way', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  await hostCall(page, 'hold', 'message.send');
  const text = field(page);
  await text.fill('Run the unit tests.');
  await expect(sendButton(page)).toBeEnabled();
  await sendButton(page).dblclick();
  await expect.poll(() => messages(page)).toHaveLength(1);
  await expect(sendButton(page)).toBeDisabled();
  // A tap on the disabled Send does nothing: dispatch the click past Playwright's check.
  await sendButton(page).dispatchEvent('click');
  await expect(text).toBeEditable();
  await text.press('End');
  await text.pressSequentially(' Then the lint.');
  await hostCall(page, 'release', 'message.send');
  // The laptop took the first text; what was typed meanwhile stays.
  await expect(app(page).locator('.tx')).toContainText('Run the unit tests.');
  await expect(text).toHaveValue('Run the unit tests. Then the lint.');
  await page.waitForTimeout(300);
  expect(await messages(page)).toEqual([{ session: MAIN_REF, text: 'Run the unit tests.' }]);
});

test('a session that cannot take messages shows the note in place of the composer', async ({ page, appHost }) => {
  const reason = 'This session cannot take messages from a phone.';
  await openApp(page, appHost, {
    scenario: withSession(MAIN_REF.terminalID, (s) => { s.capabilities.send = { available: false, reason }; }),
  });
  await openSessionByName(page, 'main');
  await expect(app(page).locator('.dock > .dock-note')).toHaveText('Sending is not available for this session.');
  await expect(app(page).locator('.dock textarea, .dock button')).toHaveCount(0);
  await expect(app(page).locator('.dock')).not.toContainText(reason);
});

test('the prompt card comes first, then the composer, each with its own refusal', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const dock = app(page).locator('.dock');
  await expect(dock.locator(':scope > .card')).toBeVisible();
  expect(await dock.evaluate((el) => [...el.children].map((c) => c.className))).toEqual(['card', 'comp']);
  await hostCall(page, 'setReply', 'message.send', { error: { code: 'refused', message: WORKING_REFUSAL } });
  await hostCall(page, 'setReply', 'prompt.answer', { error: { code: 'refused', message: 'The laptop refused the answer.' } });
  await field(page).fill('Also add a progress bar above the steps.');
  await sendButton(page).click();
  await card(page).getByRole('button', { name: 'Yes, add the test' }).click();
  await expect(card(page).locator('.refusal')).toHaveText('The laptop refused the answer.');
  await expect(dock.locator(':scope > .refusal')).toHaveText(WORKING_REFUSAL);
  expect(await dock.evaluate((el) => [...el.children].map((c) => c.className))).toEqual(['card', 'refusal', 'comp']);
});

test('a card that appears or grows above the composer, a refusal, and a growing text all leave Send where it was', async ({ page, appHost }) => {
  await openApp(page, appHost, { scenario: withSSEPrompts() });
  await openSessionByName(page, 'SSE reconnect');
  await page.waitForTimeout(OPENING_MS + 200);
  await expect(card(page)).toHaveCount(0);
  const send = sendButton(page);
  await field(page).fill('Run only the unit tests for now.');
  await expect(send).toBeEnabled();
  const before = await box(send);
  // A permission comes, and the dock grows upward over the transcript.
  await hostCall(page, 'emit', 'prompt.changed', { session: SSE_REF, prompts: [MOCK.prompts[SSE_KEY][0]] });
  await expect(card(page).locator('button.opt.pri')).toBeVisible();
  expect(await box(send)).toEqual(before);
  // Its deny form opens, and the card grows.
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  await card(page).getByRole('button', { name: 'No' }).click();
  await expect(card(page).getByRole('button', { name: 'Deny' })).toBeVisible();
  expect(await box(send)).toEqual(before);
  // The composer's refusal shows above it.
  await hostCall(page, 'setReply', 'message.send', { error: { code: 'refused', message: WORKING_REFUSAL } });
  await send.click();
  await expect(app(page).locator('.dock > .refusal')).toHaveText(WORKING_REFUSAL);
  expect(await box(send)).toEqual(before);
  // The text grows to three lines.
  await field(page).fill('Run only the unit tests for now.\nThen the lint.\nThen stop.');
  await expect(send).toBeEnabled();
  expect(await box(send)).toEqual(before);
});

test('the textarea grows with its text to at most 140 px', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  const text = field(page);
  const height = () => text.evaluate((el) => el.getBoundingClientRect().height);
  await text.fill('Run the unit tests.');
  const one = await height();
  expect(one).toBeGreaterThanOrEqual(44);
  expect(one).toBeLessThan(50);
  await text.fill('One.\nTwo.\nThree.');
  await expect.poll(height).toBeGreaterThan(one + 30);
  await text.fill(Array.from({ length: 20 }, (_, i) => `Line ${i + 1}.`).join('\n'));
  await expect.poll(height).toBe(140);
  await text.fill('Short again.');
  await expect.poll(height).toBe(one);
});

test('the dock sits above the keyboard', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await expect(card(page)).toBeVisible();
  const text = field(page);
  await text.fill('Run only the unit tests for now.');
  await text.focus();
  const { width, height } = /** @type {{ width: number, height: number }} */ (page.viewportSize());
  await hostCall(page, 'sendEnv', {
    safeArea: { top: 0, right: 0, bottom: 0, left: 0 },
    viewport: { width, height: height - 336, offsetTop: 0, offsetLeft: 0, scale: 1 },
    layout: { width, height },
  });
  const dock = app(page).locator('.dock');
  await expect.poll(() => dock.evaluate((el) => getComputedStyle(el).paddingBottom)).toBe('346px');
  await expect(text).toBeFocused();
  // The textarea and Send end above the keyboard's top edge, and the card above them is still there.
  for (const el of [text, sendButton(page)]) {
    await expect.poll(() => el.evaluate((node) => node.getBoundingClientRect().bottom <= window.innerHeight - 336)).toBe(true);
    await expect(el).toBeVisible();
  }
  await expect(card(page)).toBeAttached();
  await hostCall(page, 'sendEnv', null);
});

test("Send waits when it first shows: a session opened with a kept draft holds it at first", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  await field(page).fill('Run the unit tests.');
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
  await openSessionByName(page, 'main');
  const send = sendButton(page);
  await expect(field(page)).toHaveValue('Run the unit tests.');
  // A tap the moment the session opens, as the second tap of a double tap on its row lands.
  const at = await tap(page, send);
  await expect(send).toBeDisabled();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await messages(page)).toEqual([]);
  await expect(send).toBeEnabled();
  await page.mouse.click(at.x, at.y);
  await expect.poll(() => messages(page)).toEqual([{ session: MAIN_REF, text: 'Run the unit tests.' }]);
});

test('Send waits when its label changes, since the wider label moves its edge over the text', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  await field(page).fill('Run the unit tests.');
  const send = sendButton(page);
  await expect(send).toBeEnabled();
  const row = structuredClone(MOCK.rows.find((/** @type {any} */ r) => r.name === 'main'));
  row.sessions[0].status = { ...row.sessions[0].status, chip: 'parked' };
  await hostCall(page, 'emit', 'sessions.changed', { rows: [row], removedRowIDs: [] });
  await expect(send).toHaveText('Send and wake');
  await expect(send).toBeDisabled();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  await expect(send).toBeEnabled();
  expect(await messages(page)).toEqual([]);
});
