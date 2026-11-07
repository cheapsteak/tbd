import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { CLOSE_REPLACED, CLOSE_TOO_LARGE, MAX_FRAME_BYTES, PING, PONG, SIGNAL, type Role } from "../src/api";
import {
  LAPTOP_OFFLINE,
  LAPTOP_ONLINE,
  bytes,
  connect,
  flush,
  marker,
  newRoomID,
  presence,
  stub,
  type TestSocket,
} from "./helpers";

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
      if (ws.readyState !== WebSocket.OPEN) instance.webSocketClose(ws, CLOSE_REPLACED.code, CLOSE_REPLACED.reason, true);
    }
  });
}

/**
 * A binary frame for a direct `webSocketMessage` call. Tests that expect such a
 * call to be dropped first show that a frame built this way passes, so the drop
 * cannot come from the frame failing the handler's type check.
 */
function frame(...values: number[]): ArrayBuffer {
  return new Uint8Array(values).buffer;
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

  it("keepalive is answered after hibernation", async () => {
    const room = newRoomID();
    const laptop = await connect(room, "laptop");
    await evictDurableObject(stub(room));
    laptop.send(PING);
    expect(await laptop.next()).toBe(PONG);
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

    expect(await flush(phone2, laptop)).toEqual([SIGNAL.peerJoined, SIGNAL.peerJoined]);
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

    expect(await flush(laptop2, phone)).toEqual([SIGNAL.peerJoined, SIGNAL.peerJoined]);
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

  it("an error on the last socket of a role sends peer-left", async () => {
    const room = newRoomID();
    const { laptop } = await pair(room);
    await runInDurableObject(stub(room), (instance, state) => {
      const [server] = state.getWebSockets("phone");
      // The socket still reads as open, so the signal depends on `leave`
      // leaving the failed socket itself out of the count.
      expect(server!.readyState).toBe(WebSocket.OPEN);
      instance.webSocketError(server!, new Error("x"));
    });
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
  });

  it("frames are dropped when the peer is absent", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);
    await runInDurableObject(stub(room), (instance, state) => {
      instance.webSocketMessage(state.getWebSockets("laptop")[0]!, frame(8));
    });
    expect(bytes(await phone.next())).toEqual(new Uint8Array([8]));

    phone.close(1000);
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
    await runInDurableObject(stub(room), (instance, state) => {
      instance.webSocketMessage(state.getWebSockets("laptop")[0]!, frame(9));
    });

    // The dropped frame was not queued for the next phone.
    const phone2 = await connect(room, "phone");
    expect(await flush(laptop, phone2)).toEqual([SIGNAL.peerJoined]);
  });

  it("text from a client is never forwarded", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);

    phone.send(SIGNAL.peerLeft);
    phone.send("hello");
    expect(await flush(phone, laptop)).toEqual([]);

    phone.send(PING);
    expect(await phone.next()).toBe(PONG);
    expect(await flush(phone, laptop)).toEqual([]);
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

  it("a frame too large sends peer-left without waiting for the close", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);
    const m = marker();
    await runInDurableObject(stub(room), (instance, state) => {
      const [server] = state.getWebSockets("phone");
      instance.webSocketMessage(server!, new Uint8Array(MAX_FRAME_BYTES + 1).buffer);
      // No close event can run before this callback returns, so whatever the
      // laptop hears before this marker came from the oversize frame itself.
      state.getWebSockets("laptop")[0]!.send(m);
    });
    expect(await laptop.until(m)).toEqual([SIGNAL.peerLeft]);
    expect(await phone.closed).toEqual(CLOSE_TOO_LARGE);
  });

  it("frames from a socket the relay is closing are dropped", async () => {
    const room = newRoomID();
    const { laptop } = await pair(room);
    await runInDurableObject(stub(room), (instance, state) => {
      instance.webSocketMessage(state.getWebSockets("phone")[0]!, frame(4));
    });
    expect(bytes(await laptop.next())).toEqual(new Uint8Array([4]));

    await runInDurableObject(stub(room), (instance, state) => {
      const [server] = state.getWebSockets("phone");
      server!.close(CLOSE_REPLACED.code, CLOSE_REPLACED.reason);
      instance.webSocketMessage(server!, frame(5));
      instance.webSocketClose(server!, CLOSE_REPLACED.code, CLOSE_REPLACED.reason, true);
    });
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
  });

  it("forwarding and peer-left survive hibernation", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);

    await evictDurableObject(stub(room));
    expect(await flush(phone, laptop)).toEqual([]);
    expect(await flush(laptop, phone)).toEqual([]);

    await evictDurableObject(stub(room));
    phone.close(1000);
    expect(await laptop.next()).toBe(SIGNAL.peerLeft);
  });

  it("a phone that joins after hibernation replaces the old one", async () => {
    const room = newRoomID();
    const { laptop, phone: phone1 } = await pair(room);
    // The eviction wipes memory, so the join must find the old phone among the
    // room's sockets rather than in a field.
    await evictDurableObject(stub(room));

    const phone2 = await connect(room, "phone");
    expect(await phone1.closed).toEqual(CLOSE_REPLACED);
    await finishClosing(room, "phone");
    expect(await flush(phone2, laptop)).toEqual([SIGNAL.peerJoined]);
    expect(await phone2.next()).toBe(SIGNAL.peerJoined);

    laptop.send(new Uint8Array([7]));
    expect(bytes(await phone2.next())).toEqual(new Uint8Array([7]));
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

describe("presence", () => {
  it("is false in a fresh room and in a room with only a phone", async () => {
    const room = newRoomID();
    expect(await presence(room)).toBe(LAPTOP_OFFLINE);
    // Asking accepted no socket.
    await runInDurableObject(stub(room), (_, state) => {
      expect(state.getWebSockets()).toHaveLength(0);
    });

    const phone = await connect(room, "phone");
    expect(await phone.next()).toBe(SIGNAL.peerAbsent);
    expect(await presence(room)).toBe(LAPTOP_OFFLINE);
  });

  it("is true while a laptop socket is open", async () => {
    const room = newRoomID();
    await connect(room, "laptop");
    expect(await presence(room)).toBe(LAPTOP_ONLINE);
  });

  it("is false again once the laptop leaves", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);
    laptop.close(1000);
    // The phone's peer-left shows the room has handled the laptop's close.
    expect(await phone.next()).toBe(SIGNAL.peerLeft);
    expect(await presence(room)).toBe(LAPTOP_OFFLINE);
  });

  it("does not count a laptop socket the relay is closing", async () => {
    const room = newRoomID();
    await connect(room, "laptop");
    await runInDurableObject(stub(room), (instance, state) => {
      expect(instance.presence()).toEqual({ laptop: true });
      state.getWebSockets("laptop")[0]!.close(CLOSE_REPLACED.code, CLOSE_REPLACED.reason);
      expect(instance.presence()).toEqual({ laptop: false });
    });
  });

  it("disturbs neither socket of a pair", async () => {
    const room = newRoomID();
    const { laptop, phone } = await pair(room);
    expect(await presence(room)).toBe(LAPTOP_ONLINE);

    // Both sockets are still open and hear no signal: frames flow both ways.
    expect(await flush(phone, laptop)).toEqual([]);
    expect(await flush(laptop, phone)).toEqual([]);
  });

  it("leaves no trace for the next laptop", async () => {
    const room = newRoomID();
    const phone = await connect(room, "phone");
    expect(await phone.next()).toBe(SIGNAL.peerAbsent);
    expect(await presence(room)).toBe(LAPTOP_OFFLINE);

    const laptop = await connect(room, "laptop");
    expect(await laptop.next()).toBe(SIGNAL.peerJoined);
    expect(await flush(laptop, phone)).toEqual([SIGNAL.peerJoined]);
  });
});
