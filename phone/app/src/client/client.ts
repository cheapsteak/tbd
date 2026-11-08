/**
 * The app protocol client (spec section 4.4). `AppClient` is the one owner of the app's
 * requests to the laptop and of the events the laptop sends back. It mints request IDs, keeps
 * each body within one frame, keeps at most 32 requests in flight, and turns each reply into
 * the request's result or an `AppError`.
 *
 * It speaks to the loader through two seams, so tests can drive it without a port: `post`
 * sends one app body, and `handle` takes each message the loader sends the app.
 */

import type { LoaderMessage } from '../host.ts';
import { fitsFrame, MAX_IN_FLIGHT } from '../limits.ts';
import { decodeEnvelope, decodeEventData, decodeResult, isErrorCode, requestBody } from '../protocol/wire.ts';
import type { Envelope } from '../protocol/wire.ts';
import type { AppEvent, ErrorCode, Method, ParamsOf, ResultOf } from '../protocol/types.ts';

/**
 * The methods that act on a session or create something. The daemon keeps their replies in its
 * request memory (`PhoneAppService.remembersReplies(of:)`), so a resend of one gets the first
 * run's reply and acts no more, but only while the daemon still remembers it.
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

/** The methods that set up or tear down what the laptop sends the phone. */
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

/** A request that failed: with a code from the daemon's closed list, or one of the client's own. */
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
  /** One event from the laptop, decoded. */
  onEvent(event: AppEvent): void;
  /** The channel to the laptop came up. */
  onUp(): void;
  /** The channel to the laptop went down. */
  onDown(): void;
  /**
   * The time in milliseconds. Defaults to `Date.now`, wall time, on purpose: the daemon's
   * request memory lasts 600 s of wall time, and wall time keeps running while iOS suspends the
   * page. A clock that stopped during a suspension would let the client resend an action the
   * daemon has already forgotten, and the action would happen twice.
   */
  now?: () => number;
  /** A new request ID, unique for good. Defaults to `newRequestID`. */
  newID?: () => string;
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
 * - `posted`: posted on the current channel, holding one of the 32 slots;
 * - `held`: posted, then reported unsent by the loader (`sendFailed: offline`).
 */
type Lane = 'queued' | 'posted' | 'held';

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

  /** Every unanswered request, by ID, whatever its lane. */
  readonly #pending = new Map<string, Pending>();
  readonly #posted = new Set<Pending>();
  #queue: Pending[] = [];
  #held: Pending[] = [];

  constructor(options: ClientOptions) {
    this.#post = options.post;
    this.#onEvent = options.onEvent;
    this.#onUp = options.onUp;
    this.#onDown = options.onDown;
    this.#now = options.now ?? Date.now;
    this.#newID = options.newID ?? newRequestID;
  }

  /** Whether the channel to the laptop is up. */
  get up(): boolean {
    return this.#up;
  }

  /** The event stream the phone follows, from the last `sessions.subscribe` snapshot. */
  get stream(): string | null {
    return this.#stream;
  }

  /** The `seq` of the last event the phone took on that stream. */
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
   * the daemon's error, or `too_large` at once for a body over one frame (nothing is posted),
   * or `bad_reply` for a result that does not decode. It has no timeout: the daemon answers
   * every request it runs.
   *
   * The request goes out at once when the channel is up and fewer than 32 requests are posted
   * and unanswered. Otherwise it waits, in the order it was made.
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
      const pending: Pending = {
        id, method, body, resolve: resolve as (result: unknown) => void, reject, lane: 'queued', firstSentAt: null,
      };
      this.#pending.set(id, pending);
      this.#queue.push(pending);
      this.#pump();
    });
  }

  // MARK: - The channel

  #channelUp(): void {
    if (this.#up) return;
    this.#up = true;
    this.#onUp();
    this.#pump();
  }

  #channelDown(): void {
    if (!this.#up) return;
    this.#up = false;
    this.#onDown();
  }

  /**
   * `sendFailed: tooLarge`. The loader's message names no request, so every posted, unanswered
   * request is failed: the one it refused is among them, and leaving it would wait forever.
   * `request` checks the same limit the loader does, so this should never happen.
   */
  #failPosted(): void {
    for (const pending of [...this.#posted]) {
      this.#settle(pending);
      pending.reject(new AppError('too_large', TOO_LONG_TEXT));
    }
    this.#pump();
  }

  /**
   * `sendFailed: offline`. The loader names no request, so every posted, unanswered request is
   * taken as unsent. Each keeps its ID and body, and is not posted again on this channel.
   */
  #holdPosted(): void {
    for (const pending of this.#posted) {
      pending.lane = 'held';
      this.#held.push(pending);
    }
    this.#posted.clear();
  }

  // MARK: - Sending

  /** Posts what waits, oldest first, while the channel is up and a slot is free. */
  #pump(): void {
    while (this.#up && this.#posted.size < MAX_IN_FLIGHT) {
      const next = this.#queue.shift();
      if (next === undefined) return;
      this.#send(next);
    }
  }

  #send(pending: Pending): void {
    if (pending.firstSentAt === null) pending.firstSentAt = this.#now();
    pending.lane = 'posted';
    this.#posted.add(pending);
    this.#post(pending.body);
  }

  /** Takes an answered or failed request out of every lane. */
  #settle(pending: Pending): void {
    this.#pending.delete(pending.id);
    switch (pending.lane) {
      case 'posted':
        this.#posted.delete(pending);
        break;
      case 'queued':
        this.#queue = this.#queue.filter((p) => p !== pending);
        break;
      case 'held':
        this.#held = this.#held.filter((p) => p !== pending);
        break;
    }
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
   * The request a reply names, if this client sent it and it is still unanswered. A reply that
   * names anything else is ignored: an ID never seen, one already answered or failed, and one
   * still queued, which the laptop has never been sent.
   */
  #sentRequest(requestID: string): Pending | undefined {
    const pending = this.#pending.get(requestID);
    return pending !== undefined && pending.firstSentAt !== null ? pending : undefined;
  }

  #reply(reply: Reply): void {
    const pending = this.#sentRequest(reply.requestID);
    if (pending === undefined) return;
    this.#settle(pending);
    if (reply.error !== undefined) {
      // A code outside the closed list is a reply this build cannot fully read. Its message
      // is the daemon's own words for the phone, so it is kept.
      const { code, message } = reply.error;
      pending.reject(new AppError(isErrorCode(code) ? code : 'bad_reply', message));
    } else {
      let result: unknown;
      try {
        result = decodeResult(pending.method, reply.result);
      } catch {
        pending.reject(new AppError('bad_reply', BAD_REPLY_TEXT));
        this.#pump();
        return;
      }
      pending.resolve(result);
    }
    this.#pump();
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
    this.#settle(pending);
    pending.reject(new AppError('bad_reply', BAD_REPLY_TEXT));
    this.#pump();
  }

  /** Decodes an event's data by its name and hands it on. An event whose data does not decode is dropped. */
  #event(event: EventEnvelope): void {
    let data: unknown;
    try {
      data = decodeEventData(event.event, event.data);
    } catch {
      return;
    }
    this.#onEvent({ event: event.event, seq: event.seq, data } as AppEvent);
  }
}
