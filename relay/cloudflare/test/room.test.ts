import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { PING, PONG } from "../src/api";
import { connect, newRoomID, stub } from "./helpers";

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
});
