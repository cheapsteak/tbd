import { DurableObject } from "cloudflare:workers";
import {
  CLOSE_REPLACED,
  CLOSE_TOO_LARGE,
  MAX_FRAME_BYTES,
  PING,
  PONG,
  SIGNAL,
  isRole,
  otherRole,
  parseRole,
  type Role,
} from "./api";

/**
 * One room pairs one `laptop` socket with one `phone` socket. The role lives in
 * the socket's tag, so the object keeps nothing in memory between events and
 * can hibernate between frames. The relay stores nothing.
 *
 * - Join: a new socket replaces any open socket of its role (closed with 4000).
 *   When the other role is present, both sides get `peer-joined`, which always
 *   means "a new peer socket: reset your channel". A phone that finds no laptop
 *   gets `peer-absent`; a laptop alone gets nothing.
 * - Message: binary frames up to MAX_FRAME_BYTES pass unchanged to the other
 *   role, or are dropped when it is absent. Text from a client is never
 *   forwarded, so no client can forge a relay signal; `ping` is answered by the
 *   runtime's auto-response. A larger frame closes its sender with 1009, and
 *   the other role gets `peer-left` at once.
 * - Leave: when the last open socket of a role goes, the other role gets `peer-left`.
 * - Presence: says whether a laptop socket is open, without joining.
 *
 * "Open" means live: `readyState` OPEN and not marked closing. The relay marks
 * a socket before it closes one (4000 or 1009), so a socket the relay is
 * closing never counts as open, even if after a hibernation wake its
 * `readyState` read OPEN: its frames are dropped, it never holds back the other
 * role's `peer-left`, and presence does not count it.
 */
export class Room extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Set on every construction, so it is in place after each wake. The runtime
    // answers `ping` itself, without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  // Synchronous on purpose: with no `await`, a join cannot interleave with another event.
  fetch(request: Request): Response {
    const role = parseRole(new URL(request.url));
    if (role === null) return new Response("Bad Request\n", { status: 400 });

    for (const old of this.openSockets(role)) markAndClose(old, CLOSE_REPLACED);

    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [role]);

    const peers = this.openSockets(otherRole(role));
    if (peers.length > 0) {
      for (const peer of peers) send(peer, SIGNAL.peerJoined);
      send(server, SIGNAL.peerJoined);
    } else if (role === "phone") {
      send(server, SIGNAL.peerAbsent);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    // A socket the relay is closing (replaced, or too large) sends nothing more.
    if (!isLive(ws)) return;
    // Text is never forwarded. Checking for ArrayBuffer rather than for string
    // also means no other binary type could skip the size check below.
    if (!(message instanceof ArrayBuffer)) return;
    if (message.byteLength > MAX_FRAME_BYTES) {
      markAndClose(ws, CLOSE_TOO_LARGE);
      // Signal now rather than when the client answers the Close, which it may
      // never do. The close event repeats the `peer-left`, which receivers ignore.
      this.leave(ws);
      return;
    }
    const role = this.roleOf(ws);
    if (role === null) return;
    for (const peer of this.openSockets(otherRole(role))) send(peer, message);
  }

  /**
   * Whether the room's laptop is online, by the same rule signalling uses. An
   * RPC from the Worker: it accepts, closes, tags and sends to no socket, so
   * asking displaces no one.
   */
  presence(): { laptop: boolean } {
    return { laptop: this.openSockets("laptop").length > 0 };
  }

  // Neither handler calls `ws.close()`: the runtime answers the Close frame
  // itself, and closing with 1005 or 1006 would throw.
  webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): void {
    this.leave(ws);
  }

  webSocketError(ws: WebSocket, _error: unknown): void {
    this.leave(ws);
  }

  /** The live sockets of `role`, leaving out `except`. */
  private openSockets(role: Role, except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(role).filter((ws) => ws !== except && isLive(ws));
  }

  private roleOf(ws: WebSocket): Role | null {
    const tag = this.ctx.getTags(ws)[0];
    return isRole(tag) ? tag : null;
  }

  /**
   * `peer-left` goes out only when no open socket of the role remains, so a
   * socket closed because a newer one replaced it causes none.
   */
  private leave(ws: WebSocket): void {
    const role = this.roleOf(ws);
    if (role === null) return;
    if (this.openSockets(role, ws).length > 0) return;
    for (const peer of this.openSockets(otherRole(role))) send(peer, SIGNAL.peerLeft);
  }
}

/**
 * The mark on a socket the relay is closing. It is the socket's attachment,
 * which the runtime keeps with the socket across hibernation, so the room tells
 * a closing socket from a live one by the mark as well as by `readyState`.
 *
 * An attachment is allowed under the rule that the relay stores nothing. The
 * rule keeps out the object's own SQLite database, alarms, timers and outbound
 * requests. An attachment is none of them: it holds one flag and no content,
 * it lives only with its socket, and it goes when the socket goes.
 */
const CLOSING_MARK = { closing: true } as const;

/** Marks `ws` as a socket the relay is closing. Exported so tests can mark a socket without closing it. */
export function markClosing(ws: WebSocket): void {
  try {
    ws.serializeAttachment(CLOSING_MARK);
  } catch {
    // The socket closed meanwhile; its `readyState` already leaves it out.
  }
}

/** Whether `ws` carries the closing mark. */
export function isMarkedClosing(ws: WebSocket): boolean {
  const attachment: unknown = ws.deserializeAttachment();
  return typeof attachment === "object" && attachment !== null && "closing" in attachment && attachment.closing === true;
}

/** Open by `readyState` and not marked closing. The mark is read only for an open socket. */
function isLive(ws: WebSocket): boolean {
  return ws.readyState === WebSocket.OPEN && !isMarkedClosing(ws);
}

/** Marks `ws` closing, then closes it, so it stays left out whatever its `readyState` reads later. */
function markAndClose(ws: WebSocket, { code, reason }: { code: number; reason: string }): void {
  markClosing(ws);
  try {
    ws.close(code, reason);
  } catch {
    // The socket closed meanwhile.
  }
}

function send(ws: WebSocket, message: string | ArrayBuffer): void {
  try {
    ws.send(message);
  } catch {
    // The socket closed between the check and the send; its own close event follows.
  }
}
