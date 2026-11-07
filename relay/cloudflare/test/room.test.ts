import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { CLOSE_REPLACED, CLOSE_TOO_LARGE, MAX_FRAME_BYTES, PING, PONG, SIGNAL, type Role } from "../src/api";
import { bytes, connect, marker, newRoomID, stub, type TestSocket } from "./helpers";

const OPEN = 1;

/** A laptop and a phone in one room, each past its `peer-joined`. */
async function pair(room: string): Promise<{ laptop: TestSocket; phone: TestSocket }> {
  const laptop = await connect(room, "laptop");
  const phone = await connect(room, "phone");
  expect(await laptop.next()).toBe(SIGNAL.peerJoined);
  expect(await phone.next()).toBe(SIGNAL.peerJoined);
  return { laptop, phone };
}

/**
 * Runs the close handler for every `role` socket that is no longer open, so a
 * replaced socket's close has run whether or not the runtime delivered it yet.
 * The handler may then run a second time; the relay must not mind.
 */
async function finishClosing(room: string, role: Role): Promise<void> {
  await runInDurableObject(stub(room), (instance, state) => {
    for (const ws of state.getWebSockets(role)) {
      if (ws.readyState !== OPEN) instance.webSocketClose(ws, CLOSE_REPLACED.code, CLOSE_REPLACED.reason, true);
    }
  });
}

/** Random bytes of any length; `getRandomValues` fills at most 65,536 per call. */
function randomBytes(length: number): Uint8Array {
  const out = new Uint8Array(length);
  for (let offset = 0; offset < length; offset += 65_536) {
    crypto.getRandomValues(out.subarray(offset, Math.min(offset + 65_536, length)));
  }
  return out;
}

