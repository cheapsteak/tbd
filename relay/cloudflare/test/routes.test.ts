import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { RELAY_VERSION } from "../src/api";
import worker from "../src/index";
import { BASE_URL, LAPTOP_OFFLINE, connect, newRoomID } from "./helpers";

interface Drained {
  status: number;
  headers: Headers;
  body: string;
}

/** Fetch through the Worker and drain the body. */
async function request(path: string, init?: RequestInit): Promise<Drained> {
  const res = await exports.default.fetch(BASE_URL + path, init);
  return { status: res.status, headers: res.headers, body: await res.text() };
}

const upgrade = { headers: { Upgrade: "websocket" } };

/**
 * An `env` whose `ROOM` binding fails the way a Durable Object call can. With
 * `"rejects"`, the stub's `presence()` and `fetch` reject, as on an overload
 * or a reset; with `"throws"`, getting the stub throws at once.
 */
function failingEnv(how: "rejects" | "throws"): Env {
  const fail = () => Promise.reject(new Error("Durable Object overloaded"));
  const room = {
    idFromName: (name: string) => env.ROOM.idFromName(name),
    get: () => {
      if (how === "throws") throw new Error("Durable Object reset");
      return { presence: fail, fetch: fail };
    },
  };
  return { ROOM: room } as unknown as Env;
}

