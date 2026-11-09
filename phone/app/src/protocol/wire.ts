/**
 * The app protocol on the wire: its names, the envelope, one decoder per wire type, the method
 * and event tables built from them, request bodies, and session-reference keys. The names and
 * shapes mirror `Sources/TBDDaemon/PhoneBridge/App/PhoneAppProtocol.swift` and
 * `PhoneAppMessages.swift`; every fixture in `phone/protocol/` decodes and encodes back to
 * itself (`fixtures.test.ts`).
 *
 * Decoding is two steps. `decodeEnvelope` reads a body's envelope and keeps its `result` or
 * `data` unread, typed `unknown`. `decodeResult` or `decodeEventData` then decodes that value
 * by the request's method or the event's name, rebuilding it from its known fields.
 */

import { arr, bool, DecodeError, field, has, int, nullableNever, obj, oneOf, plainObject, record, str } from './decode.ts';
import type { Decoder } from './decode.ts';
import type {
  ActionOutcomeResult, DataOf, ErrorCode, EventName, Method, ParamsOf, PendingPromptKind, PermissionDecision,
  PhoneAgent, PhoneAnsweredBy, PhoneAppError, PhoneCapabilities, PhoneCapability, PhoneEmpty, PhoneFormField,
  PhoneGroupKind, PhoneGroupLayout, PhoneItem, PhoneItemKind, PhoneOption, PhoneProfile, PhonePrompt,
  PhonePromptAnswerParams, PhonePromptResolution, PhoneProvider, PhoneQuestion, PhoneRemoteCreateParams,
  PhoneRemoteProvidersParams, PhoneRemoteProvidersResult, PhoneRow, PhoneRowKind, PhoneRowPlacement, PhoneSession,
  PhoneSessionRef, PhoneStatus, PhoneStatusChip, PhoneWorktreeCreateParams, PhoneWorktreeCreateResult,
  ProfilesListResult, PromptAnswer, PromptAnswerOutcome, PromptAnswerResult, PromptChangedData, MessageSendParams,
  ResultOf, SessionForkParams, SessionRefResult, SessionSetModelParams, SessionSwitchProfileParams,
  SessionSwitchProfileResult,
  SessionsChangedData, SessionsSubscribeParams, SessionsSubscribeResult, TranscriptDetailParams, TranscriptDetailPart,
  TranscriptDetailResult, TranscriptItemsData, TranscriptOpenParams, TranscriptOpenResult, TranscriptPage,
  TranscriptPageParams, TranscriptResetData,
} from './types.ts';

export { DecodeError };
export type { Decoder };

// MARK: - Names

/**
 * The keys of `set`, in order, as a frozen list. Each list below is written as a
 * `Record<Union, true>` with the union named, so the compiler checks that it holds every member
 * of its union and nothing else.
 */
function members<K extends string>(set: Readonly<Record<K, true>>): readonly K[] {
  return Object.freeze(Object.keys(set) as K[]);
}

/** The 14 methods, in `PhoneAppMethod`'s order. */
export const METHODS = members<Method>({
  'sessions.subscribe': true,
  'transcript.open': true,
  'transcript.page': true,
  'transcript.detail': true,
  'transcript.close': true,
  'message.send': true,
  'prompt.answer': true,
  'profiles.list': true,
  'session.switchProfile': true,
  'session.fork': true,
  'session.setModel': true,
  'worktree.create': true,
  'remote.providers': true,
  'remote.create': true,
});

/** The 5 events, in `PhoneAppEventName`'s order. */
export const EVENTS = members<EventName>({
  'sessions.changed': true,
  'transcript.append': true,
  'transcript.update': true,
  'transcript.reset': true,
  'prompt.changed': true,
});

/** The 10 error codes, in `PhoneAppErrorCode`'s order. */
export const ERROR_CODES = members<ErrorCode>({
  phone_control_off: true,
  bad_request: true,
  unknown_method: true,
  not_found: true,
  unsupported: true,
  refused: true,
  not_open: true,
  stale_cursor: true,
  unavailable: true,
  internal: true,
});