describe("room", () => {
  it("keepalive is answered by the auto-response", async () => {
    const room = newRoomID();
    const laptop = await connect(room, "laptop");
    laptop.send(PING);
    expect(await laptop.next()).toBe(PONG);
    // A timestamp shows the runtime answered, not the object's message handler.
    await runInDurableObject(stub(room), (_, state) => {
      const [server] = state.getWebSockets("laptop");
      expect(server).toBeDefined();
      expect(state.getWebSocketAutoResponseTimestamp(server!)).not.toBeNull();
    });
  });

  it("a phone joining an empty room gets peer-absent", async () => {
    const phone = await connect(newRoomID(), "phone");
    expect(await phone.next()).toBe(SIGNAL.peerAbsent);
  });

  it("pairs a laptop and a phone", async () => {
    const room = newRoomID();
    const laptop = await connect(room, "laptop");
    const phone = await connect(room, "phone");
    // The laptop's first message is the phone's arrival: it got nothing when it joined alone.
    expect(await laptop.next()).toBe(SIGNAL.peerJoined);
    expect(await phone.next()).toBe(SIGNAL.peerJoined);

    phone.send(new Uint8Array([1, 2, 3]));
    const fromPhone = await laptop.next();
    expect(fromPhone).toBeInstanceOf(ArrayBuffer);
    expect(bytes(fromPhone)).toEqual(new Uint8Array([1, 2, 3]));

    laptop.send(new Uint8Array([4, 5, 6]));
    expect(bytes(await phone.next())).toEqual(new Uint8Array([4, 5, 6]));
  });

  it("a phone that waited gets peer-joined when the laptop arrives", async () => {
    const room = newRoomID();
    const phone = await connect(room, "phone");
    expect(await phone.next()).toBe(SIGNAL.peerAbsent);
    const laptop = await connect(room, "laptop");
    expect(await phone.next()).toBe(SIGNAL.peerJoined);
    expect(await laptop.next()).toBe(SIGNAL.peerJoined);
  });

  it("replacing a phone sends peer-joined and no peer-left", async () => {
    const room = newRoomID();
    const laptop = await connect(room, "laptop");
    const phone1 = await connect(room, "phone");
    const phone2 = await connect(room, "phone");
    expect(await phone1.closed).toEqual(CLOSE_REPLACED);
    await finishClosing(room, "phone");

    const m = marker();
    phone2.send(m);
    expect(await laptop.until(m)).toEqual([SIGNAL.peerJoined, SIGNAL.peerJoined]);
    expect(await phone2.next()).toBe(SIGNAL.peerJoined);

    laptop.send(new Uint8Array([7]));
    expect(bytes(await phone2.next())).toEqual(new Uint8Array([7]));
  });

  it("replacing a laptop works the same way", async () => {
    const room = newRoomID();
    const phone = await connect(room, "phone");
    expect(await phone.next()).toBe(SIGNAL.peerAbsent);
    const laptop1 = await connect(room, "laptop");
    const laptop2 = await connect(room, "laptop");
    expect(await laptop1.closed).toEqual(CLOSE_REPLACED);
    await finishClosing(room, "laptop");

    const m = marker();
    laptop2.send(m);
    expect(await phone.until(m)).toEqual([SIGNAL.peerJoined, SIGNAL.peerJoined]);
    expect(await laptop2.next()).toBe(SIGNAL.peerJoined);
  });

  it("peer-left when the other side disconnects", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);
    phone.close(1000);
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);

    // The laptop stayed open: it hears the next phone.
    const phone2 = await connect(room, "phone");
    expect(await laptop.next()).toBe(SIGNAL.peerJoined);
    expect(await phone2.next()).toBe(SIGNAL.peerJoined);
  });

  it("frames are dropped when the peer is absent", async () => {
    const room = newRoomID();
    const laptop = await connect(room, "laptop");
    await runInDurableObject(stub(room), (instance, state) => {
      const [server] = state.getWebSockets("laptop");
      instance.webSocketMessage(server!, new Uint8Array([9]).buffer);
    });

    const phone = await connect(room, "phone");
    const m = marker();
    laptop.send(m);
    expect(await phone.until(m)).toEqual([SIGNAL.peerJoined]);
  });

  it("text from a client is never forwarded", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);

    phone.send(SIGNAL.peerLeft);
    phone.send("hello");
    const m1 = marker();
    phone.send(m1);
    expect(await laptop.until(m1)).toEqual([]);

    phone.send(PING);
    expect(await phone.next()).toBe(PONG);
    const m2 = marker();
    phone.send(m2);
    expect(await laptop.until(m2)).toEqual([]);
  });

  it("the 64 KiB limit", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);

    const largest = randomBytes(MAX_FRAME_BYTES);
    phone.send(largest);
    expect(bytes(await laptop.next())).toEqual(largest);

    phone.send(randomBytes(MAX_FRAME_BYTES + 1));
    expect(await phone.closed).toEqual(CLOSE_TOO_LARGE);
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
  });

  it("frames from a socket the relay is closing are dropped", async () => {
    const room = newRoomID();
    const { laptop } = await pair(room);
    await runInDurableObject(stub(room), (instance, state) => {
      const [server] = state.getWebSockets("phone");
      server!.close(CLOSE_REPLACED.code, CLOSE_REPLACED.reason);
      instance.webSocketMessage(server!, new Uint8Array([5]).buffer);
      instance.webSocketClose(server!, CLOSE_REPLACED.code, CLOSE_REPLACED.reason, true);
    });
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
  });

  it("forwarding and peer-left survive hibernation", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);

    await evictDurableObject(stub(room));
    const fromPhone = marker();
    phone.send(fromPhone);
    expect(await laptop.until(fromPhone)).toEqual([]);
    const fromLaptop = marker();
    laptop.send(fromLaptop);
    expect(await phone.until(fromLaptop)).toEqual([]);

    await evictDurableObject(stub(room));
    phone.close(1000);
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
  });

  it("rooms are separate", async () => {
    const a = newRoomID();
    const b = newRoomID();
    const roomA = { laptop: await connect(a, "laptop"), phone: await connect(a, "phone") };
    const roomB = { laptop: await connect(b, "laptop"), phone: await connect(b, "phone") };

    const mA = marker();
    const mB = marker();
    roomA.phone.send(mA);
    roomB.phone.send(mB);
    expect(await roomA.laptop.until(mA)).toEqual([SIGNAL.peerJoined]);
    expect(await roomB.laptop.until(mB)).toEqual([SIGNAL.peerJoined]);
  });
});
