// A stand-in `$` for the channel tests: a daemon on mod.sock the test answers
// request by request, a clock that moves only when the test moves it, and the
// environment and session the channel reads.
//
// The tests call the feature's functions directly, so they pass this
// stand-in, which answers `$` calls with the plugin-side signatures
// (`$.http.fetch(url, init)`), where the test kit's own `$` takes each event's
// input whole.
import type { EngineInterface } from 'claude-code'
import { expect } from 'claude-code/testing'

import type { ChannelEnv } from '../hooks/shared/channel.ts'

export const SESSION_ID = 'sess-1'
export const CHANNEL: ChannelEnv = {
  socket: '/tbd/mod.sock',
  token: 'token-1',
  terminalId: '0F8D3A52-6B1C-4E7A-9D2F-3C4B5A6E7F80',
  incarnationId: '5B0C2D9E-4F1A-4C55-9E2B-7A1D3C8F6E01',
}
export const CHANNEL_VARIABLES: Record<string, string> = {
  TBD_MOD_SOCKET: CHANNEL.socket,
  TBD_MOD_TOKEN: CHANNEL.token,
  TBD_TERMINAL_ID: CHANNEL.terminalId,
  TBD_TERMINAL_INCARNATION_ID: CHANNEL.incarnationId,
}

/** What the daemon answers: a status and a JSON body, or a request that fails to connect. */
export type Reply = { status: number; json?: unknown } | 'fail'

/** One request the mod sent. */
export type Sent = {
  method: string
  /** The URL's path and query, without `http://tbd`. */
  path: string
  url: string
  headers: Record<string, string>
  socketPath: string | undefined
  /** The body parsed as JSON; undefined for none. */
  body: unknown
}

type Held = Sent & { reply: (reply: Reply) => void }
type Wait = { due: number; run: () => void; fail: (error: Error) => void; isDone: boolean }

export type FakeChannel = {
  engine: EngineInterface
  /** Every request, in the order sent. */
  sent: Sent[]
  logs: string[]
  /** The length of every `$.clock.sleep`, in the order asked. */
  sleeps: number[]
  /**
   * How the daemon answers a request at once, by `METHOD path`; one listed
   * nowhere is answered 200 `{}` when it is a POST and held when it is a GET.
   */
  replies: Map<string, Reply>
  /** Answers the oldest held request to `METHOD path`; fails the test when none is held. */
  answer: (method: string, path: string, reply: Reply) => Promise<void>
  /** How many requests to `METHOD path` are held unanswered. */
  heldCount: (method: string, path: string) => number
  /** Moves the clock on, running each wait due on the way in order. */
  advance: (ms: number) => Promise<void>
}

/** Lets every promise chain already under way run out. */
export async function flush(): Promise<void> {
  for (let turn = 0; turn < 200; turn += 1) {
    await Promise.resolve()
  }
}

export function fakeChannel(variables: Record<string, string> = CHANNEL_VARIABLES): FakeChannel {
  const sent: Sent[] = []
  const logs: string[] = []
  const sleeps: number[] = []
  const replies = new Map<string, Reply>()
  const held: Held[] = []
  const waits: Wait[] = []
  let now = 0

  function respond(reply: Reply, resolve: (value: unknown) => void, reject: (error: Error) => void): void {
    if (reply === 'fail') {
      reject(new Error('connect ECONNREFUSED'))
      return
    }
    resolve({
      status: reply.status,
      ok: reply.status >= 200 && reply.status < 300,
      headers: {},
      text: reply.json === undefined ? '' : JSON.stringify(reply.json),
    })
  }

  function addWait(ms: number, run: () => void, fail: (error: Error) => void): Wait {
    const wait: Wait = { due: now + ms, run, fail, isDone: false }
    waits.push(wait)
    return wait
  }

  const engine = {
    env: { get: async (name: string) => variables[name] },
    session: { id: async () => SESSION_ID },
    ui: {
      log: (text: string) => {
        logs.push(text)
      },
    },
    clock: {
      now: async () => now,
      sleep: (ms: number, options?: { signal?: AbortSignal }) =>
        new Promise<void>((resolve, reject) => {
          sleeps.push(ms)
          const wait = addWait(ms, resolve, reject)
          options?.signal?.addEventListener(
            'abort',
            () => {
              if (!wait.isDone) {
                wait.isDone = true
                reject(new Error('aborted'))
              }
            },
            { once: true },
          )
        }),
      after: (ms: number, run: () => void) => {
        const wait = addWait(ms, run, () => {})
        return {
          cancel: () => {
            wait.isDone = true
          },
        }
      },
    },
    http: {
      fetch: (url: string, init?: { method?: string; headers?: Record<string, string>; body?: string; socketPath?: string }) =>
        new Promise((resolve, reject) => {
          const method = init?.method ?? 'GET'
          const path = url.replace(/^http:\/\/tbd/, '')
          const request: Sent = {
            method,
            path,
            url,
            headers: { ...(init?.headers ?? {}) },
            socketPath: init?.socketPath,
            body: init?.body === undefined ? undefined : JSON.parse(init.body),
          }
          sent.push(request)
          const known = replies.get(`${method} ${path}`)
          if (known !== undefined) {
            respond(known, resolve, reject)
          } else if (method === 'POST') {
            respond({ status: 200, json: {} }, resolve, reject)
          } else {
            held.push({ ...request, reply: reply => respond(reply, resolve, reject) })
          }
        }),
    },
  } as unknown as EngineInterface

  return {
    engine,
    sent,
    logs,
    sleeps,
    replies,
    answer: async (method, path, reply) => {
      await flush()
      const index = held.findIndex(request => request.method === method && request.path === path)
      expect(index).not.toBe(-1)
      const [request] = held.splice(index, 1)
      request?.reply(reply)
      await flush()
    },
    heldCount: (method, path) => held.filter(request => request.method === method && request.path === path).length,
    advance: async ms => {
      const target = now + ms
      await flush()
      for (;;) {
        const due = waits
          .filter(wait => !wait.isDone && wait.due <= target)
          .sort((a, b) => a.due - b.due)[0]
        if (due === undefined) {
          break
        }
        now = Math.max(now, due.due)
        due.isDone = true
        due.run()
        await flush()
      }
      now = target
      await flush()
    },
  }
}

/** A `next` whose answer the test gives, with the signal the engine would abort. */
export type Below<T> = {
  next: T
  calls: () => number
  settle: (result: unknown) => void
  abort: () => void
}

export function below<T>(answer?: unknown): Below<T> {
  const controller = new AbortController()
  let calls = 0
  let settle: (result: unknown) => void = () => {}
  const settled = new Promise<unknown>(resolve => {
    settle = resolve
  })
  if (answer !== undefined) {
    settle(answer)
  }
  const next = Object.assign(
    async () => {
      calls += 1
      return settled
    },
    { signal: controller.signal },
  )
  return {
    next: next as unknown as T,
    calls: () => calls,
    settle: result => settle(result),
    abort: () => controller.abort(),
  }
}

/** The requests sent to `METHOD path`. */
export function sentTo(fake: FakeChannel, method: string, path: string): Sent[] {
  return fake.sent.filter(request => request.method === method && request.path === path)
}