export const PHONE_STATUS_CHIPS = members<PhoneStatusChip>({
  waitingForYou: true, working: true, idle: true, parked: true, rateLimited: true, error: true, exited: true, unknown: true,
});
export const PHONE_AGENTS = members<PhoneAgent>({ claude: true, codex: true, remote: true });
export const PHONE_ROW_KINDS = members<PhoneRowKind>({ worktree: true, remoteSession: true });
export const PHONE_GROUP_KINDS = members<PhoneGroupKind>({ scratch: true, repo: true, provider: true });
export const PHONE_ITEM_KINDS = members<PhoneItemKind>({
  user: true, assistant: true, tool: true, fileEdit: true, subagent: true, slash: true, peer: true, thinking: true, systemNote: true,
});
export const TRANSCRIPT_DETAIL_PARTS = members<TranscriptDetailPart>({ input: true, result: true, text: true, subagent: true });
export const PENDING_PROMPT_KINDS = members<PendingPromptKind>({ question: true, permission: true });
export const PHONE_ANSWERED_BY = members<PhoneAnsweredBy>({ phone: true, laptop: true, unknown: true });
export const PERMISSION_DECISIONS = members<PermissionDecision>({ allow: true, allow_always: true, deny: true });
export const PROMPT_ANSWER_OUTCOMES = members<PromptAnswerOutcome>({ delivered: true, already_resolved: true, unknown: true });

/** Whether `code`, a reply error's code, is one of the closed list. */
export function isErrorCode(code: string): code is ErrorCode {
  return (ERROR_CODES as readonly string[]).includes(code);
}

// MARK: - Envelope

/**
 * One app body from the laptop. A reply carries exactly one of `result` and `error`; its
 * `result`, and an event's `data`, are left unread for `decodeResult` and `decodeEventData`.
 * A reply's `requestID` may be empty: the daemon sends an `internal` error with no request ID
 * when it cannot encode a reply at all.
 */
export type Envelope =
  | { kind: 'reply'; requestID: string; result?: unknown; error?: PhoneAppError }
  | { kind: 'event'; event: EventName; seq: number; data: unknown };

export const decodeEventName: Decoder<EventName> = oneOf(EVENTS);
const decodeEnvelopeKind = oneOf(['reply', 'event']);
const decodePhoneAppError = obj<PhoneAppError>({ code: str, message: str }, {});
/** Any value but `null`, left unread. */
const unread: Decoder<unknown> = nullableNever((raw) => raw);

/** Reads a body's envelope. Anything that is neither a reply nor an event is refused. */
export function decodeEnvelope(body: unknown): Envelope {
  const o = plainObject(body);
  const kind = field(o, 'kind', decodeEnvelopeKind, '');
  if (kind === 'event') {
    return { kind, event: field(o, 'event', decodeEventName, ''), seq: field(o, 'seq', int, ''), data: field(o, 'data', unread, '') };
  }
  const requestID = field(o, 'requestID', str, '');
  const hasResult = has(o, 'result');
  if (hasResult === has(o, 'error')) {
    throw new DecodeError('', hasResult ? 'a reply carries both a result and an error' : 'a reply carries neither a result nor an error');
  }
  if (hasResult) return { kind, requestID, result: field(o, 'result', unread, '') };
  return { kind, requestID, error: field(o, 'error', decodePhoneAppError, '') };
}

// MARK: - Session reference

const decodeLocalRef = obj<Extract<PhoneSessionRef, { kind: 'local' }>>({ kind: oneOf(['local']), terminalID: str }, {});
const decodeRemoteRef = obj<Extract<PhoneSessionRef, { kind: 'remote' }>>(
  { kind: oneOf(['remote']), provider: str, sessionID: str }, {});

