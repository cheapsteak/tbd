// An in-memory relay with relay API v1's room rules (plan 2's accepted changes 1–4), plus
// test hooks. It delivers synchronously into each socket's sink; fake-websocket.js and the
// e2e server make delivery asynchronous on the phone's side.

const ROOM_SOCKET_PATH = /^\/v1\/rooms\/([A-Za-z0-9_-]{43})\?role=(phone|laptop)$/;
const PRESENCE_PATH = /^\/v1\/rooms\/([A-Za-z0-9_-]{43})\/presence$/;
const MAX_FRAME_BYTES = 65_536;
const CLOSE_REPLACED = { code: 4000, reason: 'replaced' };
const CLOSE_TOO_LARGE = { code: 1009, reason: 'frame too large' };
const NO_STATUS = 1005;

/**
 * What the relay calls to reach one socket's client.
 * @typedef {{ binary(bytes: Uint8Array): void, text(str: string): void, close(code: number, reason: string): void }} RelaySink
 */

/**
 * A client's end of one socket. `close` echoes the close back through the client's sink, as a
 * server answers a close frame, except in a black-holed room.
 * @typedef {{ send(data: string | ArrayBufferLike | ArrayBufferView): void, close(code?: number, reason?: string): void }} RelayHandle
 */

/**
 * A changed frame, several frames, or null to drop it.
 * @typedef {(frame: Uint8Array) => Uint8Array | Uint8Array[] | null} TamperFn
 */

/** @typedef {'phone' | 'laptop'} Role */
/** @typedef {{ role: Role, sink: RelaySink, open: boolean }} Member */
/** @typedef {{ phone: Member | null, laptop: Member | null, blackHole: boolean, tamper: TamperFn | null }} Room */

/**
 * @typedef {object} FakeRelay
 * @property {(path: string, sink: RelaySink) => RelayHandle | null} connect
 *   `path` is `/v1/rooms/<43 base64url>?role=phone|laptop`; anything else is null, which the
 *   caller maps to 404.
 * @property {(path: string) => { status: number, body?: { laptop: boolean } }} presence
 *   `GET /v1/rooms/<roomID>/presence`. It never joins, displaces or touches a socket.
 * @property {(room: string, on: boolean) => void} blackHole
 *   While on, nothing reaches or leaves any socket in the room: no signal, frame, `pong` or
 *   close, not even the echo of a client's own close. Joins and leaves still change who is
 *   in the room.
 * @property {(room: string, fn: TamperFn | null) => void} tamper
 *   Passes each laptop-to-phone binary frame through `fn`.
 * @property {{ pings: Map<string, number>, phoneJoins: Map<string, number>,
 *              laptopJoins: Map<string, number>, presence: Map<string, number>,
 *              swallowed: Map<string, number> }} stats
 *   Counts per room. `swallowed` counts what a black hole took from a room's sockets: each
 *   text or binary message a client sent while the room was black-holed.
 */

/** @returns {FakeRelay} */
export function createFakeRelay() {
  /** @type {Map<string, Room>} */
  const rooms = new Map();
  const stats = {
    /** @type {Map<string, number>} */ pings: new Map(),
    /** @type {Map<string, number>} */ phoneJoins: new Map(),
    /** @type {Map<string, number>} */ laptopJoins: new Map(),
    /** @type {Map<string, number>} */ presence: new Map(),
    /** @type {Map<string, number>} */ swallowed: new Map(),
  };

  /** @param {string} id */
  function roomFor(id) {
    let room = rooms.get(id);
    if (room === undefined) {
      room = { phone: null, laptop: null, blackHole: false, tamper: null };
      rooms.set(id, room);
    }
    return room;
  }

  /**
   * @param {Room} room
   * @param {Member} member
   * @param {(sink: RelaySink) => void} deliver
   */
  function reach(room, member, deliver) {
    if (!room.blackHole) deliver(member.sink);
  }

  /**
   * The member stops being a socket of the room. When it was the room's socket for its role,
   * the other role gets `peer-left`.
   * @param {Room} room
   * @param {Member} member
   */
  function remove(room, member) {
    member.open = false;
    if (room[member.role] !== member) return;
    room[member.role] = null;
    const other = room[otherRole(member.role)];
    if (other !== null) reach(room, other, (sink) => sink.text('peer-left'));
  }

  return {
    connect(path, sink) {
      const match = ROOM_SOCKET_PATH.exec(path);
      if (match === null) return null;
      const id = match[1];
      const role = /** @type {Role} */ (match[2]);
      const room = roomFor(id);
      bump(role === 'phone' ? stats.phoneJoins : stats.laptopJoins, id);

      /** @type {Member} */
      const member = { role, sink, open: true };
      const replaced = room[role];
      room[role] = member;
      if (replaced !== null) {
        // A replaced socket causes no peer-left, and its later frames are dropped.
        replaced.open = false;
        reach(room, replaced, (s) => s.close(CLOSE_REPLACED.code, CLOSE_REPLACED.reason));
      }
      const other = room[otherRole(role)];
      if (other !== null) {
        reach(room, member, (s) => s.text('peer-joined'));
        reach(room, other, (s) => s.text('peer-joined'));
      } else if (role === 'phone') {
        reach(room, member, (s) => s.text('peer-absent'));
      }

      return {
        send(data) {
          if (!member.open) return;
          if (room.blackHole) {
            bump(stats.swallowed, id);
            return;
          }
          if (typeof data === 'string') {
            // Client text is never forwarded; only `ping` is answered.
            if (data === 'ping') {
              bump(stats.pings, id);
              member.sink.text('pong');
            }
            return;
          }
          const frame = copyBytes(data);
          if (frame.length > MAX_FRAME_BYTES) {
            remove(room, member);
            member.sink.close(CLOSE_TOO_LARGE.code, CLOSE_TOO_LARGE.reason);
            return;
          }
          const peer = room[otherRole(role)];
          if (peer === null) return;
          if (role === 'laptop' && room.tamper !== null) {
            const result = room.tamper(frame.slice());
            const frames = result === null ? [] : Array.isArray(result) ? result : [result];
            for (const out of frames) peer.sink.binary(copyBytes(out));
          } else {
            peer.sink.binary(frame);
          }
        },
        close(code = NO_STATUS, reason = '') {
          if (!member.open) return;
          remove(room, member);
          // The server's half of the close handshake, which a black hole swallows.
          reach(room, member, (s) => s.close(code, reason));
        },
      };
    },

    presence(path) {
      const match = PRESENCE_PATH.exec(path.split('?')[0]);
      if (match === null) return { status: 404 };
      const id = match[1];
      bump(stats.presence, id);
      return { status: 200, body: { laptop: (rooms.get(id)?.laptop ?? null) !== null } };
    },

    blackHole(room, on) {
      roomFor(room).blackHole = Boolean(on);
    },

    tamper(room, fn) {
      roomFor(room).tamper = fn ?? null;
    },

    stats,
  };
}

/**
 * @param {Role} role
 * @returns {Role}
 */
function otherRole(role) {
  return role === 'phone' ? 'laptop' : 'phone';
}

/**
 * @param {Map<string, number>} counter
 * @param {string} room
 */
function bump(counter, room) {
  counter.set(room, (counter.get(room) ?? 0) + 1);
}

/**
 * A plain Uint8Array copy of binary data (a Node Buffer included).
 * @param {ArrayBufferLike | ArrayBufferView} data
 * @returns {Uint8Array}
 */
function copyBytes(data) {
  if (ArrayBuffer.isView(data)) {
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice();
  }
  return new Uint8Array(/** @type {ArrayBufferLike} */ (data)).slice();
}
