// The session-mod channel's client: requests over mod.sock and the poll loop.
// Each test gets a stand-in daemon of its own, so a poll loop a test leaves
// running holds only that test's stand-in.
import { expect, test } from 'claude-code/testing'

import { queueReport, readChannelEnv, request, standReport, startPolling, withdrawReport } from '../hooks/shared/channel.ts'
import { CHANNEL, CHANNEL_VARIABLES, fakeChannel, flush, sentTo } from './fake-channel.ts'

const POLL_FROM_ZERO = '/v1/poll?after=0'

test('requestSendsBearerAndIdentityHeadersOverSocket', async () => {
  const fake = fakeChannel()

  const reply = await request(fake.engine, CHANNEL, 'POST', '/v1/prompts/open', { toolUseID: 'toolu_1' })

  expect(reply).toEqual({ status: 200, json: {} })
  expect(fake.sent).toEqual([
    {
      method: 'POST',
      path: '/v1/prompts/open',
      url: 'http://tbd/v1/prompts/open',
      headers: {
        Authorization: `Bearer ${CHANNEL.token}`,
        'X-TBD-Terminal': CHANNEL.terminalId,
        'X-TBD-Incarnation': CHANNEL.incarnationId,
        'Content-Type': 'application/json',
      },
      socketPath: CHANNEL.socket,
      body: { toolUseID: 'toolu_1' },
    },
  ])

  // A request that cannot connect resolves null and never rejects.
  fake.replies.set('POST /v1/prompts/toolu_1/closed', 'fail')
  expect(await request(fake.engine, CHANNEL, 'POST', '/v1/prompts/toolu_1/closed', {})).toBeNull()
})

test('pollBacksOffOneTwoFiveTen', async () => {
  const fake = fakeChannel()

  startPolling(fake.engine, CHANNEL)
  await fake.advance(0)

  for (const delay of [1_000, 2_000, 5_000, 10_000, 10_000]) {
    await fake.answer('GET', POLL_FROM_ZERO, 'fail')
    expect(fake.sleeps.at(-1)).toBe(delay)
    // Nothing is polled until the wait is over.
    await fake.advance(delay - 1)
    expect(fake.heldCount('GET', POLL_FROM_ZERO)).toBe(0)
    await fake.advance(1)
    expect(fake.heldCount('GET', POLL_FROM_ZERO)).toBe(1)
  }
  expect(fake.sleeps).toEqual([1_000, 2_000, 5_000, 10_000, 10_000])

  // A refused token is a failed poll too, and a success resets the backoff.
  await fake.answer('GET', POLL_FROM_ZERO, { status: 401, json: { error: 'unauthorized' } })
  expect(fake.sleeps.at(-1)).toBe(10_000)
  await fake.advance(10_000)
  await fake.answer('GET', POLL_FROM_ZERO, { status: 200, json: { items: [] } })
  await fake.answer('GET', POLL_FROM_ZERO, 'fail')
  expect(fake.sleeps.at(-1)).toBe(1_000)

  // Failures log at debug level only: nothing reaches the transcript.
  expect(fake.logs.length).toBeGreaterThan(0)
  expect(fake.logOptions).toHaveLength(fake.logs.length)
  for (const options of fake.logOptions) {
    expect(options).toEqual({ to: 'debug' })
  }
})