export const decodePhoneSessionRef: Decoder<PhoneSessionRef> = (raw, path = '') => {
  const o = plainObject(raw, path);
  const kind = field(o, 'kind', oneOf(['local', 'remote']), path);
  return kind === 'local' ? decodeLocalRef(o, path) : decodeRemoteRef(o, path);
};

/**
 * A key that names one session, for maps keyed by session: `local:<terminalID>` or
 * `remote:<provider>/<sessionID>`, with `%` and `/` in the provider written as `%25` and
 * `%2F`, as `encodeURIComponent` writes them. So the first `/` always ends the provider, and no
 * two refs share a key. For a provider with neither character, such as `acme-cloud`, the key is
 * the daemon's own description of the session (`PhoneSessionRef.targetDescription`), which is
 * also a remote row's ID; a row is still found by its sessions' refs, never by this key.
 *
 * Only those two characters are escaped, not all that `encodeURIComponent` escapes, because it
 * throws on a lone surrogate, and a decoded string can hold one.
 */
export function refKey(ref: PhoneSessionRef): string {
  if (ref.kind === 'local') return `local:${ref.terminalID}`;
  const provider = ref.provider.replaceAll('%', '%25').replaceAll('/', '%2F');
  return `remote:${provider}/${ref.sessionID}`;
}

/** Whether `a` and `b` name the same session. */
export function sameRef(a: PhoneSessionRef, b: PhoneSessionRef): boolean {
  if (a.kind === 'local') return b.kind === 'local' && a.terminalID === b.terminalID;
  return b.kind === 'remote' && a.provider === b.provider && a.sessionID === b.sessionID;
}

// MARK: - Session list

export const decodePhoneCapability = obj<PhoneCapability>({ available: bool }, { reason: str });

export const decodePhoneCapabilities = obj<PhoneCapabilities>({
  transcript: decodePhoneCapability,
  send: decodePhoneCapability,
  answer: decodePhoneCapability,
  switchProfile: decodePhoneCapability,
  fork: decodePhoneCapability,
  model: decodePhoneCapability,
}, {});

export const decodePhoneStatusChip: Decoder<PhoneStatusChip> = oneOf(PHONE_STATUS_CHIPS);

export const decodePhoneStatus = obj<PhoneStatus>({ chip: decodePhoneStatusChip, changedAt: int }, { reason: str, untilAt: int });

export const decodePhoneAgent: Decoder<PhoneAgent> = oneOf(PHONE_AGENTS);

export const decodePhoneSession = obj<PhoneSession>(
  { ref: decodePhoneSessionRef, agent: decodePhoneAgent, tabName: str, status: decodePhoneStatus, capabilities: decodePhoneCapabilities },
  { profileName: str, profileID: str, model: str, openPromptID: str },
);

export const decodePhoneRowKind: Decoder<PhoneRowKind> = oneOf(PHONE_ROW_KINDS);

export const decodePhoneRow = obj<PhoneRow>({
  id: str,
  kind: decodePhoneRowKind,
  name: str,
  remote: bool,
  statusChangedAt: int,
  sessions: arr(decodePhoneSession),
}, {});

export const decodePhoneRowPlacement = obj<PhoneRowPlacement>({ id: str, depth: int }, {});

export const decodePhoneGroupKind: Decoder<PhoneGroupKind> = oneOf(PHONE_GROUP_KINDS);

export const decodePhoneGroupLayout = obj<PhoneGroupLayout>(
  { id: str, kind: decodePhoneGroupKind, name: str, rows: arr(decodePhoneRowPlacement) }, {});

// MARK: - sessions.subscribe and sessions.changed

export const decodeSessionsSubscribeParams = obj<SessionsSubscribeParams>({}, { stream: str, sinceSeq: int });

export const decodeSessionsSubscribeResult = obj<SessionsSubscribeResult>(
  { stream: str, seq: int, replayed: bool, omittedRows: int, more: bool },
  { layout: arr(decodePhoneGroupLayout), rows: arr(decodePhoneRow) },
);

