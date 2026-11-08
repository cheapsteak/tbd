// The fake laptop for the phone app's end-to-end tests. It answers the app protocol (spec
// section 4.4) from a scenario, the way plan 4b's daemon does, in the wire shapes of the
// fixtures in phone/protocol/. host.js runs it in the top page, outside the app frame, and
// fake-laptop-app.test.js runs it in Node. It is pure: no DOM, no imports.
//
// **A scenario** is the laptop's data in wire form, with relative times:
// - `layout` (PhoneGroupLayout[]), `rows` (PhoneRow[]), `profiles` (PhoneProfile[]) and
//   `providers` (PhoneProvider[]), as the wire carries them;
// - `transcripts`: each session's items (PhoneItem[]) by its ref key, as `refKey` writes it
//   (`local:<terminalID>`, `remote:<provider>/<sessionID>`);
// - `details`: by item ID, the text of each part (`input`, `result`, `text`) and the items of
//   a `subagent`;
// - `prompts`: each session's open prompts (PhonePrompt[]) by its ref key.
// Each key may be left out. Any other key throws, so a typo fails loudly.
//
// **Times.** A session's `status.agoMinutes`, an item's `agoMinutes` and a row's
// `agoMinutes` become `changedAt`, `at` and `statusChangedAt`: `now - agoMinutes * 60_000 -
// 20_000`, rounded to the millisecond, when the scenario loads. The 20 s of slack keep "4m" a
// stable "4m" while a test runs. A row with no `statusChangedAt` takes its newest session's
// `changedAt`, as the daemon's does.
//
// **Connections.** `connect()` starts a connection (the channel came up) and `disconnect()`
// ends it. As in 4b:
// - No event goes out on a connection before its `sessions.subscribe` reply. Events made
//   meanwhile are numbered and kept, so a later subscribe can replay them.
// - A reply goes out through whatever connection the phone has when it is ready, and is lost
//   when it has none. A subscribe reply goes only to the connection that asked for it.
// - A transcript's prompt feed starts only once the connection is live, and a resumed
//   `transcript.open` is answered only then.
// - An acting request's reply is remembered by its request ID: a resend gets it again and acts
//   no more. An ID reused for another method is `bad_request`.
//
// **Size.** Every reply and event is measured as the loader wraps it, `{"type":"app","body":…}`
// in UTF-8, against one frame's 65,519 bytes. One that does not fit throws, so a scenario
// mistake fails the test loudly instead of hanging it.

/** One frame's plaintext (`MAX_PLAINTEXT_LENGTH` in phone/loader/channel/noise.js). */
export const MAX_PLAINTEXT_LENGTH = 65_519;
/** The only event stream this laptop numbers. */
export const STREAM = 's1';
/** The slack added to every `agoMinutes`. */
export const AGO_SLACK_MS = 20_000;
/** The messages a fresh `transcript.open` page reaches back. */
export const FIRST_PAGE_MESSAGES = 4;
/** The messages a `transcript.page` reaches back. */
export const OLDER_PAGE_MESSAGES = 20;
/** The most escaped bytes one detail chunk's text takes (`PhoneFrameBudget.detailChunkBytes`). */
export const DETAIL_CHUNK_BYTES = 60_000;
/** A detail over this many UTF-8 bytes is too large for the phone (`PhoneAppConstants.detailLimitBytes`). */
export const DETAIL_LIMIT_BYTES = 1_048_576;
/** A message text over this many escaped bytes arrives cut (`PhoneAppConstants.messagePreviewBytes`). */
export const MESSAGE_PREVIEW_BYTES = 4_096;

const METHODS = new Set([
  'sessions.subscribe', 'transcript.open', 'transcript.page', 'transcript.detail', 'transcript.close',
  'message.send', 'prompt.answer', 'profiles.list', 'session.switchProfile', 'session.fork',
  'session.setModel', 'worktree.create', 'remote.providers', 'remote.create',
]);
const EVENTS = new Set(['sessions.changed', 'transcript.append', 'transcript.update', 'transcript.reset', 'prompt.changed']);
/** The methods whose replies the daemon remembers (`PhoneAppService.remembersReplies(of:)`). */
const ACTING = new Set([
  'message.send', 'prompt.answer', 'session.switchProfile', 'session.fork', 'session.setModel',
  'worktree.create', 'remote.create',
]);
const SCENARIO_KEYS = new Set(['layout', 'rows', 'transcripts', 'details', 'prompts', 'profiles', 'providers']);
/** Item kinds a transcript leaves out unless `showDetails` is set. */
const DETAIL_KINDS = new Set(['thinking', 'systemNote']);

