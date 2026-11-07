import { API_VERSIONS, RELAY_NAME, RELAY_VERSION, ROOM_ID_PATTERN, parseRole } from "./api";

export { Room } from "./room";

const ROOMS_PREFIX = "/v1/rooms/";
/** `/v1/rooms/<roomID>/presence` says whether the room's laptop is online. */
const PRESENCE_SUFFIX = "/presence";

const INFO_BODY = JSON.stringify({ name: RELAY_NAME, version: RELAY_VERSION, api: API_VERSIONS });

const NO_STORE_JSON = { "content-type": "application/json", "cache-control": "no-store" };
/** The loader's laptops list asks for presence from another origin. */
const ANY_ORIGIN = { "access-control-allow-origin": "*" };

function text(status: number, body: string, headers: Record<string, string> = {}): Response {
  return new Response(body + "\n", {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...headers },
  });
}

function methodNotAllowed(headers: Record<string, string> = {}): Response {
  return text(405, "Method Not Allowed", { allow: "GET", ...headers });
}

async function presence(env: Env, roomID: string): Promise<Response> {
  const { laptop } = await env.ROOM.get(env.ROOM.idFromName(roomID)).presence();
  return new Response(JSON.stringify({ laptop }), { headers: { ...NO_STORE_JSON, ...ANY_ORIGIN } });
}

export default {
  fetch(request, env) {
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
      // A cross-origin caller can read a refusal too.
      if (request.method !== "GET") return methodNotAllowed(ANY_ORIGIN);
      return presence(env, roomID);
    }

    if (request.method !== "GET") return methodNotAllowed();
    if (parseRole(url) === null) return text(400, "Bad Request: role must be laptop or phone");
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return text(426, "Upgrade Required", { upgrade: "websocket" });
    }

    // Only now does the Worker touch a Durable Object for a socket.
    return env.ROOM.get(env.ROOM.idFromName(roomID)).fetch(request);
  },
} satisfies ExportedHandler<Env>;