export const decodeSessionsChangedData = obj<SessionsChangedData>(
  { rows: arr(decodePhoneRow), removedRowIDs: arr(str) },
  { layout: arr(decodePhoneGroupLayout) },
);

// MARK: - Transcript items

export const decodePhoneItemKind: Decoder<PhoneItemKind> = oneOf(PHONE_ITEM_KINDS);

export const decodePhoneItem = obj<PhoneItem>({ id: str, kind: decodePhoneItemKind, truncated: bool }, {
  at: int,
  text: str,
  toolName: str,
  target: str,
  toolStatus: str,
  added: int,
  removed: int,
  agentType: str,
  itemCount: int,
  sender: str,
});

export const decodeTranscriptPage = obj<TranscriptPage>(
  { items: arr(decodePhoneItem), reachedStart: bool, omittedItems: int }, { cursor: str });

// MARK: - Transcript requests

export const decodeTranscriptOpenParams = obj<TranscriptOpenParams>(
  { session: decodePhoneSessionRef, showDetails: bool, resume: bool }, {});

export const decodeTranscriptOpenResult = obj<TranscriptOpenResult>({ resumed: bool, seq: int }, { page: decodeTranscriptPage });

export const decodeTranscriptPageParams = obj<TranscriptPageParams>({ session: decodePhoneSessionRef, cursor: str }, {});

export const decodeTranscriptDetailPart: Decoder<TranscriptDetailPart> = oneOf(TRANSCRIPT_DETAIL_PARTS);

export const decodeTranscriptDetailParams = obj<TranscriptDetailParams>(
  { session: decodePhoneSessionRef, itemID: str, part: decodeTranscriptDetailPart, chunk: int }, {});

export const decodeTranscriptDetailResult = obj<TranscriptDetailResult>(
  { itemID: str, part: decodeTranscriptDetailPart, chunk: int, chunkCount: int, totalBytes: int, tooLarge: bool },
  { text: str, items: arr(decodePhoneItem) },
);

// MARK: - Transcript events

export const decodeTranscriptItemsData = obj<TranscriptItemsData>({ session: decodePhoneSessionRef, items: arr(decodePhoneItem) }, {});

export const decodeTranscriptResetData = obj<TranscriptResetData>(
  { session: decodePhoneSessionRef, reason: str, page: decodeTranscriptPage }, {});

// MARK: - Prompts

export const decodePendingPromptKind: Decoder<PendingPromptKind> = oneOf(PENDING_PROMPT_KINDS);

export const decodePhoneOption = obj<PhoneOption>({ label: str }, { description: str });

export const decodePhoneQuestion = obj<PhoneQuestion>(
  { text: str, multiSelect: bool, options: arr(decodePhoneOption) }, { header: str });

export const decodePhonePrompt = obj<PhonePrompt>(
  { id: str, kind: decodePendingPromptKind, targetTruncated: bool, allowAlways: bool },
  { toolName: str, summary: str, target: str, questions: arr(decodePhoneQuestion), suggestions: arr(str) },
);

export const decodePhoneAnsweredBy: Decoder<PhoneAnsweredBy> = oneOf(PHONE_ANSWERED_BY);

export const decodePhonePromptResolution = obj<PhonePromptResolution>(
  { promptID: str, answeredBy: decodePhoneAnsweredBy }, { deviceID: str });

export const decodePromptChangedData = obj<PromptChangedData>(
  { session: decodePhoneSessionRef, prompts: arr(decodePhonePrompt) },
  { resolved: arr(decodePhonePromptResolution) },
);

// MARK: - Actions

export const decodeMessageSendParams = obj<MessageSendParams>({ session: decodePhoneSessionRef, text: str }, {});

export const decodeActionOutcomeResult = obj<ActionOutcomeResult>({ outcome: str }, {});

export const decodePermissionDecision: Decoder<PermissionDecision> = oneOf(PERMISSION_DECISIONS);

