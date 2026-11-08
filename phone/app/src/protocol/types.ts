/**
 * The app protocol's wire types (spec section 4.4). Each type carries the name of its Swift twin
 * in `Sources/TBDDaemon/PhoneBridge/App/PhoneAppMessages.swift` (or `PhoneAppProtocol.swift`,
 * or `Sources/TBDShared/PromptAnswer.swift`), so a reader can grep across the two. A Swift
 * optional is an optional field here: the daemon leaves a nil out of the JSON and never writes
 * `null`, and the decoders in `wire.ts` keep an absent field absent.
 *
 * These are plain data, decoded from what the laptop sent. Render their fields one by one.
 * Never spread a decoded value onto JSX props: a spread passes every key it holds, and a key
 * such as React's raw-HTML prop would reach the DOM.
 *
 * Identifiers the daemon holds as a `UUID` (terminal, profile, repo, worktree and device IDs)
 * are strings here. The daemon writes them in upper case.
 */

// MARK: - Names

/** The 14 requests, by their wire names (`PhoneAppMethod`). */
export type Method =
  | 'sessions.subscribe'
  | 'transcript.open'
  | 'transcript.page'
  | 'transcript.detail'
  | 'transcript.close'
  | 'message.send'
  | 'prompt.answer'
  | 'profiles.list'
  | 'session.switchProfile'
  | 'session.fork'
  | 'session.setModel'
  | 'worktree.create'
  | 'remote.providers'
  | 'remote.create';

/** The 5 events, by their wire names (`PhoneAppEventName`). */
export type EventName = 'sessions.changed' | 'transcript.append' | 'transcript.update' | 'transcript.reset' | 'prompt.changed';

/** The closed list of reply error codes (`PhoneAppErrorCode`). */
export type ErrorCode =
  | 'phone_control_off'
  | 'bad_request'
  | 'unknown_method'
  | 'not_found'
  | 'unsupported'
  | 'refused'
  | 'not_open'
  | 'stale_cursor'
  | 'unavailable'
  | 'internal';

/** `{}`: the params of a request that takes none, and the result of one that returns none. */
export type PhoneEmpty = Record<string, never>;

/**
 * A reply's error: a code and a plain message for the phone to show. The code is a string, not
 * an `ErrorCode`, so a reply the app does not expect still reaches it; `isErrorCode` in
 * `wire.ts` narrows it.
 */
export type PhoneAppError = { code: string; message: string };

// MARK: - Session reference

/** Which session a request or event is about: a local terminal, or a remote session. */
export type PhoneSessionRef =
  | { kind: 'local'; terminalID: string }
  | { kind: 'remote'; provider: string; sessionID: string };

// MARK: - Session list

/** Whether a session supports one action, and if not, why not. */
export type PhoneCapability = { available: boolean; reason?: string };

export type PhoneCapabilities = {
  transcript: PhoneCapability;
  send: PhoneCapability;
  answer: PhoneCapability;
  switchProfile: PhoneCapability;
  fork: PhoneCapability;
  model: PhoneCapability;
};

/** A session's status, as the laptop sidebar shows it. */
export type PhoneStatusChip = 'waitingForYou' | 'working' | 'idle' | 'parked' | 'rateLimited' | 'error' | 'exited' | 'unknown';

export type PhoneStatus = {
  chip: PhoneStatusChip;
  /** When the chip last changed, in Unix milliseconds. */
  changedAt: number;
  /** Why, for an error or a rate limit. */
  reason?: string;
  /** When a rate limit lifts, in Unix milliseconds. */
  untilAt?: number;
};

export type PhoneAgent = 'claude' | 'codex' | 'remote';

export type PhoneSession = {
  ref: PhoneSessionRef;
  agent: PhoneAgent;
  tabName: string;
  status: PhoneStatus;
  profileName?: string;
  /** Matches `PhoneProfile.id`. Absent when the session has no model profile. */
  profileID?: string;
  /** The session's current model name, when the daemon knows it. */
  model?: string;
  capabilities: PhoneCapabilities;
  /** The prompt waiting for an answer, if any. */
  openPromptID?: string;
};

/** `PhoneRow.kind`. A `String` in Swift, with these two values. */
export type PhoneRowKind = 'worktree' | 'remoteSession';

/** One row of the sessions list: a worktree with its sessions, or one remote session. */
export type PhoneRow = {
  id: string;
  kind: PhoneRowKind;
  name: string;
  remote: boolean;
  /** The newest `status.changedAt` among the row's sessions, in Unix milliseconds. */
  statusChangedAt: number;
  sessions: PhoneSession[];
};

/** A row's place in its group, in the laptop sidebar's order. */
export type PhoneRowPlacement = { id: string; depth: number };

/** `PhoneGroupLayout.kind`. A `String` in Swift, with these three values. */
export type PhoneGroupKind = 'scratch' | 'repo' | 'provider';

