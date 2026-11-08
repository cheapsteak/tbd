/**
 * The app protocol client (spec section 4.4). `AppClient` is the one owner of the app's
 * requests to the laptop and of the events the laptop sends back. It mints request IDs, keeps
 * each body within one frame, keeps at most 32 requests in flight, turns each reply into the
 * request's result or an `AppError`, resends what a dropped channel left unanswered, and
 * numbers the event stream.
 *
 * It speaks to the loader through two seams, so tests can drive it without a port: `post`
 * sends one app body, and `handle` takes each message the loader sends the app.
 *
 * **Across a dropped channel.** The daemon finishes every request it started, whatever
 * happens to the connection, and sends the reply through whatever connection the phone has
 * then; a reply that finds the phone away is lost. So the client keeps every unanswered
 * request through a drop. When the channel comes back up it does three things, in order:
 * 1. It rejects every unanswered state request (`STATE_METHODS`) with `superseded`, because
 *    its caller sends fresh ones from `onUp`.
 * 2. It calls `onUp`. Whatever `onUp` requests goes out first: `sessions.subscribe`, then a
 *    `transcript.open` with `resume`.
 * 3. It posts every other unanswered request again, in the order each was first sent, with
 *    the very body it first posted, then drains the queue. An acting request posted on an
 *    earlier connection waits, though, until this connection's `sessions.subscribe` reply
 *    shows the daemon still remembers it (below), and a queued action waits behind it, so a
 *    session gets its actions in the order they were made.
 *
 * A resend is safe because of what the daemon does with a request ID (`PhoneAppService.swift`):
 * - **A resend of a request still running** starts nothing, and the running request's one
 *   reply comes to the new connection.
 * - **A resend of an acting request** (`ACTING_METHODS`) that finished gets the reply the
 *   daemon remembered and acts no more. Otherwise a resend would act again: a message typed
 *   twice, a second worktree. The daemon remembers a reply for 600 s, and only in memory, so
 *   two things can make it forget:
 *   - **Time.** An acting request is resent only within `RESEND_HORIZON_MS` (540 s) of its
 *     first send, and is otherwise rejected with `not_confirmed`.
 *   - **A daemon restart.** The loader keeps the same frame across one, so the client cannot
 *     see it directly. It sees the event stream, though: the daemon makes a new stream ID for
 *     each phone it starts keeping state for (`PhoneEventStream.swift`). So an acting resend
 *     waits for the subscribe reply, and goes out only when that reply replays the stream or
 *     names the stream the client already had. A new stream, or no stream known before,
 *     rejects it with `not_confirmed`. A new stream can also mean only that the daemon's
 *     120 s grace for an absent phone ran out while it still remembered the request; refusing
 *     then is the cautious reading.
 * - **A resend of a read** that finished runs again, which is harmless at any age, so reads
 *   go out at once.
 * - **An ID reused for another method** is answered `bad_request`. So a resend posts the very
 *   body first posted, and a new request always gets a new ID.
 *
 * The daemon also caps a phone at 32 running requests, counted across connections. The client
 * never has more than 32 posted and unanswered on one channel, reposts included: `onUp`'s
 * requests take slots first, then the reposts, then the queue.
 *
 * **Events.** Every event carries a `seq` on the phone's one stream. The daemon sends none on
 * a connection before that connection's `sessions.subscribe` reply, so the client drops any
 * that reaches it between a channel up and that reply. After it, an event at or below the last
 * `seq` taken is a repeat and is dropped. The subscribe reply sets the numbering: a snapshot
 * starts a stream whose later events are above the reply's `seq`, and a replay keeps the
 * numbering as it was, because the missed events follow it with `seq` at or below the reply's.
 */

import type { LoaderMessage } from '../host.ts';
import { fitsFrame, MAX_IN_FLIGHT, RESEND_HORIZON_MS } from '../limits.ts';
import { decodeEnvelope, decodeEventData, decodeResult, isErrorCode, requestBody } from '../protocol/wire.ts';
import type { Envelope } from '../protocol/wire.ts';
import type { AppEvent, ErrorCode, Method, ParamsOf, ResultOf, SessionsSubscribeResult } from '../protocol/types.ts';

