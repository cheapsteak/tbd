// prompt-answer's hooks, called directly with a stand-in `$` and a stand-in
// daemon (fake-channel.ts). Each test starts its tool calls itself and lets
// every one of them settle, so the feature's records of calls in flight and
// open dialogs, which last as long as this file, are empty between tests.
import type { ClassicEventOf, Frozen, Next, ToolCallInput } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { permissionRequested, toolCalled } from '../hooks/features/prompt-answer.ts'
import { startPolling } from '../hooks/shared/channel.ts'
import { CHANNEL, SESSION_ID, below, fakeChannel, flush, sentTo } from './fake-channel.ts'
import type { Below, FakeChannel } from './fake-channel.ts'

type PermissionInput = ClassicEventOf['classic.PermissionRequest']

const OPEN = '/v1/prompts/open'
const TOOL_RESULT = { result: { ok: true } }
// What the hooks beneath a permission request answer when nothing decides.
const PASSED = {}
const DENY_TEXT = 'The user declined this from TBD.'
const SESSION_RULE = [
  { type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'ls:*' }], behavior: 'allow', destination: 'session' },
]

const answerPath = (id: string): string => `/v1/prompts/${id}/answer`
const receiptPath = (id: string): string => `/v1/prompts/${id}/receipt`
const closedPath = (id: string): string => `/v1/prompts/${id}/closed`

type Call = { done: Promise<unknown>; tool: Below<Next<'tool.call'>> }
type Dialog = { done: Promise<unknown>; below: Below<Next<'classic.PermissionRequest'>> }

/** Starts a tool call through the feature's tool.call hook; the tool runs until the test settles it. */
function startCall(fake: FakeChannel, input: Record<string, unknown>): Call {
  const tool = below<Next<'tool.call'>>()
  const done = toolCalled(fake.engine, CHANNEL, input as unknown as Frozen<ToolCallInput>, tool.next)
  return { done, tool }
}

/** Raises a permission dialog through the feature's classic.PermissionRequest hook. */
function requestPermission(fake: FakeChannel, input: Record<string, unknown>): Dialog {
  const passOn = below<Next<'classic.PermissionRequest'>>(PASSED)
  const event = {
    hook_event_name: 'PermissionRequest',
    session_id: SESSION_ID,
    transcript_path: '',
    cwd: '/work',
    ...input,
  }
  const done = permissionRequested(fake.engine, CHANNEL, event as unknown as Frozen<PermissionInput>, passOn.next)
  return { done, below: passOn }
}

/** The tool use ids the mod posted `open` for, in order. */
function openedIds(fake: FakeChannel): unknown[] {
  return sentTo(fake, 'POST', OPEN).map(request => (request.body as { toolUseID: unknown }).toolUseID)
}

async function finish(call: Call, result: unknown = TOOL_RESULT): Promise<void> {
  call.tool.settle(result)
  await call.done
  await flush()
}

test('pairsPermissionWithCallByExactArgs', async () => {
  const fake = fakeChannel()
  const first = startCall(fake, { tool: 'Read', tool_use_id: 'toolu_a', file_path: '/a', limit: 10 })
  const second = startCall(fake, { tool: 'Read', tool_use_id: 'toolu_b', file_path: '/b', limit: 10 })
  await flush()

  // The payload's keys come in another order; the values decide.
  const forSecond = requestPermission(fake, { tool_name: 'Read', tool_input: { limit: 10, file_path: '/b' } })
  await flush()
  const forFirst = requestPermission(fake, { tool_name: 'Read', tool_input: { limit: 10, file_path: '/a' } })
  await flush()
  expect(openedIds(fake)).toEqual(['toolu_b', 'toolu_a'])

  await fake.answer('GET', answerPath('toolu_a'), { status: 200, json: { state: 'decision', decision: { behavior: 'deny', message: DENY_TEXT } } })
  await fake.answer('GET', answerPath('toolu_b'), { status: 200, json: { state: 'decision', decision: { behavior: 'allow' } } })

  expect(await forFirst.done).toEqual({ decision: { behavior: 'deny', message: DENY_TEXT } })
  expect(await forSecond.done).toEqual({ decision: { behavior: 'allow' } })
  await finish(first)
  await finish(second)
  expect(sentTo(fake, 'POST', receiptPath('toolu_a'))).toHaveLength(1)
  expect(sentTo(fake, 'POST', receiptPath('toolu_b'))).toHaveLength(1)
  expect(fake.sent.filter(request => request.path.endsWith('/closed'))).toEqual([])

  // A dialog with no call in flight is left to the terminal.
  const stray = requestPermission(fake, { tool_name: 'Read', tool_input: { file_path: '/a', limit: 10 } })
  expect(await stray.done).toEqual(PASSED)
  expect(stray.below.calls()).toBe(1)
  expect(openedIds(fake)).toHaveLength(2)
})