/** The daemon's words for each refusal the fake makes (`Sources/TBDDaemon/PhoneBridge/App/`). */
export const TEXT = Object.freeze({
  unknownMethod: 'This TBD build has no such request.',
  idInUse: 'That request ID is already in use.',
  badParams: "The request's params are not valid.",
  noSuchSession: 'That session is no longer on this laptop.',
  noSuchProfile: 'That profile is no longer on this laptop.',
  noSuchRepo: 'That repo is no longer on this laptop.',
  noSuchProvider: "That remote session's provider is not registered on this laptop.",
  refused: 'The laptop refused the message.',
  notOpen: 'That transcript is not open. Open it again.',
  staleCursor: 'That part of the transcript has changed. Reopen the transcript to load it again.',
  detailNotFound: 'That detail is not in the transcript.',
  detailChunk: 'That part of the detail does not exist.',
  emptyMessage: 'Write a message first.',
  notAModel: 'That is not a model name.',
  remoteOnly: 'Not available for remote sessions.',
});

const AVAILABLE = Object.freeze({ available: true });
const REMOTE_CAPABILITIES = Object.freeze({
  transcript: AVAILABLE, send: AVAILABLE, answer: AVAILABLE, model: AVAILABLE,
  switchProfile: Object.freeze({ available: false, reason: TEXT.remoteOnly }),
  fork: Object.freeze({ available: false, reason: TEXT.remoteOnly }),
});
const CLAUDE_CAPABILITIES = Object.freeze({
  transcript: AVAILABLE, send: AVAILABLE, answer: AVAILABLE, switchProfile: AVAILABLE, fork: AVAILABLE, model: AVAILABLE,
});

const utf8 = new TextEncoder();

/**
 * @typedef {{ result: Record<string, unknown> } | { error: { code: string, message: string } }} Outcome
 *   What a reply carries, beside its envelope.
 * @typedef {Outcome | ((params: Record<string, any>, state: FakeLaptopState) => Outcome)} ReplySetting
 * @typedef {{ requestID: string, method: string, params: Record<string, any> }} Request
 */

/**
 * @typedef {object} FakeLaptopState What the laptop holds now. Read it; never write it.
 * @property {string} stream
 * @property {number} seq The `seq` of the last event numbered, 0 before any.
 * @property {Array<{ kind: 'event', event: string, seq: number, data: unknown }>} log Every
 *   event numbered, in order, as it went out (or would have).
 * @property {any[]} layout
 * @property {any[]} rows
 * @property {Record<string, any[]>} transcripts
 * @property {Record<string, Record<string, any>>} details
 * @property {Record<string, any[]>} prompts
 * @property {any[]} profiles
 * @property {any[]} providers
 * @property {{ session: any, showDetails: boolean } | null} open The open transcript.
 * @property {{ live: boolean, replayed: boolean } | null} connection Null while the phone is away.
 */

/**
 * Makes one fake laptop.
 * @param {object} options
 * @param {object} [options.scenario] The data it starts with (see the header).
 * @param {(body: Record<string, unknown>) => void} options.emit Sends one app body to the phone.
 * @param {() => number} [options.now] Unix milliseconds.
 * @param {(fn: () => void) => void} [options.defer] Runs `fn` on a later task.
 */
