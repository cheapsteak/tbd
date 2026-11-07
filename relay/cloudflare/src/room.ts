import { DurableObject } from "cloudflare:workers";
import {
  CLOSE_REPLACED,
  CLOSE_TOO_LARGE,
  MAX_FRAME_BYTES,
  PING,
  PONG,
  SIGNAL,
  otherRole,
  parseRole,
  type Role,
} from "./api";

/** `WebSocket.readyState` of an open socket. */
const OPEN = 1;

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

    for (const old of this.openSockets(role)) {
      try {
        old.close(CLOSE_REPLACED.code, CLOSE_REPLACED.reason);
      } catch {
        // Closed meanwhile.
      }
    }

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
    if (ws.readyState !== OPEN) return;
    // Text is never forwarded. Checking for ArrayBuffer rather than for string
    // also means no other binary type could skip the size check below.
    if (!(message instanceof ArrayBuffer)) return;
    if (message.byteLength > MAX_FRAME_BYTES) {
      try {
        ws.close(CLOSE_TOO_LARGE.code, CLOSE_TOO_LARGE.reason);
      } catch {
        // Closed meanwhile.
      }
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

  /** The open sockets of `role`, leaving out `except`. */
  private openSockets(role: Role, except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(role).filter((ws) => ws !== except && ws.readyState === OPEN);
  }

  private roleOf(ws: WebSocket): Role | null {
    const tag = this.ctx.getTags(ws)[0];
    return tag === "laptop" || tag === "phone" ? tag : null;
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

function send(ws: WebSocket, message: string | ArrayBuffer): void {
  try {
    ws.send(message);
  } catch {
    // The socket closed between the check and the send; its own close event follows.
  }
}