test('allowReturnsDecisionAndPostsReceipt', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_1', command: 'ls' })
  await flush()

  const dialog = requestPermission(fake, { tool_name: 'Bash', tool_input: { command: 'ls' } })
  await flush()
  expect(sentTo(fake, 'POST', OPEN).map(request => request.body)).toEqual([
    { toolUseID: 'toolu_1', sessionID: SESSION_ID, toolName: 'Bash', toolInput: { command: 'ls' }, suggestions: null },
  ])
  // Nothing answered yet: the wait is asked again.
  await fake.answer('GET', answerPath('toolu_1'), { status: 200, json: { state: 'pending' } })
  await fake.answer('GET', answerPath('toolu_1'), { status: 200, json: { state: 'decision', decision: { behavior: 'allow' } } })

  expect(await dialog.done).toEqual({ decision: { behavior: 'allow' } })
  expect(dialog.below.calls()).toBe(0)
  await flush()
  expect(sentTo(fake, 'POST', receiptPath('toolu_1'))).toHaveLength(1)

  // The tool then runs; its end posts nothing more.
  await finish(call)
  expect(sentTo(fake, 'POST', closedPath('toolu_1'))).toEqual([])
})

test('allowAlwaysPassesUpdatedPermissionsThrough', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_1', command: 'ls' })
  await flush()

  const dialog = requestPermission(fake, {
    tool_name: 'Bash',
    tool_input: { command: 'ls' },
    permission_suggestions: [{ ...SESSION_RULE[0], destination: 'localSettings' }],
  })
  await flush()
  expect((sentTo(fake, 'POST', OPEN)[0]?.body as { suggestions: unknown }).suggestions).toEqual([
    { ...SESSION_RULE[0], destination: 'localSettings' },
  ])
  await fake.answer('GET', answerPath('toolu_1'), {
    status: 200,
    json: { state: 'decision', decision: { behavior: 'allow', updatedPermissions: SESSION_RULE } },
  })

  expect(await dialog.done).toEqual({ decision: { behavior: 'allow', updatedPermissions: SESSION_RULE } })
  await finish(call)
})

test('denyCarriesMessageAndNoInterrupt', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_1', command: 'rm -rf build' })
  await flush()

  const dialog = requestPermission(fake, { tool_name: 'Bash', tool_input: { command: 'rm -rf build' } })
  // Even a decision that asked for it never interrupts the turn.
  await fake.answer('GET', answerPath('toolu_1'), {
    status: 200,
    json: { state: 'decision', decision: { behavior: 'deny', message: DENY_TEXT, interrupt: true } },
  })

  const result = (await dialog.done) as { decision: Record<string, unknown> }
  expect(result).toEqual({ decision: { behavior: 'deny', message: DENY_TEXT } })
  expect('interrupt' in result.decision).toBe(false)
  await flush()
  expect(sentTo(fake, 'POST', receiptPath('toolu_1'))).toHaveLength(1)
  await finish(call, { deny: DENY_TEXT })
})