export function createFakeLaptop({ scenario = {}, emit, now = () => Date.now(), defer = (fn) => { setTimeout(fn, 0); } }) {
  /** @type {FakeLaptopState} */
  const state = {
    stream: STREAM,
    seq: 0,
    log: [],
    layout: [],
    rows: [],
    transcripts: {},
    details: {},
    prompts: {},
    profiles: [],
    providers: [],
    open: null,
    connection: null,
  };
  /** Work waiting for the current connection to go live. */
  let afterLive = [];
  /** @type {Map<string, Array<() => void>>} Held replies, by method, and held events, by name. */
  const holds = new Map();
  /** @type {Map<string, ReplySetting>} */
  const overrides = new Map();
  /** @type {Map<string, { method: string, outcome: Outcome | null }>} */
  const memory = new Map();
  let minted = 0;
  let worktreesMade = 0;
  let remotesMade = 0;
  let openToken = 0;
  let t0 = now();

  // --- the scenario ---------------------------------------------------------------------

  /**
   * Replaces the laptop's data with `next`, resolving its times against now. The stream, its
   * numbering and the connection stay, so a phone already subscribed sees the new data only
   * through a later snapshot or event. Any open transcript is closed.
   * @param {object} next
   */
  function load(next) {
    if (!isRecord(next)) throw new TypeError('fake laptop: a scenario is an object');
    for (const key of Object.keys(next)) {
      if (!SCENARIO_KEYS.has(key)) throw new TypeError(`fake laptop: a scenario has no key ${key}`);
    }
    const s = structuredClone(next);
    t0 = now();
    state.layout = s.layout ?? [];
    state.rows = (s.rows ?? []).map(resolveRow);
    state.transcripts = mapValues(s.transcripts ?? {}, (items) => items.map(resolveItem));
    state.details = mapValues(s.details ?? {}, (parts) => (
      parts.subagent === undefined ? parts : { ...parts, subagent: parts.subagent.map(resolveItem) }));
    state.prompts = s.prompts ?? {};
    state.profiles = s.profiles ?? [];
    state.providers = s.providers ?? [];
    state.open = null;
  }

  /** @param {number} minutes */
  function ago(minutes) {
    return Math.round(t0 - minutes * 60_000 - AGO_SLACK_MS);
  }

  /** @param {any} status */
  function resolveStatus(status) {
    if (!isRecord(status) || status.agoMinutes === undefined) return status;
    const { agoMinutes, ...rest } = status;
    return { ...rest, changedAt: ago(agoMinutes) };
  }

  /** @param {any} row */
  function resolveRow(row) {
    const { agoMinutes, ...rest } = row;
    const sessions = (rest.sessions ?? []).map((/** @type {any} */ s) => ({ ...s, status: resolveStatus(s.status) }));
    let statusChangedAt = rest.statusChangedAt;
    if (statusChangedAt === undefined) statusChangedAt = agoMinutes === undefined ? newest(sessions) : ago(agoMinutes);
    return { ...rest, sessions, statusChangedAt };
  }

  /** @param {any} item */
  function resolveItem(item) {
    if (!isRecord(item) || item.agoMinutes === undefined) return item;
    const { agoMinutes, ...rest } = item;
    return { ...rest, at: ago(agoMinutes) };
  }

  /** @param {any[]} sessions */
  function newest(sessions) {
    let at = 0;
    for (const s of sessions) at = Math.max(at, s.status?.changedAt ?? 0);
    return at === 0 ? Math.round(t0 - AGO_SLACK_MS) : at;
  }

  // --- the connection -------------------------------------------------------------------

  /** The channel came up: a new connection, not live until its subscribe reply goes out. */
  function connect() {
    state.connection = { live: false, replayed: false };
    afterLive = [];
  }

  /** The channel went down. Anything waiting for the connection to go live is dropped. */
  function disconnect() {
    state.connection = null;
    afterLive = [];
  }

  /**
   * Runs `fn` once `conn` is live: at once when it is, later when it is still the current
   * connection, and never when the phone has moved on.
   * @param {FakeLaptopState['connection']} conn
   * @param {() => void} fn
   */
  function whenLive(conn, fn) {
    if (conn === null || state.connection !== conn) return;
    if (conn.live) fn();
    else afterLive.push(fn);
  }

  /**
   * The subscribe reply went out on `conn`: it is live. A replay sends every kept event after
   * `sinceSeq`, in order, then whatever waited for the connection.
   * @param {FakeLaptopState['connection']} conn
   * @param {number | null} sinceSeq
   */
  function goLive(conn, sinceSeq) {
    if (conn === null || state.connection !== conn || conn.live) return;
    conn.live = true;
    if (sinceSeq !== null) {
      for (const body of state.log) if (body.seq > sinceSeq) emit(body);
    }
    const waiting = afterLive;
    afterLive = [];
    for (const fn of waiting) fn();
  }

  // --- holds and overrides --------------------------------------------------------------

  /**
   * Holds every reply to `name`, if it is a method, or every emit of `name`, if it is an event,
   * until `release(name)`. A held event is numbered only when it is released.
   * @param {string} name
   */
  function hold(name) {
    checkName(name);
    if (!holds.has(name)) holds.set(name, []);
  }

  /**
   * Sends what `hold(name)` kept, in the order it was made, and holds nothing more.
   * @param {string} name
   */
  function release(name) {
    checkName(name);
    const waiting = holds.get(name);
    holds.delete(name);
    for (const fn of waiting ?? []) fn();
  }

  /**
   * Replaces `method`'s default handler: every later request gets `reply` (or what `reply`
   * returns for its params) as it is, and nothing else happens. Null brings the default back.
   * A `sessions.subscribe` reply with a result still makes its connection live.
   * @param {string} method
   * @param {ReplySetting | null} reply
   */
  function setReply(method, reply) {
    if (!METHODS.has(method)) throw new RangeError(`fake laptop: no method ${method}`);
    if (reply === null) {
      overrides.delete(method);
    } else {
      if (typeof reply !== 'function') checkOutcome(reply);
      overrides.set(method, reply);
    }
  }

  /** @param {string} name */
  function checkName(name) {
    if (!METHODS.has(name) && !EVENTS.has(name)) throw new RangeError(`fake laptop: no method or event ${name}`);
  }

  /** @param {string} name @param {() => void} fn */
  function heldOr(name, fn) {
    const waiting = holds.get(name);
    if (waiting === undefined) fn();
    else waiting.push(fn);
  }

  // --- sending --------------------------------------------------------------------------

  /**
   * Replies to `request`. `outcome` may be a function, which builds it when the reply goes
   * out, so a held snapshot shows the state at its release.
   * @param {Request} request
   * @param {Outcome | (() => Outcome)} outcome
   * @param {(() => void)} [onSent]
   */
  function reply(request, outcome, onSent) {
    const conn = state.connection;
    const make = typeof outcome === 'function' ? outcome : () => outcome;
    if (typeof outcome !== 'function') {
      checkFits(replyBody(request, outcome), request.method);
      const remembered = memory.get(request.requestID);
      if (remembered !== undefined && ACTING.has(request.method)) remembered.outcome = outcome;
    }
    heldOr(request.method, () => {
      if (state.connection === null) return;
      if (request.method === 'sessions.subscribe' && state.connection !== conn) return;
      const body = replyBody(request, make());
      checkFits(body, request.method);
      emit(body);
      onSent?.();
    });
  }

  /**
   * Numbers `event` and sends it when the connection is live. Every numbered event is kept for
   * replay.
   * @param {string} event
   * @param {unknown} data
   */
  function sendEvent(event, data) {
    heldOr(event, () => {
      const body = { kind: 'event', event, seq: state.seq + 1, data };
      checkFits(body, event);
      state.seq = body.seq;
      state.log.push(body);
      if (state.connection?.live) emit(body);
    });
  }

  /**
   * An event as a test wrote it: its times resolved, folded into the laptop's data, then
   * numbered and sent like the laptop's own.
   * @param {string} event
   * @param {any} data
   */
  function emitEvent(event, data) {
    if (!EVENTS.has(event)) throw new RangeError(`fake laptop: no event ${event}`);
    const resolved = resolveEventData(event, structuredClone(data));
    applyEvent(event, resolved);
    sendEvent(event, resolved);
  }

  /** @param {string} event @param {any} data */
  function resolveEventData(event, data) {
    if (!isRecord(data)) return data;
    if (event === 'sessions.changed' && Array.isArray(data.rows)) return { ...data, rows: data.rows.map(resolveRow) };
    if ((event === 'transcript.append' || event === 'transcript.update') && Array.isArray(data.items)) {
      return { ...data, items: data.items.map(resolveItem) };
    }
    if (event === 'transcript.reset' && isRecord(data.page) && Array.isArray(data.page.items)) {
      return { ...data, page: { ...data.page, items: data.page.items.map(resolveItem) } };
    }
    return data;
  }

  /** @param {string} event @param {any} data */
  function applyEvent(event, data) {
    if (!isRecord(data)) return;
    if (event === 'sessions.changed') {
      if (Array.isArray(data.layout)) state.layout = structuredClone(data.layout);
      const removed = new Set(Array.isArray(data.removedRowIDs) ? data.removedRowIDs : []);
      state.rows = state.rows.filter((row) => !removed.has(row.id));
      for (const row of Array.isArray(data.rows) ? data.rows : []) putRow(structuredClone(row));
      return;
    }
    if (!isRef(data.session)) return;
    const key = refKey(data.session);
    if (event === 'transcript.append' && Array.isArray(data.items)) {
      state.transcripts[key] = [...(state.transcripts[key] ?? []), ...structuredClone(data.items)];
    } else if (event === 'transcript.update' && Array.isArray(data.items)) {
      const byID = new Map(data.items.map((/** @type {any} */ item) => [item.id, item]));
      state.transcripts[key] = (state.transcripts[key] ?? []).map((item) => structuredClone(byID.get(item.id) ?? item));
    } else if (event === 'transcript.reset' && isRecord(data.page) && Array.isArray(data.page.items)) {
      state.transcripts[key] = structuredClone(data.page.items);
    } else if (event === 'prompt.changed' && Array.isArray(data.prompts)) {
      state.prompts[key] = structuredClone(data.prompts);
    }
  }

  // --- requests -------------------------------------------------------------------------

  /**
   * One app body from the phone. Only a request is expected; anything else throws.
   * @param {unknown} body
   */
  function handle(body) {
    if (!isRecord(body) || body.kind !== 'request' || typeof body.requestID !== 'string' || typeof body.method !== 'string') {
      throw new TypeError(`fake laptop: not a request: ${JSON.stringify(body)}`);
    }
    /** @type {Request} */
    const request = { requestID: body.requestID, method: body.method, params: isRecord(body.params) ? body.params : {} };
    const seen = memory.get(request.requestID);
    if (seen !== undefined) {
      if (seen.method !== request.method) {
        reply(request, failure('bad_request', TEXT.idInUse));
        return;
      }
      if (seen.outcome !== null) {
        reply(request, seen.outcome);
        return;
      }
    } else {
      memory.set(request.requestID, { method: request.method, outcome: null });
    }
    if (!METHODS.has(request.method)) {
      reply(request, failure('unknown_method', TEXT.unknownMethod));
      return;
    }
    const override = overrides.get(request.method);
    if (override !== undefined) {
      const outcome = typeof override === 'function' ? override(request.params, state) : override;
      checkOutcome(outcome);
      const conn = state.connection;
      if (request.method === 'sessions.subscribe' && 'result' in outcome) {
        if (conn !== null) conn.replayed = outcome.result.replayed === true;
        reply(request, outcome, () => goLive(conn, null));
      } else {
        reply(request, outcome);
      }
      return;
    }
    HANDLERS[/** @type {keyof typeof HANDLERS} */ (request.method)](request);
  }

  /**
   * The default handlers, by method. Each answers through `reply`.
   * @type {Record<string, (request: Request) => void>}
   */
  const HANDLERS = {
    'sessions.subscribe': (request) => {
      const { stream, sinceSeq } = request.params;
      const conn = state.connection;
      const replays = stream === STREAM && Number.isInteger(sinceSeq) && sinceSeq >= 0 && sinceSeq <= state.seq;
      if (conn !== null) conn.replayed = replays;
      if (replays) {
        reply(request, () => ({ result: { stream: STREAM, seq: state.seq, replayed: true, omittedRows: 0, more: false } }),
          () => goLive(conn, sinceSeq));
      } else {
        reply(request, () => ({
          result: {
            stream: STREAM, seq: state.seq, replayed: false, layout: state.layout, rows: state.rows, omittedRows: 0, more: false,
          },
        }), () => goLive(conn, null));
      }
    },

    'transcript.open': (request) => {
      const { session, showDetails = false, resume = false } = request.params;
      const found = sessionOrRefuse(request, 'transcript');
      if (found === null) return;
      const conn = state.connection;
      const open = state.open;
      if (resume === true && conn?.replayed === true && open !== null && sameRef(open.session, session)
        && open.showDetails === showDetails) {
        whenLive(conn, () => reply(request, () => ({ result: { resumed: true, seq: state.seq } })));
        return;
      }
      const token = ++openToken;
      state.open = { session: structuredClone(session), showDetails: showDetails === true };
      const items = transcriptOf(session);
      const page = pageOf(items, startBefore(items, items.length, FIRST_PAGE_MESSAGES), items.length, showDetails === true);
      reply(request, () => ({ result: { resumed: false, seq: state.seq, page } }), () => whenLive(conn, () => {
        if (openToken !== token || state.open === null) return;
        sendEvent('prompt.changed', { session: state.open.session, prompts: state.prompts[refKey(session)] ?? [] });
      }));
    },

    'transcript.page': (request) => {
      const { session, cursor } = request.params;
      if (!isOpen(session)) {
        reply(request, failure('not_open', TEXT.notOpen));
        return;
      }
      const items = transcriptOf(session);
      const end = typeof cursor === 'string' && /^[0-9]+$/.test(cursor) ? Number(cursor) : Number.NaN;
      if (!(end > 0 && end <= items.length)) {
        reply(request, failure('stale_cursor', TEXT.staleCursor));
        return;
      }
      const showDetails = state.open?.showDetails === true;
      reply(request, { result: pageOf(items, startBefore(items, end, OLDER_PAGE_MESSAGES), end, showDetails) });
    },

    'transcript.detail': (request) => {
      const { session, itemID, part, chunk } = request.params;
      if (!isOpen(session)) {
        reply(request, failure('not_open', TEXT.notOpen));
        return;
      }
      const parts = Object.hasOwn(state.details, itemID) ? state.details[itemID] : undefined;
      const detail = parts !== undefined && Object.hasOwn(parts, part) ? parts[part] : undefined;
      if (detail === undefined) {
        reply(request, failure('not_found', TEXT.detailNotFound));
        return;
      }
      if (part === 'subagent') {
        if (chunk !== 0) {
          reply(request, failure('bad_request', TEXT.detailChunk));
          return;
        }
        reply(request, {
          result: { itemID, part, chunk: 0, chunkCount: 1, totalBytes: utf8Bytes(JSON.stringify(detail)), tooLarge: false, items: detail },
        });
        return;
      }
      const totalBytes = utf8Bytes(detail);
      const tooLarge = totalBytes > DETAIL_LIMIT_BYTES;
      const chunks = chunkText(detail, DETAIL_CHUNK_BYTES, tooLarge ? 1 : Infinity);
      if (!Number.isInteger(chunk) || chunk < 0 || chunk >= chunks.length) {
        reply(request, failure('bad_request', TEXT.detailChunk));
        return;
      }
      reply(request, { result: { itemID, part, chunk, chunkCount: chunks.length, totalBytes, tooLarge, text: chunks[chunk] } });
    },

    'transcript.close': (request) => {
      state.open = null;
      openToken += 1;
      reply(request, { result: {} });
    },

    'message.send': (request) => {
      const { session, text } = request.params;
      if (typeof text !== 'string' || text.trim() === '') {
        reply(request, failure('bad_request', TEXT.emptyMessage));
        return;
      }
      const found = sessionOrRefuse(request, 'send');
      if (found === null) return;
      const parked = found.session.status?.chip === 'parked';
      reply(request, { result: { outcome: parked ? 'woken' : 'sent' } });
      const id = `fake-item-${++minted}`;
      const preview = chunkText(text, MESSAGE_PREVIEW_BYTES, 1)[0];
      const item = { id, kind: 'user', at: now(), text: preview, truncated: preview !== text };
      if (item.truncated) state.details[id] = { text };
      const key = refKey(session);
      state.transcripts[key] = [...(state.transcripts[key] ?? []), item];
      if (isOpen(session)) sendEvent('transcript.append', { session: found.session.ref, items: [item] });
      setChip(found, 'working');
      sendEvent('sessions.changed', { rows: [found.row], removedRowIDs: [] });
    },

    'prompt.answer': (request) => {
      const { session, promptID } = request.params;
      const found = sessionOrRefuse(request, 'answer');
      if (found === null) return;
      const key = refKey(session);
      const prompts = state.prompts[key] ?? [];
      if (!prompts.some((p) => p.id === promptID)) {
        reply(request, { result: { outcome: 'already_resolved' } });
        return;
      }
      reply(request, { result: { outcome: 'delivered' } });
      const left = prompts.filter((p) => p.id !== promptID);
      state.prompts[key] = left;
      if (isOpen(session)) {
        sendEvent('prompt.changed', { session: found.session.ref, prompts: left, resolved: [{ promptID, answeredBy: 'phone' }] });
      }
      if (left.length > 0) {
        found.session.openPromptID = left[0].id;
      } else {
        delete found.session.openPromptID;
        if (found.session.status?.chip === 'waitingForYou') setChip(found, 'working');
      }
      sendEvent('sessions.changed', { rows: [found.row], removedRowIDs: [] });
    },

    'profiles.list': (request) => {
      reply(request, { result: { profiles: state.profiles } });
    },

    'remote.providers': (request) => {
      reply(request, { result: { providers: state.providers } });
    },

    'session.switchProfile': (request) => {
      const found = sessionOrRefuse(request, 'switchProfile');
      if (found === null) return;
      const profile = state.profiles.find((p) => p.id === request.params.profileID);
      if (profile === undefined) {
        reply(request, failure('not_found', TEXT.noSuchProfile));
        return;
      }
      reply(request, { result: { session: found.session.ref } });
      defer(() => {
        found.session.profileID = profile.id;
        found.session.profileName = profile.name;
        setChip(found, 'idle');
        sendEvent('sessions.changed', { rows: [found.row], removedRowIDs: [] });
      });
    },

    'session.fork': (request) => {
      const found = sessionOrRefuse(request, 'fork');
      if (found === null) return;
      const { profileID } = request.params;
      const profile = profileID === undefined ? null : state.profiles.find((p) => p.id === profileID);
      if (profile === undefined) {
        reply(request, failure('not_found', TEXT.noSuchProfile));
        return;
      }
      const ref = { kind: 'local', terminalID: mintID() };
      reply(request, { result: { session: ref } });
      defer(() => {
        const parent = found.session;
        /** @type {any} */
        const fork = {
          ...structuredClone(parent),
          ref,
          tabName: `${parent.tabName} ${found.row.sessions.length + 1}`,
          status: { chip: 'idle', changedAt: now() },
        };
        delete fork.openPromptID;
        if (profile !== null) {
          fork.profileID = profile.id;
          fork.profileName = profile.name;
        }
        found.row.sessions.push(fork);
        found.row.statusChangedAt = newest(found.row.sessions);
        state.transcripts[refKey(ref)] = structuredClone(state.transcripts[refKey(parent.ref)] ?? []);
        sendEvent('sessions.changed', { rows: [found.row], removedRowIDs: [] });
      });
    },

    'session.setModel': (request) => {
      const { model } = request.params;
      const found = sessionOrRefuse(request, 'model');
      if (found === null) return;
      if (typeof model !== 'string' || model.trim() === '') {
        reply(request, failure('bad_request', TEXT.notAModel));
        return;
      }
      reply(request, { result: { outcome: 'sent' } });
      defer(() => {
        found.session.model = model;
        sendEvent('sessions.changed', { rows: [found.row], removedRowIDs: [] });
      });
    },

    'worktree.create': (request) => {
      const { repoID, message } = request.params;
      const group = repoGroup(repoID);
      if (group === null) {
        reply(request, failure('not_found', TEXT.noSuchRepo));
        return;
      }
      const worktreeID = mintID();
      const ref = { kind: 'local', terminalID: mintID() };
      const profile = state.profiles.find((p) => p.isDefault === true);
      /** @type {any} */
      const session = {
        ref, agent: 'claude', tabName: 'Claude', status: { chip: 'working', changedAt: now() }, capabilities: CLAUDE_CAPABILITIES,
      };
      if (profile !== undefined) {
        session.profileID = profile.id;
        session.profileName = profile.name;
      }
      const row = {
        id: worktreeID, kind: 'worktree', name: `new-worktree-${++worktreesMade}`, remote: false,
        statusChangedAt: session.status.changedAt, sessions: [session],
      };
      addRow(group, row, ref, message);
      reply(request, { result: { worktreeID, session: ref } });
    },

    'remote.create': (request) => {
      const { provider, repoID, message } = request.params;
      if (!state.providers.some((p) => p.name === provider)) {
        reply(request, failure('not_found', TEXT.noSuchProvider));
        return;
      }
      const group = repoGroup(repoID);
      if (group === null) {
        reply(request, failure('not_found', TEXT.noSuchRepo));
        return;
      }
      const ref = { kind: 'remote', provider, sessionID: `rs-${++remotesMade}` };
      const session = {
        ref, agent: 'remote', tabName: provider, status: { chip: 'working', changedAt: now() }, capabilities: REMOTE_CAPABILITIES,
      };
      const row = {
        id: refKey(ref), kind: 'remoteSession', name: `new-remote-${remotesMade}`, remote: true,
        statusChangedAt: session.status.changedAt, sessions: [session],
      };
      addRow(group, row, ref, message);
      reply(request, { result: { session: ref } });
    },
  };

  // --- helpers on the laptop's data -----------------------------------------------------

  /**
   * The session `request.params.session` names, or null once it has replied: `bad_request`
   * for a ref that is not one, `not_found` for one no row lists, and `refused` with the
   * capability's reason when `capability` is unavailable.
   * @param {Request} request
   * @param {string} capability
   */
  function sessionOrRefuse(request, capability) {
    const ref = request.params.session;
    if (!isRef(ref)) {
      reply(request, failure('bad_request', TEXT.badParams));
      return null;
    }
    const found = findSession(ref);
    if (found === null) {
      reply(request, failure('not_found', TEXT.noSuchSession));
      return null;
    }
    const cap = found.session.capabilities?.[capability];
    if (isRecord(cap) && cap.available === false) {
      reply(request, failure(capability === 'transcript' ? 'unsupported' : 'refused', cap.reason ?? TEXT.refused));
      return null;
    }
    return found;
  }

  /** @param {any} ref */
  function findSession(ref) {
    for (const row of state.rows) {
      const session = row.sessions.find((/** @type {any} */ s) => sameRef(s.ref, ref));
      if (session !== undefined) return { row, session };
    }
    return null;
  }

  /** @param {{ row: any, session: any }} found @param {string} chip */
  function setChip(found, chip) {
    found.session.status = { chip, changedAt: now() };
    found.row.statusChangedAt = newest(found.row.sessions);
  }

  /** @param {any} row */
  function putRow(row) {
    const at = state.rows.findIndex((r) => r.id === row.id);
    if (at < 0) state.rows.push(row);
    else state.rows[at] = row;
  }

  /** @param {unknown} repoID */
  function repoGroup(repoID) {
    if (typeof repoID !== 'string') return null;
    return state.layout.find((g) => g.id === `repo:${repoID}`) ?? null;
  }

  /**
   * Adds `row` to the end of `group`, with `message` as its session's first item when it has
   * one, and announces it with the new layout.
   * @param {any} group @param {any} row @param {any} ref @param {unknown} message
   */
  function addRow(group, row, ref, message) {
    group.rows.push({ id: row.id, depth: 0 });
    state.rows.push(row);
    state.transcripts[refKey(ref)] = typeof message === 'string' && message.trim() !== ''
      ? [{ id: `fake-item-${++minted}`, kind: 'user', at: now(), text: message, truncated: false }]
      : [];
    sendEvent('sessions.changed', { layout: state.layout, rows: [row], removedRowIDs: [] });
  }

  /** @param {any} ref */
  function transcriptOf(ref) {
    return state.transcripts[refKey(ref)] ?? [];
  }

  /** @param {unknown} ref */
  function isOpen(ref) {
    return state.open !== null && isRef(ref) && sameRef(state.open.session, ref);
  }

  /** A fresh UUID-shaped ID, in the daemon's upper case. */
  function mintID() {
    minted += 1;
    return `00000000-0000-4000-8000-${minted.toString(16).toUpperCase().padStart(12, '0')}`;
  }

  load(scenario);
  return { state, handle, connect, disconnect, emitEvent, setReply, hold, release, load };
}