/**
 * The methods that act on a session or create something. The daemon keeps their replies in its
 * request memory (`PhoneAppService.remembersReplies(of:)`), so a resend of one gets the first
 * run's reply and acts no more, but only while the daemon still remembers it.
 *
 * **Never retry a failed action automatically under a new ID.** Several failures can mean the
 * action happened all the same: `not_confirmed`, `bad_reply`, `internal`, and a `too_large`
 * that came from the loader (`sendFailed: tooLarge`) rather than from `request`'s own check. A
 * new ID is a new action to the daemon, so an automatic retry can act twice. Show the error
 * and leave the choice to the user.
 */
export const ACTING_METHODS: ReadonlySet<Method> = new Set<Method>([
  'message.send',
  'prompt.answer',
  'session.switchProfile',
  'session.fork',
  'session.setModel',
  'worktree.create',
  'remote.create',
]);

/**
 * The methods that set up or tear down what the laptop sends the phone. They are never resent:
 * after a drop, the caller's `onUp` sends fresh ones for the state it wants now. That includes
 * a `transcript.close`: one superseded at a channel up is gone, so when no transcript is open,
 * the transcript actions' `onUp` work (`resumeTranscriptOnUp`) sends a fresh close.
 */
export const STATE_METHODS: ReadonlySet<Method> = new Set<Method>(['sessions.subscribe', 'transcript.open', 'transcript.close']);

/** The codes the client itself rejects with, beside the daemon's own. */
export type LocalErrorCode = 'too_large' | 'not_confirmed' | 'bad_reply' | 'superseded';

/** The daemon's words for a message over its limit (`PhoneAppService.messageTooLongReason`). */
export const TOO_LONG_TEXT = 'That message is too long to send from a phone.';

/** A reply whose result, or whose envelope, this build cannot read. */
export const BAD_REPLY_TEXT = 'The laptop sent a reply this app cannot read.';

/**
 * Params that do not fit their method's wire shape, such as a number that is not an integer.
 * The daemon's words for the same fault (`PhoneAppService.perform`).
 */
export const BAD_PARAMS_TEXT = "The request's params are not valid.";

/** An acting request the channel dropped before the laptop answered, too old to send again. */
export const NOT_CONFIRMED_TEXT =
  'The laptop did not confirm this before the connection dropped. Check the session before you try again.';

/**
 * A state request a channel up replaced. Its caller sends a fresh one from `onUp`, so this is
 * for logs and tests, never for the screen.
 */
export const SUPERSEDED_TEXT = 'The connection came back, and a fresh request replaces this one.';

/**
 * A request that failed: with a code from the daemon's closed list, or one of the client's own.
 * For an acting request, `not_confirmed`, `bad_reply`, `internal` and a loader's `too_large`
 * can each mean the action happened; see `ACTING_METHODS`.
 */
export class AppError extends Error {
  readonly code: ErrorCode | LocalErrorCode;

  constructor(code: ErrorCode | LocalErrorCode, message: string) {
    super(message);
    this.name = 'AppError';
    this.code = code;
  }
}

export interface ClientOptions {
  /** Sends one app body to the laptop: `HostLink.postApp` in the app. */
  post(body: Record<string, unknown>): void;
  /** One event from the laptop, decoded, in order, each `seq` once. */
  onEvent(event: AppEvent): void;
  /**
   * The channel to the laptop came up. Called on every change to up, before anything held is
   * posted again, so the requests it makes go out first.
   */
  onUp(): void;
  /** The channel to the laptop went down. */
  onDown(): void;
  /** The time in milliseconds. Defaults to `elapsedClock()`, which never undercounts. */
  now?: () => number;
  /** A new request ID, unique for good. Defaults to `newRequestID`. */
  newID?: () => string;
}

/**
 * A clock, in milliseconds, whose elapsed time is the larger of what wall time and the
 * monotonic clock say has passed since it was made. The client compares an action's age with
 * the daemon's 600 s request memory, so the clock must never undercount: an undercount resends
 * an action the daemon has forgotten, and the action happens twice.
 * - **Wall time** (`Date.now`) keeps running while iOS suspends the page, when the monotonic
 *   clock may stop. The daemon's memory runs on in the meantime.
 * - **The monotonic clock** (`performance.now`) keeps counting when the wall clock is stepped
 *   backward.
 */