describe("routes", () => {
  it("info returns the name, version and API list", async () => {
    const res = await request("/v1/info");
    expect(res.status).toBe(200);
    expect(res.body).toBe('{"name":"tbd-relay","version":"1.0.0","api":[1]}');
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("the version matches package.json", async () => {
    const pkg = await import("../package.json");
    expect(RELAY_VERSION).toBe(pkg.version);
  });

  it("info refuses other methods", async () => {
    for (const method of ["POST", "HEAD"]) {
      expect((await request("/v1/info", { method })).status, method).toBe(405);
    }
  });

  it("the root says the relay runs", async () => {
    const res = await request("/");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/^text\/plain/);
    expect(res.body).toContain("TBD relay");
  });

  it("unknown paths are 404", async () => {
    for (const path of ["/v2/info", "/v1/info/", "/v1/rooms", "/v1/rooms/", "/v1", "/favicon.ico"]) {
      expect((await request(path)).status, path).toBe(404);
    }
  });

  it("malformed room IDs are 404 even with an upgrade", async () => {
    const id = newRoomID();
    expect(id).toHaveLength(43);
    const malformed = [
      id.slice(0, 42),
      id + "A",
      id.slice(0, 42) + "+",
      id.slice(0, 42) + "=",
      id.slice(0, 42) + ".",
      id.slice(0, 41) + "%41",
      // Decoded, this would be a valid 43-character ID; the relay never decodes the path.
      id.slice(0, 42) + "%41",
      id + "/",
      id + "/x",
    ];
    for (const room of malformed) {
      expect((await request(`/v1/rooms/${room}?role=phone`, upgrade)).status, room).toBe(404);
    }
  });

  it("a bad role is 400", async () => {
    const id = newRoomID();
    for (const query of ["", "?role=admin", "?role=Laptop", "?role=", "?role=laptop&role=phone"]) {
      // Without an upgrade, 400 before 426 shows the Worker checks the role first.
      expect((await request(`/v1/rooms/${id}${query}`)).status, query).toBe(400);
      // With one, the request is still refused, never upgraded.
      expect((await request(`/v1/rooms/${id}${query}`, upgrade)).status, query).toBe(400);
    }
  });

  it("a room URL without an upgrade is 426", async () => {
    const id = newRoomID();
    expect((await request(`/v1/rooms/${id}?role=laptop`)).status).toBe(426);
    expect((await request(`/v1/rooms/${id}?role=phone`, { headers: { Upgrade: "h2c" } })).status).toBe(426);
  });

  it("a room refuses other methods", async () => {
    const path = `/v1/rooms/${newRoomID()}?role=laptop`;
    // 405, not 426: the method is checked before the upgrade.
    expect((await request(path, { method: "POST" })).status).toBe(405);
    // The runtime's fetch sends every request that carries `Upgrade: websocket`
    // as a GET, so a POST upgrade goes to the handler directly.
    const res = await worker.fetch(new Request(BASE_URL + path, { method: "POST", ...upgrade }), env);
    await res.text();
    expect(res.status).toBe(405);
  });

  it("checks the room ID, then the method, then the role", async () => {
    // 404 before 405: a malformed room ID is missing whatever the method.
    const malformed = `/v1/rooms/${newRoomID().slice(0, 42)}?role=laptop`;
    expect((await request(malformed, { method: "POST" })).status).toBe(404);
    // 405 before 400: a POST is refused before its role is read.
    const badRole = `/v1/rooms/${newRoomID()}?role=admin`;
    expect((await request(badRole, { method: "POST" })).status).toBe(405);
  });

  it("a valid room URL opens a WebSocket", async () => {
    // `connect` asserts the 101.
    const socket = await connect(newRoomID(), "laptop");
    socket.close();
  });

  it("every HTTP response is readable from any origin", async () => {
    const id = newRoomID();
    const cases: [label: string, path: string, init: RequestInit | undefined, status: number][] = [
      ["the root", "/", undefined, 200],
      ["info", "/v1/info", undefined, 200],
      ["presence", `/v1/rooms/${id}/presence`, undefined, 200],
      ["an unknown path", "/favicon.ico", undefined, 404],
      ["a malformed room ID", `/v1/rooms/${id.slice(0, 42)}?role=phone`, upgrade, 404],
      // What a cross-origin loader sees when it asks presence for a bad room ID.
      ["presence for a malformed room ID", `/v1/rooms/${id.slice(0, 42)}/presence`, undefined, 404],
      ["another method on the root", "/", { method: "POST" }, 405],
      ["another method on info", "/v1/info", { method: "POST" }, 405],
      ["another method on a room", `/v1/rooms/${id}?role=laptop`, { method: "POST" }, 405],
      ["another method on presence", `/v1/rooms/${id}/presence`, { method: "POST" }, 405],
      ["a bad role", `/v1/rooms/${id}?role=admin`, upgrade, 400],
      ["a room URL without an upgrade", `/v1/rooms/${id}?role=laptop`, undefined, 426],
    ];
    for (const [label, path, init, status] of cases) {
      const res = await request(path, init);
      expect(res.status, label).toBe(status);
      expect(res.headers.get("access-control-allow-origin"), label).toBe("*");
    }
  });

  it("a failed Durable Object call is a 500 any origin can read", async () => {
    const id = newRoomID();
    const routes: [label: string, path: string, init: typeof upgrade | undefined][] = [
      ["presence", `/v1/rooms/${id}/presence`, undefined],
      ["a room socket", `/v1/rooms/${id}?role=phone`, upgrade],
    ];
    for (const how of ["rejects", "throws"] as const) {
      for (const [route, path, init] of routes) {
        const label = `${route}, when the binding ${how}`;
        const res = await worker.fetch(new Request(BASE_URL + path, init), failingEnv(how));
        expect(res.status, label).toBe(500);
        expect(res.headers.get("access-control-allow-origin"), label).toBe("*");
        expect(res.headers.get("content-type"), label).toMatch(/^text\/plain/);
        expect(await res.text(), label).toBe("Internal Server Error\n");
      }
    }
  });
});

describe("presence route", () => {
  it("answers with JSON a page on any origin can read", async () => {
    const res = await request(`/v1/rooms/${newRoomID()}/presence`);
    expect(res.status).toBe(200);
    expect(res.body).toBe(LAPTOP_OFFLINE);
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  it("ignores the role and the upgrade", async () => {
    const res = await request(`/v1/rooms/${newRoomID()}/presence?role=admin`, upgrade);
    expect(res.status).toBe(200);
    expect(res.body).toBe(LAPTOP_OFFLINE);
  });

  it("malformed room IDs and near-miss paths are 404", async () => {
    const id = newRoomID();
    const paths = [
      `/v1/rooms/${id.slice(0, 42)}/presence`,
      `/v1/rooms/${id}A/presence`,
      `/v1/rooms/${id.slice(0, 42)}+/presence`,
      `/v1/rooms/${id}/presence/`,
      `/v1/rooms/${id}/presencex`,
      `/v1/rooms/${id}/x`,
      "/v1/rooms/presence",
    ];
    for (const path of paths) {
      expect((await request(path)).status, path).toBe(404);
    }
    // 404 before 405, as on the WebSocket route.
    expect((await request(`/v1/rooms/${id.slice(0, 42)}/presence`, { method: "POST" })).status).toBe(404);
  });

  it("refuses other methods in a way a page on any origin can read", async () => {
    for (const method of ["POST", "HEAD"]) {
      const res = await request(`/v1/rooms/${newRoomID()}/presence`, { method });
      expect(res.status, method).toBe(405);
      expect(res.headers.get("allow"), method).toBe("GET");
      expect(res.headers.get("access-control-allow-origin"), method).toBe("*");
    }
  });
});