// --- pure helpers -----------------------------------------------------------------------

/**
 * A session's key, as the app's `refKey` (phone/app/src/protocol/wire.ts) writes it.
 * @param {any} ref
 */
export function refKey(ref) {
  if (ref.kind === 'local') return `local:${ref.terminalID}`;
  const provider = ref.provider.replaceAll('%', '%25').replaceAll('/', '%2F');
  return `remote:${provider}/${ref.sessionID}`;
}

/** @param {any} a @param {any} b */
function sameRef(a, b) {
  if (!isRef(a) || !isRef(b)) return false;
  return refKey(a) === refKey(b);
}

/** @param {unknown} ref */
function isRef(ref) {
  if (!isRecord(ref)) return false;
  if (ref.kind === 'local') return typeof ref.terminalID === 'string';
  return ref.kind === 'remote' && typeof ref.provider === 'string' && typeof ref.sessionID === 'string';
}

/** @param {any} item */
function isMessage(item) {
  return item.kind === 'user' || item.kind === 'assistant';
}

/**
 * The index of the `count`-th user or assistant item before `end`, or 0 when there are fewer.
 * @param {any[]} items @param {number} end @param {number} count
 */
export function startBefore(items, end, count) {
  let seen = 0;
  for (let i = end - 1; i >= 0; i--) {
    if (isMessage(items[i]) && ++seen === count) return i;
  }
  return 0;
}

