import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { RELAY_VERSION } from "../src/api";
import worker from "../src/index";
import { BASE_URL, connect, newRoomID } from "./helpers";

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
});
