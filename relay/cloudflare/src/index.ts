import { API_VERSIONS, RELAY_NAME, RELAY_VERSION, ROOM_ID_PATTERN, parseRole } from "./api";

export { Room } from "./room";

const ROOMS_PREFIX = "/v1/rooms/";
/** `/v1/rooms/<roomID>/presence` says whether the room's laptop is online. */
const PRESENCE_SUFFIX = "/presence";

const INFO_BODY = JSON.stringify({ name: RELAY_NAME, version: RELAY_VERSION, api: API_VERSIONS });

const NO_STORE_JSON = { "content-type": "application/json", "cache-control": "no-store" };

function text(status: number, body: string, headers: Record<string, string> = {}): Response {
  return new Response(body + "\n", {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...headers },
  });
}

function methodNotAllowed(): Response {
  return text(405, "Method Not Allowed", { allow: "GET" });
}

async function presence(env: Env, roomID: string): Promise<Response> {
  const { laptop } = await env.ROOM.get(env.ROOM.idFromName(roomID)).presence();
  return new Response(JSON.stringify({ laptop }), { headers: NO_STORE_JSON });
}

/**
 * Every HTTP response the relay sends lets a page on any origin read it. The
 * loader's laptops list asks for presence from another origin, and a refusal
 * it can read is a 404 or a 405 rather than an opaque CORS error. This exposes
 * nothing: the relay sets no cookies and reads no credentials, so no response
 * depends on who asks. A 101 is left as it is, since CORS never governs a
 * WebSocket upgrade.
 */
function readableFromAnyOrigin(response: Response): Response {
  if (response.status === 101) return response;
  // A copy, so the headers can be set whatever made the response: one that
  // came back through `fetch`, as a Durable Object's does, may hold immutable ones.
  const readable = new Response(response.body, response);
  readable.headers.set("access-control-allow-origin", "*");
  return readable;
}

function route(request: Request, env: Env): Response | Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (path === "/") {
    if (request.method !== "GET") return methodNotAllowed();
    return text(200, `TBD relay ${RELAY_VERSION} is running. Pair a phone from the TBD app.`);
  }

  if (path === "/v1/info") {
    if (request.method !== "GET") return methodNotAllowed();
    return new Response(INFO_BODY, { headers: NO_STORE_JSON });
  }

  // A malformed room ID is a missing resource, whatever the method, role or headers.
  if (!path.startsWith(ROOMS_PREFIX)) return text(404, "Not Found");
  const rest = path.slice(ROOMS_PREFIX.length);
  const isPresence = rest.endsWith(PRESENCE_SUFFIX);
  const roomID = isPresence ? rest.slice(0, -PRESENCE_SUFFIX.length) : rest;
  if (!ROOM_ID_PATTERN.test(roomID)) return text(404, "Not Found");

  if (isPresence) {
    // Presence never upgrades, so the role and the Upgrade header play no part.
    if (request.method !== "GET") return methodNotAllowed();
    return presence(env, roomID);
  }

  if (request.method !== "GET") return methodNotAllowed();
  if (parseRole(url) === null) return text(400, "Bad Request: role must be laptop or phone");
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return text(426, "Upgrade Required", { upgrade: "websocket" });
  }

  // Only now does the Worker touch a Durable Object for a socket.
  return env.ROOM.get(env.ROOM.idFromName(roomID)).fetch(request);
}

export default {
  async fetch(request, env) {
    return readableFromAnyOrigin(await route(request, env));
  },
} satisfies ExportedHandler<Env>;