/**
 * `items[start..end)` as a page, without the detail kinds unless `showDetails`. The cursor is
 * the start index as a string, and is absent once the page reaches the start.
 * @param {any[]} items @param {number} start @param {number} end @param {boolean} showDetails
 */
function pageOf(items, start, end, showDetails) {
  const shown = items.slice(start, end).filter((item) => showDetails || !DETAIL_KINDS.has(item.kind));
  return start > 0
    ? { items: shown, cursor: String(start), reachedStart: false, omittedItems: 0 }
    : { items: shown, reachedStart: true, omittedItems: 0 };
}

/**
 * `text` cut at code point boundaries into chunks whose JSON string bodies take at most
 * `budget` UTF-8 bytes each, at most `limit` of them. An empty text is one empty chunk.
 * @param {string} text @param {number} budget @param {number} limit
 */
export function chunkText(text, budget, limit) {
  const chunks = [];
  let chunk = '';
  let used = 0;
  for (const cp of text) {
    const size = utf8Bytes(JSON.stringify(cp)) - 2;
    if (used + size > budget && chunk !== '') {
      chunks.push(chunk);
      if (chunks.length >= limit) return chunks;
      chunk = '';
      used = 0;
    }
    chunk += cp;
    used += size;
  }
  chunks.push(chunk);
  return chunks;
}