const decodeQuestionAnswer = obj<Extract<PromptAnswer, { kind: 'question' }>>(
  { kind: oneOf(['question']), answers: record(str) }, {});
const decodePermissionAnswer = obj<Extract<PromptAnswer, { kind: 'permission' }>>(
  { kind: oneOf(['permission']), decision: decodePermissionDecision }, { message: str });

/** `{kind:'question', answers}` or `{kind:'permission', decision, message?}`, as `PromptAnswer.swift` codes it. */
export const decodePromptAnswer: Decoder<PromptAnswer> = (raw, path = '') => {
  const o = plainObject(raw, path);
  return field(o, 'kind', decodePendingPromptKind, path) === 'question' ? decodeQuestionAnswer(o, path) : decodePermissionAnswer(o, path);
};

export const decodePhonePromptAnswerParams = obj<PhonePromptAnswerParams>(
  { session: decodePhoneSessionRef, promptID: str, answer: decodePromptAnswer }, {});

/**
 * A string, read as `unknown` when it is not an outcome this build knows. This is the one enum
 * that does not refuse an unknown value, because Swift's `PromptAnswerOutcome` reads one the
 * same way: `unknown` never invites a second answer.
 */
export const decodePromptAnswerOutcome: Decoder<PromptAnswerOutcome> = (raw, path = '') => {
  const s = str(raw, path);
  return (PROMPT_ANSWER_OUTCOMES as readonly string[]).includes(s) ? (s as PromptAnswerOutcome) : 'unknown';
};

export const decodePromptAnswerResult = obj<PromptAnswerResult>({ outcome: decodePromptAnswerOutcome }, {});

export const decodePhoneProfile = obj<PhoneProfile>({ id: str, name: str, kind: str, isDefault: bool }, {});

export const decodeProfilesListResult = obj<ProfilesListResult>({ profiles: arr(decodePhoneProfile) }, {});

export const decodeSessionSwitchProfileParams = obj<SessionSwitchProfileParams>(
  { session: decodePhoneSessionRef, profileID: str }, {});

export const decodeSessionForkParams = obj<SessionForkParams>({ session: decodePhoneSessionRef }, { profileID: str });

export const decodeSessionRefResult = obj<SessionRefResult>({ session: decodePhoneSessionRef }, {});

export const decodeSessionSwitchProfileResult = obj<SessionSwitchProfileResult>(
  { session: decodePhoneSessionRef, parked: bool }, {});

export const decodeSessionSetModelParams = obj<SessionSetModelParams>({ session: decodePhoneSessionRef, model: str }, {});

export const decodePhoneWorktreeCreateParams = obj<PhoneWorktreeCreateParams>({ repoID: str, message: str }, {});

export const decodePhoneWorktreeCreateResult = obj<PhoneWorktreeCreateResult>(
  { worktreeID: str }, { session: decodePhoneSessionRef });

export const decodePhoneRemoteProvidersParams = obj<PhoneRemoteProvidersParams>({}, { repoID: str });

export const decodePhoneFormField = obj<PhoneFormField>(
  { name: str, type: str, required: bool }, { label: str, values: arr(str), prefill: str });

export const decodePhoneProvider = obj<PhoneProvider>(
  { name: str, available: bool, acceptsPrompt: bool, fields: arr(decodePhoneFormField) }, { reason: str });

export const decodePhoneRemoteProvidersResult = obj<PhoneRemoteProvidersResult>({ providers: arr(decodePhoneProvider) }, {});

export const decodePhoneRemoteCreateParams = obj<PhoneRemoteCreateParams>(
  { provider: str, repoID: str, message: str, strings: record(str), bools: record(bool) }, {});

/** `{}`. Any fields it holds are dropped. */
export const decodePhoneEmpty: Decoder<PhoneEmpty> = (raw, path = '') => {
  plainObject(raw, path);
  return {};
};

// MARK: - Method and event tables