test('queuedReportRetriesThenGivesUp', async () => {
  const fake = fakeChannel()
  const path = '/v1/prompts/toolu_1/closed'
  fake.replies.set(`POST ${path}`, 'fail')

  queueReport(fake.engine, CHANNEL, path, { by: 'terminal' })
  // Nothing goes out until the timer runs.
  expect(sentTo(fake, 'POST', path)).toEqual([])
  await fake.advance(0)
  expect(sentTo(fake, 'POST', path)).toHaveLength(1)

  // Retried after 1, 2, 5 and 5 s: five attempts in all, then dropped.
  for (const [index, delay] of [1_000, 2_000, 5_000, 5_000].entries()) {
    await fake.advance(delay - 1)
    expect(sentTo(fake, 'POST', path)).toHaveLength(index + 1)
    await fake.advance(1)
    expect(sentTo(fake, 'POST', path)).toHaveLength(index + 2)
  }
  await fake.advance(60_000)
  expect(sentTo(fake, 'POST', path)).toHaveLength(5)
  expect(sentTo(fake, 'POST', path).map(request => request.body)).toEqual(Array(5).fill({ by: 'terminal' }))

  // A daemon error is retried too; the first attempt that reaches the daemon
  // ends the report.
  const other = '/v1/prompts/toolu_2/closed'
  fake.replies.set(`POST ${other}`, { status: 503, json: { error: 'unavailable' } })
  queueReport(fake.engine, CHANNEL, other, { by: 'terminal' })
  await fake.advance(0)
  fake.replies.set(`POST ${other}`, { status: 200, json: {} })
  await fake.advance(1_000)
  await fake.advance(60_000)
  expect(sentTo(fake, 'POST', other)).toHaveLength(2)

  // Failures log at debug level only.
  expect(fake.logs.length).toBeGreaterThan(0)
  for (const options of fake.logOptions) {
    expect(options).toEqual({ to: 'debug' })
  }
})

test('pollDropsRepeatedSeq', async () => {
  const fake = fakeChannel()

  startPolling(fake.engine, CHANNEL)
  await fake.advance(0)
  await fake.answer('GET', POLL_FROM_ZERO, {
    status: 200,
    json: { items: [{ seq: 2, kind: 'later', body: {} }, { seq: 1, kind: 'later', body: {} }] },
  })
  // The daemon resends what was not yet confirmed, and seq 2 was.
  await fake.answer('GET', '/v1/poll?after=2', {
    status: 200,
    json: { items: [{ seq: 2, kind: 'later', body: {} }, { seq: 3, kind: 'later', body: {} }] },
  })
  // A failure never moves `after` back.
  await fake.answer('GET', '/v1/poll?after=3', 'fail')
  await fake.advance(1_000)
  await flush()

  expect(fake.heldCount('GET', '/v1/poll?after=3')).toBe(1)
  expect(sentTo(fake, 'GET', POLL_FROM_ZERO)).toHaveLength(1)
  expect(fake.logs.filter(line => line.includes('no handler for item'))).toEqual([
    'session mod channel: no handler for item 1 (later)',
    'session mod channel: no handler for item 2 (later)',
    'session mod channel: no handler for item 3 (later)',
  ])
})

test('repostSkipsAReportWithdrawnMidRepost', async () => {
  const fake = fakeChannel()
  standReport('toolu_r1', '/v1/prompts/open', { toolUseID: 'toolu_r1' })
  standReport('toolu_r2', '/v1/prompts/open-second', { toolUseID: 'toolu_r2' })
  fake.replies.set('POST /v1/prompts/open', 'hold')

  startPolling(fake.engine, CHANNEL)
  await fake.advance(0)
  await fake.answer('GET', POLL_FROM_ZERO, 'fail')
  await fake.advance(1_000)
  await fake.answer('GET', POLL_FROM_ZERO, { status: 200, json: { items: [] } })
  expect(fake.heldCount('POST', '/v1/prompts/open')).toBe(1)

  // The second dialog closes while the first is being posted again.
  withdrawReport('toolu_r2')
  await fake.answer('POST', '/v1/prompts/open', { status: 200, json: {} })

  expect(sentTo(fake, 'POST', '/v1/prompts/open-second')).toEqual([])
  withdrawReport('toolu_r1')
})

// The only test here that reads the environment: it is read once per load.
test('missingEnvDisablesChannel', async () => {
  const withoutToken = Object.fromEntries(Object.entries(CHANNEL_VARIABLES).filter(([name]) => name !== 'TBD_MOD_TOKEN'))
  const fake = fakeChannel(withoutToken)

  expect(await readChannelEnv(fake.engine)).toBeNull()
  expect(fake.sent).toEqual([])
})