/** One group of the laptop sidebar, with its rows in order. */
export type PhoneGroupLayout = { id: string; kind: PhoneGroupKind; name: string; rows: PhoneRowPlacement[] };

// MARK: - sessions.subscribe and sessions.changed

export type SessionsSubscribeParams = {
  /** The stream the phone saw before. */
  stream?: string;
  /** The last `seq` the phone saw on that stream. */
  sinceSeq?: number;
};

export type SessionsSubscribeResult = {
  stream: string;
  seq: number;
  /** True when the missed events were replayed in place of a snapshot. */
  replayed: boolean;
  layout?: PhoneGroupLayout[];
  rows?: PhoneRow[];
  omittedRows: number;
  more: boolean;
};

export type SessionsChangedData = {
  /** Present only when the layout changed. */
  layout?: PhoneGroupLayout[];
  rows: PhoneRow[];
  removedRowIDs: string[];
};

// MARK: - Transcript items

export type PhoneItemKind = 'user' | 'assistant' | 'tool' | 'fileEdit' | 'subagent' | 'slash' | 'peer' | 'thinking' | 'systemNote';

/** One transcript row, shaped for the phone (spec section 7). */
export type PhoneItem = {
  id: string;
  kind: PhoneItemKind;
  /** Unix milliseconds. */
  at?: number;
  text?: string;
  /** True when `text` was cut and the rest is behind `transcript.detail`. */
  truncated: boolean;
  toolName?: string;
  target?: string;
  /** `running`, `ok` or `error`. A `String` in Swift. */
  toolStatus?: string;
  added?: number;
  removed?: number;
  agentType?: string;
  itemCount?: number;
  sender?: string;
};

export type TranscriptPage = {
  items: PhoneItem[];
  /** Asks for the page before this one. Absent once the start is reached. */
  cursor?: string;
  reachedStart: boolean;
  omittedItems: number;
};

// MARK: - Transcript requests

export type TranscriptOpenParams = { session: PhoneSessionRef; showDetails: boolean; resume: boolean };

export type TranscriptOpenResult = { resumed: boolean; seq: number; page?: TranscriptPage };

export type TranscriptPageParams = { session: PhoneSessionRef; cursor: string };

export type TranscriptDetailPart = 'input' | 'result' | 'text' | 'subagent';

export type TranscriptDetailParams = { session: PhoneSessionRef; itemID: string; part: TranscriptDetailPart; chunk: number };

export type TranscriptDetailResult = {
  itemID: string;
  part: TranscriptDetailPart;
  chunk: number;
  chunkCount: number;
  totalBytes: number;
  tooLarge: boolean;
  text?: string;
  items?: PhoneItem[];
};

// MARK: - Transcript events

/** The data of `transcript.append` and `transcript.update`. */
export type TranscriptItemsData = { session: PhoneSessionRef; items: PhoneItem[] };

export type TranscriptResetData = {
  session: PhoneSessionRef;
  /** `rollover`, `rewrite` or `generation`. A `String` in Swift. */
  reason: string;
  page: TranscriptPage;
};

// MARK: - Prompts

/** A prompt's kind, and the kind of answer that fits it (`PendingPromptKind`). */
export type PendingPromptKind = 'question' | 'permission';

export type PhoneOption = { label: string; description?: string };

export type PhoneQuestion = { text: string; header?: string; multiSelect: boolean; options: PhoneOption[] };

export type PhonePrompt = {
  id: string;
  /** A `String` in Swift, with the values of `PendingPromptKind`. */
  kind: PendingPromptKind;
  toolName?: string;
  summary?: string;
  target?: string;
  targetTruncated: boolean;
  questions?: PhoneQuestion[];
  suggestions?: string[];
  allowAlways: boolean;
};

/** Where a closed prompt was answered. */
export type PhoneAnsweredBy = 'phone' | 'laptop' | 'unknown';

/** A prompt that closed since the last `prompt.changed` for its session. */
export type PhonePromptResolution = {
  promptID: string;
  answeredBy: PhoneAnsweredBy;
  /** The answering phone, when `answeredBy` is `phone` and TBD can tell which phone it was. */
  deviceID?: string;
};

export type PromptChangedData = {
  session: PhoneSessionRef;
  /** The session's open prompts. */
  prompts: PhonePrompt[];
  /** Absent when no prompt closed. */
  resolved?: PhonePromptResolution[];
};

// MARK: - Actions

export type MessageSendParams = { session: PhoneSessionRef; text: string };

/** How a send ended: `sent`, `woken` or `unknown`. A `String` in Swift. */
export type ActionOutcomeResult = { outcome: string };

/** The decision a permission prompt can take. */
export type PermissionDecision = 'allow' | 'allow_always' | 'deny';