test('abortPostsClosedAndPassesOn', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_1', command: 'ls' })
  await flush()

  const dialog = requestPermission(fake, { tool_name: 'Bash', tool_input: { command: 'ls' } })
  await flush()
  expect(fake.heldCount('GET', answerPath('toolu_1'))).toBe(1)

  // No or Escape in the terminal abandons the hook's dispatch.
  dialog.below.abort()

  expect(await dialog.done).toEqual(PASSED)
  expect(dialog.below.calls()).toBe(1)
  await flush()
  expect(sentTo(fake, 'POST', closedPath('toolu_1')).map(request => request.body)).toEqual([{ by: 'terminal' }])
  expect(sentTo(fake, 'POST', receiptPath('toolu_1'))).toEqual([])

  // The refused tool's end posts no second close.
  await finish(call, { deny: 'refused' })
  expect(sentTo(fake, 'POST', closedPath('toolu_1'))).toHaveLength(1)
})

test('disabledOpenPassesOn', async () => {
  const fake = fakeChannel()
  fake.replies.set(`POST ${OPEN}`, { status: 409, json: { error: 'disabled' } })
  const call = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_1', command: 'ls' })
  await flush()

  const dialog = requestPermission(fake, { tool_name: 'Bash', tool_input: { command: 'ls' } })

  expect(await dialog.done).toEqual(PASSED)
  expect(dialog.below.calls()).toBe(1)
  expect(sentTo(fake, 'GET', answerPath('toolu_1'))).toEqual([])
  await finish(call)
  expect(fake.sent.filter(request => request.path !== OPEN)).toEqual([])

  // A daemon that cannot be reached passes the dialog on the same way.
  fake.replies.set(`POST ${OPEN}`, 'fail')
  const unreachable = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_2', command: 'pwd' })
  await flush()
  const dialog2 = requestPermission(fake, { tool_name: 'Bash', tool_input: { command: 'pwd' } })
  expect(await dialog2.done).toEqual(PASSED)
  await finish(unreachable)
  expect(fake.sent.filter(request => request.path !== OPEN)).toEqual([])
})

const QUESTIONS = [
  {
    question: 'Which database?',
    header: 'Database',
    multiSelect: false,
    options: [
      { label: 'SQLite', description: 'One file' },
      { label: 'Postgres', description: 'A server' },
    ],
  },
]

test('questionAnsweredFromTBDReturnsQuestionsAndAnswers', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'AskUserQuestion', tool_use_id: 'toolu_q', questions: QUESTIONS })
  await flush()

  // The dialog opened in the terminal and its card in TBD.
  expect(call.tool.calls()).toBe(1)
  expect(sentTo(fake, 'POST', OPEN).map(request => request.body)).toEqual([
    { toolUseID: 'toolu_q', sessionID: SESSION_ID, toolName: 'AskUserQuestion', toolInput: { questions: QUESTIONS }, suggestions: null },
  ])
  const answers = { 'Which database?': 'SQLite' }
  await fake.answer('GET', answerPath('toolu_q'), {
    status: 200,
    json: { state: 'decision', decision: { behavior: 'allow', updatedInput: { questions: QUESTIONS, answers } } },
  })

  expect(await call.done).toEqual({ result: { questions: QUESTIONS, answers } })
  await flush()
  expect(sentTo(fake, 'POST', receiptPath('toolu_q'))).toHaveLength(1)

  // The dialog the answer closed settles later; nothing more is posted.
  call.tool.settle(TOOL_RESULT)
  await flush()
  expect(sentTo(fake, 'POST', closedPath('toolu_q'))).toEqual([])

  // A question never goes through the permission hook.
  const dialog = requestPermission(fake, { tool_name: 'AskUserQuestion', tool_input: { questions: QUESTIONS } })
  expect(await dialog.done).toEqual(PASSED)
  expect(sentTo(fake, 'POST', OPEN)).toHaveLength(1)
})