/** @param {string} s */
function utf8Bytes(s) {
  return utf8.encode(s).length;
}

/**
 * The bytes `body` takes as the loader sends it, `{"type":"app","body":…}` in UTF-8.
 * @param {unknown} body
 */
export function frameBytes(body) {
  return utf8Bytes(JSON.stringify({ type: 'app', body }));
}

/** @param {unknown} body @param {string} name */
function checkFits(body, name) {
  const bytes = frameBytes(body);
  if (bytes > MAX_PLAINTEXT_LENGTH) {
    throw new RangeError(`fake laptop: ${name} takes ${bytes} bytes, more than one frame's ${MAX_PLAINTEXT_LENGTH}`);
  }
}

/** @param {Request} request @param {Outcome} outcome */
function replyBody(request, outcome) {
  return { kind: 'reply', requestID: request.requestID, ...outcome };
}

/** @param {string} code @param {string} message @returns {Outcome} */
function failure(code, message) {
  return { error: { code, message } };
}

/** @param {unknown} outcome */
function checkOutcome(outcome) {
  const keys = isRecord(outcome) ? Object.keys(outcome) : [];
  const ok = keys.length === 1
    && ((keys[0] === 'result' && isRecord(/** @type {any} */ (outcome).result))
      || (keys[0] === 'error' && isRecord(/** @type {any} */ (outcome).error)));
  if (!ok) throw new TypeError(`fake laptop: a reply is { result } or { error }, not ${JSON.stringify(outcome)}`);
}

/**
 * @template T, U
 * @param {Record<string, T>} record @param {(value: T) => U} fn
 * @returns {Record<string, U>}
 */
function mapValues(record, fn) {
  /** @type {Record<string, U>} */
  const out = {};
  for (const [key, value] of Object.entries(record)) out[key] = fn(value);
  return out;
}

/** @param {unknown} value @returns {value is Record<string, any>} */
function isRecord(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