/**
 * An answer to an open prompt. A question answer maps each question's text to its value; a
 * permission answer is a decision, with an optional message on a deny.
 */
export type PromptAnswer =
  | { kind: 'question'; answers: Record<string, string> }
  | { kind: 'permission'; decision: PermissionDecision; message?: string };

export type PhonePromptAnswerParams = { session: PhoneSessionRef; promptID: string; answer: PromptAnswer };

/**
 * How an answer ended. As in Swift, an outcome this build does not know decodes as `unknown`,
 * the only reading that never invites a second answer.
 */
export type PromptAnswerOutcome = 'delivered' | 'already_resolved' | 'unknown';

export type PromptAnswerResult = { outcome: PromptAnswerOutcome };

export type ProfilesListResult = { profiles: PhoneProfile[] };

/** A model profile, never with a token or other secret. */
export type PhoneProfile = {
  id: string;
  name: string;
  /** The credential kind's raw value, such as `oauth` or `apiKey`. A `String` in Swift. */
  kind: string;
  isDefault: boolean;
};

export type SessionSwitchProfileParams = { session: PhoneSessionRef; profileID: string };

export type SessionForkParams = {
  session: PhoneSessionRef;
  /** Absent forks under the session's own profile. */
  profileID?: string;
};

/** The session an action produced or restarted. */
export type SessionRefResult = { session: PhoneSessionRef };

export type SessionSetModelParams = { session: PhoneSessionRef; model: string };

export type PhoneWorktreeCreateParams = { repoID: string; message: string };

export type PhoneWorktreeCreateResult = {
  worktreeID: string;
  /** Absent when the session was not ready in time. */
  session?: PhoneSessionRef;
};

export type PhoneRemoteProvidersParams = {
  /** The repo whose values prefill the providers' forms. */
  repoID?: string;
};

export type PhoneRemoteProvidersResult = { providers: PhoneProvider[] };

export type PhoneProvider = { name: string; available: boolean; reason?: string; acceptsPrompt: boolean; fields: PhoneFormField[] };

/** One field of a provider's create form. */
export type PhoneFormField = {
  name: string;
  /** The provider's field type, such as `string`, `text`, `bool`, `int` or `enum`, passed on as the provider gave it. */
  type: string;
  label?: string;
  required: boolean;
  /** The choices of an `enum` field. */
  values?: string[];
  prefill?: string;
};

export type PhoneRemoteCreateParams = {
  provider: string;
  repoID: string;
  message: string;
  strings: Record<string, string>;
  bools: Record<string, boolean>;
};

// MARK: - Methods and events

/** Each request's params and result, as `PhoneAppMessages.swift` pairs them. */
export interface MethodShapes {
  'sessions.subscribe': { params: SessionsSubscribeParams; result: SessionsSubscribeResult };
  'transcript.open': { params: TranscriptOpenParams; result: TranscriptOpenResult };
  'transcript.page': { params: TranscriptPageParams; result: TranscriptPage };
  'transcript.detail': { params: TranscriptDetailParams; result: TranscriptDetailResult };
  'transcript.close': { params: PhoneEmpty; result: PhoneEmpty };
  'message.send': { params: MessageSendParams; result: ActionOutcomeResult };
  'prompt.answer': { params: PhonePromptAnswerParams; result: PromptAnswerResult };
  'profiles.list': { params: PhoneEmpty; result: ProfilesListResult };
  'session.switchProfile': { params: SessionSwitchProfileParams; result: SessionRefResult };
  'session.fork': { params: SessionForkParams; result: SessionRefResult };
  'session.setModel': { params: SessionSetModelParams; result: ActionOutcomeResult };
  'worktree.create': { params: PhoneWorktreeCreateParams; result: PhoneWorktreeCreateResult };
  'remote.providers': { params: PhoneRemoteProvidersParams; result: PhoneRemoteProvidersResult };
  'remote.create': { params: PhoneRemoteCreateParams; result: SessionRefResult };
}

/** Each event's data. */
export interface EventShapes {
  'sessions.changed': SessionsChangedData;
  'transcript.append': TranscriptItemsData;
  'transcript.update': TranscriptItemsData;
  'transcript.reset': TranscriptResetData;
  'prompt.changed': PromptChangedData;
}

export type ParamsOf<M extends Method> = MethodShapes[M]['params'];
export type ResultOf<M extends Method> = MethodShapes[M]['result'];
export type DataOf<E extends EventName> = EventShapes[E];

/** One decoded event, its data typed by its name. */
export type AppEvent = { [E in EventName]: { event: E; seq: number; data: DataOf<E> } }[EventName];

// The compiler checks that the two tables above name exactly the methods and events.
type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
type Holds<T extends true> = T;
export type MethodShapesCoverMethods = Holds<Same<keyof MethodShapes, Method>>;
export type EventShapesCoverEvents = Holds<Same<keyof EventShapes, EventName>>;
