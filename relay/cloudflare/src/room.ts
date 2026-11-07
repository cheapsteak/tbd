import { DurableObject } from "cloudflare:workers";
import { PING, PONG, parseRole } from "./api";

/**
 * One room pairs one `laptop` socket with one `phone` socket. The role lives in
 * the socket's tag, so the object keeps nothing in memory between events and
 * can hibernate between frames. The relay stores nothing.
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

    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [role]);
    return new Response(null, { status: 101, webSocket: client });
  }
}