test('questionAnsweredInTerminalPostsClosed', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'AskUserQuestion', tool_use_id: 'toolu_q', questions: QUESTIONS })
  await flush()
  expect(fake.heldCount('GET', answerPath('toolu_q'))).toBe(1)

  const answeredHere = { result: { questions: QUESTIONS, answers: { 'Which database?': 'Postgres' } } }
  call.tool.settle(answeredHere)

  expect(await call.done).toEqual(answeredHere)
  await flush()
  expect(sentTo(fake, 'POST', closedPath('toolu_q')).map(request => request.body)).toEqual([{ by: 'terminal' }])
  expect(sentTo(fake, 'POST', receiptPath('toolu_q'))).toEqual([])

  // The close resolves the daemon's prompt; the wait still held ends there.
  await fake.answer('GET', answerPath('toolu_q'), { status: 200, json: { state: 'resolved' } })
  expect(fake.heldCount('GET', answerPath('toolu_q'))).toBe(0)
})

test('repostAfterReconnect', async () => {
  const fake = fakeChannel()
  const call = startCall(fake, { tool: 'Bash', tool_use_id: 'toolu_1', command: 'ls' })
  await flush()
  const dialog = requestPermission(fake, { tool_name: 'Bash', tool_input: { command: 'ls' } })
  await flush()
  const opened = sentTo(fake, 'POST', OPEN)[0]?.body

  // The daemon goes away and comes back: a poll fails, the next succeeds.
  startPolling(fake.engine, CHANNEL)
  await fake.advance(0)
  await fake.answer('GET', '/v1/poll?after=0', { status: 200, json: { items: [] } })
  expect(sentTo(fake, 'POST', OPEN)).toHaveLength(1)
  await fake.answer('GET', '/v1/poll?after=0', 'fail')
  await fake.advance(1_000)
  await fake.answer('GET', '/v1/poll?after=0', { status: 200, json: { items: [] } })

  expect(sentTo(fake, 'POST', OPEN).map(request => request.body)).toEqual([opened, opened])

  // A dialog no longer open is not posted again.
  await fake.answer('GET', answerPath('toolu_1'), { status: 200, json: { state: 'resolved' } })
  expect(await dialog.done).toEqual(PASSED)
  await finish(call)
  await fake.answer('GET', '/v1/poll?after=0', 'fail')
  await fake.advance(1_000)
  await fake.answer('GET', '/v1/poll?after=0', { status: 200, json: { items: [] } })
  expect(sentTo(fake, 'POST', OPEN)).toHaveLength(2)
  // A prompt the daemon resolved gets no close from the mod.
  expect(sentTo(fake, 'POST', closedPath('toolu_1'))).toEqual([])
})

test('subagentAgentIdSeparatesPairing', async () => {
  const fake = fakeChannel()
  // The main loop's call is older and has the same arguments.
  const main = startCall(fake, { tool: 'Read', tool_use_id: 'toolu_main', file_path: '/x' })
  const sub = startCall(fake, { tool: 'Read', tool_use_id: 'toolu_sub', file_path: '/x', agentId: 'agent-1' })
  await flush()

  const forSub = requestPermission(fake, { tool_name: 'Read', tool_input: { file_path: '/x' }, agent_id: 'agent-1' })
  await flush()
  const forMain = requestPermission(fake, { tool_name: 'Read', tool_input: { file_path: '/x' } })
  await flush()
  expect(openedIds(fake)).toEqual(['toolu_sub', 'toolu_main'])

  // Another subagent's dialog matches neither.
  const other = requestPermission(fake, { tool_name: 'Read', tool_input: { file_path: '/x' }, agent_id: 'agent-2' })
  expect(await other.done).toEqual(PASSED)

  await fake.answer('GET', answerPath('toolu_sub'), { status: 200, json: { state: 'decision', decision: { behavior: 'allow' } } })
  await fake.answer('GET', answerPath('toolu_main'), { status: 200, json: { state: 'resolved' } })
  expect(await forSub.done).toEqual({ decision: { behavior: 'allow' } })
  expect(await forMain.done).toEqual(PASSED)
  await finish(main)
  await finish(sub)
})