export function elapsedClock(): () => number {
  const wall0 = Date.now();
  const mono0 = performance.now();
  return () => wall0 + Math.max(Date.now() - wall0, performance.now() - mono0);
}

/**
 * A random version 4 UUID in lower case, in the 8-4-4-4-12 form: 36 bytes, well under the
 * daemon's 128-byte limit (`PhoneAppConstants.requestIDMaxBytes`). It uses
 * `crypto.getRandomValues`, which needs no secure context, unlike `crypto.randomUUID`.
 */
export function newRequestID(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/**
 * Where an unanswered request is:
 * - `queued`: never posted, waiting in FIFO order for the channel and a slot;
 * - `first`: never posted, made by `onUp`, so it goes ahead of everything else;
 * - `posted`: posted on the current channel, holding one of the 32 slots;
 * - `held`: posted before, and owed a repost on the next channel up, because the channel went
 *   down or the loader reported it unsent (`sendFailed: offline`);
 * - `unconfirmed`: an acting request owed a repost since the latest channel up, waiting for
 *   that connection's subscribe reply to show the daemon still remembers it;
 * - `resend`: owed a repost since the latest channel up, waiting for a slot. The list is kept
 *   in first-send order.
 */
type Lane = 'queued' | 'first' | 'posted' | 'held' | 'unconfirmed' | 'resend';

interface Pending {
  readonly id: string;
  readonly method: Method;
  /** The body as first built. Every send posts this same object. */
  readonly body: Record<string, unknown>;
  readonly resolve: (result: unknown) => void;
  readonly reject: (error: AppError) => void;
  lane: Lane;
  /** When it was first posted, by `now`. Null while it has never been posted. */
  firstSentAt: number | null;
  /** Its place in first-send order, which reposts keep. */
  sendOrder: number;
  /** How many times it was posted. */
  posts: number;
}

function byFirstSend(a: Pending, b: Pending): number {
  return a.sendOrder - b.sendOrder;
}

type Reply = Extract<Envelope, { kind: 'reply' }>;
type EventEnvelope = Extract<Envelope, { kind: 'event' }>;

export class AppClient {
  readonly #post: (body: Record<string, unknown>) => void;
  readonly #onEvent: (event: AppEvent) => void;
  readonly #onUp: () => void;
  readonly #onDown: () => void;
  readonly #now: () => number;
  readonly #newID: () => string;

  #up = false;
  #stream: string | null = null;
  #lastSeq: number | null = null;
  /** True from each channel up until that connection's subscribe reply decodes. */
  #awaitingSubscribe = true;
  /** True while `onUp` runs, so only its own requests are posted then. */
  #inOnUp = false;
  #sends = 0;

  /** Every unanswered request, by ID, whatever its lane. */
  readonly #pending = new Map<string, Pending>();
  readonly #posted = new Set<Pending>();
  #first: Pending[] = [];
  #unconfirmed: Pending[] = [];
  #resends: Pending[] = [];
  #queue: Pending[] = [];
  #held: Pending[] = [];

  constructor(options: ClientOptions) {
    this.#post = options.post;
    this.#onEvent = options.onEvent;
    this.#onUp = options.onUp;
    this.#onDown = options.onDown;
    this.#now = options.now ?? elapsedClock();
    this.#newID = options.newID ?? newRequestID;
  }

  /** Whether the channel to the laptop is up. */
  get up(): boolean {
    return this.#up;
  }

  /**
   * The event stream the phone follows: the stream of the last `sessions.subscribe` snapshot.
   * A caller passes it, with `lastSeq`, to the next subscribe.
   */
  get stream(): string | null {
    return this.#stream;
  }

  /** The `seq` of the last event the phone took on that stream, or of the snapshot that started it. */
  get lastSeq(): number | null {
    return this.#lastSeq;
  }

  /** One message from the loader. The env message is the app shell's business, not this one's. */
  handle(message: LoaderMessage): void {
    switch (message.t) {
      case 'app':
        this.#receive(message.body);
        break;
      case 'channel':
        if (message.up) this.#channelUp();
        else this.#channelDown();
        break;
      case 'sendFailed':
        if (message.reason === 'tooLarge') this.#failPosted();
        else this.#holdPosted();
        break;
      case 'env':
        break;
    }
  }

  /**
   * Sends one request and resolves with its decoded result. It rejects with `AppError` only:
   * - the daemon's error;
   * - `too_large` at once for a body over one frame, with nothing posted;
   * - `bad_reply` for a reply that does not decode;
   * - `superseded` for a state request still unanswered when the channel comes back up;
   * - `not_confirmed` for an acting request still unanswered when the channel comes back up,
   *   when it is more than 540 s past its first send or the new connection's subscribe reply
   *   names a new stream, and for a repost of one that the daemon answers `refused`.
   *
   * It has no timeout: the daemon answers every request it runs. The request goes out at once
   * when the channel is up and fewer than 32 requests are posted and unanswered, and, for an
   * action, when no earlier action waits to be sent again. Otherwise it waits, in the order it
   * was made.
   */
  request<M extends Method>(method: M, params: ParamsOf<M>): Promise<ResultOf<M>> {
    const id = this.#newID();
    // A reused ID would be read by the daemon as a resend: another request's reply, or nothing.
    if (this.#pending.has(id)) throw new Error(`AppClient: request ID ${id} is already in use`);
    let body: Record<string, unknown>;
    try {
      body = requestBody(id, method, params);
    } catch {
      return Promise.reject(new AppError('bad_request', BAD_PARAMS_TEXT));
    }
    // The loader's refusal of an oversized body names no request, so it is caught here, before
    // the body is queued, while the caller can still be told which request it was.
    if (!fitsFrame(body)) return Promise.reject(new AppError('too_large', TOO_LONG_TEXT));
    return new Promise<ResultOf<M>>((resolve, reject) => {
      const lane: Lane = this.#inOnUp ? 'first' : 'queued';
      const pending: Pending = {
        id, method, body, resolve: resolve as (result: unknown) => void, reject, lane, firstSentAt: null, sendOrder: 0, posts: 0,
      };
      this.#pending.set(id, pending);
      if (lane === 'first') this.#first.push(pending);
      else this.#queue.push(pending);
      this.#pump();
    });
  }

  // MARK: - The channel

  /** A change to up: the three steps in this file's header, then the queue. */
  #channelUp(): void {
    if (this.#up) return;
    this.#up = true;
    this.#awaitingSubscribe = true;
    for (const pending of [...this.#pending.values()]) {
      if (STATE_METHODS.has(pending.method)) this.#fail(pending, 'superseded', SUPERSEDED_TEXT);
    }
    this.#inOnUp = true;
    try {
      this.#onUp();
    } finally {
      this.#inOnUp = false;
      const reads: Pending[] = [];
      for (const pending of this.#held) {
        if (ACTING_METHODS.has(pending.method)) {
          pending.lane = 'unconfirmed';
          this.#unconfirmed.push(pending);
        } else {
          reads.push(pending);
        }
      }
      this.#held = [];
      this.#addResends(reads);
      this.#rejectTooOld([...this.#unconfirmed, ...this.#resends]);
      this.#pump();
    }
  }

  /** A change to down. Nothing is failed: every unanswered request waits for the next up. */
  #channelDown(): void {
    if (!this.#up) return;
    this.#up = false;
    for (const pending of this.#posted) this.#hold(pending);
    this.#posted.clear();
    // A released resend still waiting for a slot is held again, so the next connection's
    // subscribe reply must confirm it afresh.
    for (const pending of this.#resends) this.#hold(pending);
    this.#resends = [];
    for (const pending of this.#unconfirmed) this.#hold(pending);
    this.#unconfirmed = [];
    // `onUp` requests never posted are queued requests now, still ahead of the rest.
    for (const pending of this.#first) pending.lane = 'queued';
    this.#queue = [...this.#first, ...this.#queue];
    this.#first = [];
    this.#onDown();
  }

  /**
   * `sendFailed: tooLarge`. The loader's message names no request, so every posted, unanswered
   * request is failed: the one it refused is among them, and leaving it would wait forever.
   * `request` checks the same limit the loader does, so this should never happen.
   */
  #failPosted(): void {
    for (const pending of [...this.#posted]) this.#fail(pending, 'too_large', TOO_LONG_TEXT);
    this.#pump();
  }

  /**
   * `sendFailed: offline`. The loader names no request, so every posted, unanswered request is
   * taken as unsent and held for the next channel up. Reposting one sent after all is safe:
   * the daemon reads it as a resend.
   */
  #holdPosted(): void {
    for (const pending of this.#posted) this.#hold(pending);
    this.#posted.clear();
  }

  #hold(pending: Pending): void {
    pending.lane = 'held';
    this.#held.push(pending);
  }

  /**
   * Adds reposts to the resend lane, kept in first-send order: the lanes they come from do not
   * keep it, since a request first sent on one connection can be held after one sent earlier.
   */
  #addResends(list: Pending[]): void {
    for (const pending of list) pending.lane = 'resend';
    this.#resends = [...this.#resends, ...list].sort(byFirstSend);
  }

  /**
   * Rejects each of `list` that is too old to resend, at once rather than when a slot frees.
   * `#pump` checks again before each repost.
   */
  #rejectTooOld(list: Pending[]): void {
    for (const pending of list) {
      if (this.#tooOldToResend(pending)) this.#fail(pending, 'not_confirmed', NOT_CONFIRMED_TEXT);
    }
  }

  // MARK: - Sending

  /**
   * Posts what waits while the channel is up and a slot is free: `onUp`'s requests, then the
   * reposts in first-send order, then the queue. While `onUp` runs, only its own go.
   */
  #pump(): void {
    while (this.#up && this.#posted.size < MAX_IN_FLIGHT) {
      const next = this.#first.shift() ?? (this.#inOnUp ? undefined : this.#resends.shift() ?? this.#nextQueued());
      if (next === undefined) return;
      if (this.#tooOldToResend(next)) {
        // Shifted out of its lane already, so only its entry is left to remove.
        this.#pending.delete(next.id);
        next.reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
        continue;
      }
      this.#send(next);
    }
  }

  /**
   * The queued request to post next, taken out of the queue. While an earlier action still
   * waits to be sent again, held or unconfirmed, a queued action waits behind it, so a session
   * never gets a message typed later before one typed earlier. Reads go meanwhile, in order.
   * Once the held actions are resent or rejected, the queue drains in order.
   */
  #nextQueued(): Pending | undefined {
    const actionsWait = this.#unconfirmed.length > 0 || this.#held.some((p) => ACTING_METHODS.has(p.method));
    if (!actionsWait) return this.#queue.shift();
    const index = this.#queue.findIndex((p) => !ACTING_METHODS.has(p.method));
    return index < 0 ? undefined : this.#queue.splice(index, 1)[0];
  }

  /**
   * Whether `pending` is an acting request first sent more than 540 s ago, which the daemon may
   * have forgotten by now. A request never sent is never too old.
   */
  #tooOldToResend(pending: Pending): boolean {
    return pending.firstSentAt !== null
      && ACTING_METHODS.has(pending.method)
      && this.#now() - pending.firstSentAt > RESEND_HORIZON_MS;
  }

  #send(pending: Pending): void {
    if (pending.firstSentAt === null) {
      pending.firstSentAt = this.#now();
      pending.sendOrder = ++this.#sends;
    }
    pending.posts++;
    pending.lane = 'posted';
    this.#posted.add(pending);
    this.#post(pending.body);
  }

  /** Takes an answered or failed request out of every lane, so a later reply to it is ignored. */
  #settle(pending: Pending): void {
    this.#pending.delete(pending.id);
    switch (pending.lane) {
      case 'posted':
        this.#posted.delete(pending);
        break;
      case 'queued':
        this.#queue = this.#queue.filter((p) => p !== pending);
        break;
      case 'first':
        this.#first = this.#first.filter((p) => p !== pending);
        break;
      case 'held':
        this.#held = this.#held.filter((p) => p !== pending);
        break;
      case 'unconfirmed':
        this.#unconfirmed = this.#unconfirmed.filter((p) => p !== pending);
        break;
      case 'resend':
        this.#resends = this.#resends.filter((p) => p !== pending);
        break;
    }
  }

  #fail(pending: Pending, code: ErrorCode | LocalErrorCode, message: string): void {
    this.#settle(pending);
    pending.reject(new AppError(code, message));
  }

  // MARK: - Receiving

  #receive(body: Record<string, unknown>): void {
    let envelope: Envelope;
    try {
      envelope = decodeEnvelope(body);
    } catch {
      this.#unreadableReply(body);
      return;
    }
    if (envelope.kind === 'reply') this.#reply(envelope);
    else this.#event(envelope);
  }

  /**
   * The request a reply names, if this client sent it and it is still unanswered, whichever
   * channel it was sent on. A reply that names anything else is ignored: an ID never seen, one
   * already answered or failed (`superseded` and `not_confirmed` included), and one still
   * queued, which the laptop has never been sent.
   */
  #sentRequest(requestID: string): Pending | undefined {
    const pending = this.#pending.get(requestID);
    return pending !== undefined && pending.firstSentAt !== null ? pending : undefined;
  }

  #reply(reply: Reply): void {
    const pending = this.#sentRequest(reply.requestID);
    if (pending === undefined) return;
    if (reply.error !== undefined) {
      const { code, message } = reply.error;
      if (code === 'refused' && ACTING_METHODS.has(pending.method) && pending.posts > 1) {
        // The daemon checks its cap on running requests before its request memory, so a
        // repost of an action that already ran can be refused as "too many in progress".
        // Shown as is, it invites the user to try again under a new ID, which would act twice.
        this.#fail(pending, 'not_confirmed', NOT_CONFIRMED_TEXT);
      } else {
        // A code outside the closed list is a reply this build cannot fully read. Its message
        // is the daemon's own words for the phone, so it is kept.
        this.#fail(pending, isErrorCode(code) ? code : 'bad_reply', message);
      }
      this.#pump();
      return;
    }
    let result: unknown;
    try {
      result = decodeResult(pending.method, reply.result);
    } catch {
      this.#fail(pending, 'bad_reply', BAD_REPLY_TEXT);
      this.#pump();
      return;
    }
    // Before the promise resolves, so the numbering holds for the very next port message.
    if (pending.method === 'sessions.subscribe') this.#subscribed(result as SessionsSubscribeResult);
    this.#settle(pending);
    pending.resolve(result);
    this.#pump();
  }

  /**
   * A subscribe reply that decoded. A snapshot starts the numbering at its `seq`; a replay
   * keeps it, because the events it replays follow with `seq` at or below its own.
   *
   * It also settles the acting reposts waiting for it. A replay, or a snapshot of the stream
   * the client already had, shows the daemon is the one that numbered that stream, so it still
   * remembers their IDs: they go out, still held to the horizon. Any other stream may come from
   * a daemon that restarted and forgot them, so each is rejected `not_confirmed`.
   */
  #subscribed(result: SessionsSubscribeResult): void {
    const before = this.#stream;
    if (!result.replayed) {
      this.#stream = result.stream;
      this.#lastSeq = result.seq;
    }
    this.#awaitingSubscribe = false;
    const waiting = this.#unconfirmed;
    if (result.replayed || (before !== null && result.stream === before)) {
      this.#unconfirmed = [];
      this.#addResends(waiting);
      this.#rejectTooOld(waiting);
    } else {
      for (const pending of [...waiting]) this.#fail(pending, 'not_confirmed', NOT_CONFIRMED_TEXT);
    }
  }

  /**
   * A body whose envelope does not decode. When it is a reply that names a request this
   * client sent, that request fails with `bad_reply`, so it does not wait forever. Anything
   * else is dropped.
   */
  #unreadableReply(body: Record<string, unknown>): void {
    const requestID = body.requestID;
    if (body.kind !== 'reply' || typeof requestID !== 'string') return;
    const pending = this.#sentRequest(requestID);
    if (pending === undefined) return;
    this.#fail(pending, 'bad_reply', BAD_REPLY_TEXT);
    this.#pump();
  }

  /**
   * One event: dropped before this connection's subscribe reply, and dropped as a repeat at or
   * below the last `seq` taken. Otherwise its `seq` is taken, and its data, decoded by its
   * name, handed on. An event whose data does not decode is taken and not handed on.
   */
  #event(event: EventEnvelope): void {
    if (this.#awaitingSubscribe) return;
    if (this.#lastSeq !== null && event.seq <= this.#lastSeq) return;
    this.#lastSeq = event.seq;
    let data: unknown;
    try {
      data = decodeEventData(event.event, event.data);
    } catch {
      return;
    }
    this.#onEvent({ event: event.event, seq: event.seq, data } as AppEvent);
  }
}
