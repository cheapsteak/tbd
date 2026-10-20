// The session-mod channel's client: requests over mod.sock and the poll loop.
// Each test gets a stand-in daemon of its own, so a poll loop a test leaves
// running holds only that test's stand-in.
import { expect, test } from 'claude-code/testing'

import { readChannelEnv, request, startPolling } from '../hooks/shared/channel.ts'
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

  // Failures log at debug level only.
  expect(fake.logs.length).toBeGreaterThan(0)
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

// The only test here that reads the environment: it is read once per load.
test('missingEnvDisablesChannel', async () => {
  const withoutToken = Object.fromEntries(Object.entries(CHANNEL_VARIABLES).filter(([name]) => name !== 'TBD_MOD_TOKEN'))
  const fake = fakeChannel(withoutToken)

  expect(await readChannelEnv(fake.engine)).toBeNull()
  expect(fake.sent).toEqual([])
})