const PARAMS: { readonly [M in Method]: Decoder<ParamsOf<M>> } = {
  'sessions.subscribe': decodeSessionsSubscribeParams,
  'transcript.open': decodeTranscriptOpenParams,
  'transcript.page': decodeTranscriptPageParams,
  'transcript.detail': decodeTranscriptDetailParams,
  'transcript.close': decodePhoneEmpty,
  'message.send': decodeMessageSendParams,
  'prompt.answer': decodePhonePromptAnswerParams,
  'profiles.list': decodePhoneEmpty,
  'session.switchProfile': decodeSessionSwitchProfileParams,
  'session.fork': decodeSessionForkParams,
  'session.setModel': decodeSessionSetModelParams,
  'worktree.create': decodePhoneWorktreeCreateParams,
  'remote.providers': decodePhoneRemoteProvidersParams,
  'remote.create': decodePhoneRemoteCreateParams,
};

const RESULTS: { readonly [M in Method]: Decoder<ResultOf<M>> } = {
  'sessions.subscribe': decodeSessionsSubscribeResult,
  'transcript.open': decodeTranscriptOpenResult,
  'transcript.page': decodeTranscriptPage,
  'transcript.detail': decodeTranscriptDetailResult,
  'transcript.close': decodePhoneEmpty,
  'message.send': decodeActionOutcomeResult,
  'prompt.answer': decodePromptAnswerResult,
  'profiles.list': decodeProfilesListResult,
  'session.switchProfile': decodeSessionSwitchProfileResult,
  'session.fork': decodeSessionRefResult,
  'session.setModel': decodeActionOutcomeResult,
  'worktree.create': decodePhoneWorktreeCreateResult,
  'remote.providers': decodePhoneRemoteProvidersResult,
  'remote.create': decodeSessionRefResult,
};

const EVENT_DATA: { readonly [E in EventName]: Decoder<DataOf<E>> } = {
  'sessions.changed': decodeSessionsChangedData,
  'transcript.append': decodeTranscriptItemsData,
  'transcript.update': decodeTranscriptItemsData,
  'transcript.reset': decodeTranscriptResetData,
  'prompt.changed': decodePromptChangedData,
};

/** Refuses a name the table does not hold, so a cast string never reaches a prototype's member. */
function known(table: object, name: string, what: string): void {
  if (!Object.hasOwn(table, name)) throw new DecodeError('', `unknown ${what} ${JSON.stringify(name)}`);
}

/** A request's params, decoded by its method. */
export function decodeParams<M extends Method>(method: M, raw: unknown): ParamsOf<M> {
  known(PARAMS, method, 'method');
  const decode: Decoder<ParamsOf<M>> = PARAMS[method];
  return decode(raw, '');
}

/** A reply's result, decoded by the method of the request it answers. */
export function decodeResult<M extends Method>(method: M, raw: unknown): ResultOf<M> {
  known(RESULTS, method, 'method');
  const decode: Decoder<ResultOf<M>> = RESULTS[method];
  return decode(raw, '');
}

/** An event's data, decoded by its name. */
export function decodeEventData<E extends EventName>(event: E, raw: unknown): DataOf<E> {
  known(EVENT_DATA, event, 'event');
  const decode: Decoder<DataOf<E>> = EVENT_DATA[event];
  return decode(raw, '');
}

/**
 * The app body of one request. Its params are rebuilt through their decoder, so the body holds
 * exactly the wire fields: a field the type does not name is dropped, an optional field set to
 * `undefined` is left out, and params of the wrong shape throw `DecodeError` before anything is
 * sent. A string-keyed map in the params comes back on a null prototype (see `record`); the
 * loader's JSON encoding and the port's structured clone both read it as a plain object.
 */
export function requestBody<M extends Method>(requestID: string, method: M, params: ParamsOf<M>): Record<string, unknown> {
  return { kind: 'request', requestID, method, params: decodeParams(method, params) };
}
