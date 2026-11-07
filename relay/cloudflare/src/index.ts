import { API_VERSIONS, RELAY_NAME, RELAY_VERSION, ROOM_ID_PATTERN, parseRole } from "./api";

export { Room } from "./room";

const ROOMS_PREFIX = "/v1/rooms/";

const INFO_BODY = JSON.stringify({ name: RELAY_NAME, version: RELAY_VERSION, api: API_VERSIONS });

function text(status: number, body: string, headers: Record<string, string> = {}): Response {
  return new Response(body + "\n", {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...headers },
  });
}

function methodNotAllowed(): Response {
  return text(405, "Method Not Allowed", { allow: "GET" });
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
      return new Response(INFO_BODY, {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }

    // A malformed room ID is a missing resource, whatever the method, role or headers.
    if (!path.startsWith(ROOMS_PREFIX)) return text(404, "Not Found");
    const roomID = path.slice(ROOMS_PREFIX.length);
    if (!ROOM_ID_PATTERN.test(roomID)) return text(404, "Not Found");

    if (request.method !== "GET") return methodNotAllowed();
    if (parseRole(url) === null) return text(400, "Bad Request: role must be laptop or phone");
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return text(426, "Upgrade Required", { upgrade: "websocket" });
    }

    // Only now does the Worker touch a Durable Object.
    return env.ROOM.get(env.ROOM.idFromName(roomID)).fetch(request);
  },
} satisfies ExportedHandler<Env>;
