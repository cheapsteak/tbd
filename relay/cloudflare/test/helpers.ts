import { env, exports } from "cloudflare:workers";
import { expect } from "vitest";
import type { Role } from "../src/api";

export const BASE_URL = "https://relay.test";

/** How long `next` waits before it rejects. */
const MESSAGE_TIMEOUT_MS = 5_000;

export type Message = string | ArrayBuffer;

export interface TestSocket {
  send(data: string | ArrayBuffer | Uint8Array): void;
  /** The next message, in arrival order. Rejects after 5 s, or once the socket has closed. */
  next(): Promise<Message>;
  /** Every message before the binary frame equal to `marker`, which is consumed. */
  until(marker: Uint8Array): Promise<Message[]>;
  close(code?: number): void;
  closed: Promise<{ code: number; reason: string }>;
}

/** A fresh room: 32 random bytes, base64url without padding. Tests share storage, so each mints its own. */
export function newRoomID(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/**
 * A frame no test sends by accident: 16 random bytes, unique per call. The
 * object handles one socket's messages in order, so once a marker sent after
 * some frames arrives, anything those frames would have caused has arrived too.
 * That is how a test shows that nothing arrived, without sleeping.
 */
export function marker(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(16));
}

/** The room's Durable Object stub. */
export function stub(room: string) {
  return env.ROOM.get(env.ROOM.idFromName(room));
}

/** The bytes of a binary message; fails the test on a text message. */
export function bytes(message: Message): Uint8Array {
  if (!(message instanceof ArrayBuffer)) throw new Error(`expected a binary frame, got text ${JSON.stringify(message)}`);
  return new Uint8Array(message);
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}

interface Waiter {
  resolve(message: Message): void;
  reject(error: Error): void;
  timer: ReturnType<typeof setTimeout>;
}

export async function connect(room: string, role: Role): Promise<TestSocket> {
  const res = await exports.default.fetch(`${BASE_URL}/v1/rooms/${room}?role=${role}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket;
  if (ws === null) throw new Error("a 101 response carried no WebSocket");
  // From compatibility date 2026-03-17 (`websocket_standard_binary_type`) a
  // runtime WebSocket delivers binary frames as Blob unless asked otherwise.
  ws.binaryType = "arraybuffer";

  const queue: Message[] = [];
  const waiters: Waiter[] = [];
  let closeEvent: { code: number; reason: string } | null = null;
  let resolveClosed!: (value: { code: number; reason: string }) => void;
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    resolveClosed = resolve;
  });

  ws.addEventListener("message", (event) => {
    const waiter = waiters.shift();
    if (waiter === undefined) {
      queue.push(event.data);
    } else {
      clearTimeout(waiter.timer);
      waiter.resolve(event.data);
    }
  });
  ws.addEventListener("close", (event) => {
    closeEvent = { code: event.code, reason: event.reason };
    // Complete the close handshake even if the runtime has not answered it.
    try {
      ws.close();
    } catch {
      // Already answered.
    }
    resolveClosed(closeEvent);
    for (const waiter of waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error(`${role} socket closed (${closeEvent.code}) while waiting for a message`));
    }
  });
  ws.accept();

  const socket: TestSocket = {
    send(data) {
      ws.send(data);
    },
    next() {
      const queued = queue.shift();
      if (queued !== undefined) return Promise.resolve(queued);
      if (closeEvent !== null) {
        return Promise.reject(new Error(`${role} socket closed (${closeEvent.code}) with no message left`));
      }
      return new Promise<Message>((resolve, reject) => {
        const waiter: Waiter = {
          resolve,
          reject,
          timer: setTimeout(() => {
            waiters.splice(waiters.indexOf(waiter), 1);
            reject(new Error(`${role} socket: no message within ${MESSAGE_TIMEOUT_MS} ms`));
          }, MESSAGE_TIMEOUT_MS),
        };
        waiters.push(waiter);
      });
    },
    async until(target) {
      const before: Message[] = [];
      for (;;) {
        const message = await socket.next();
        if (message instanceof ArrayBuffer && sameBytes(new Uint8Array(message), target)) return before;
        before.push(message);
      }
    },
    close(code = 1000) {
      ws.close(code);
    },
    closed,
  };
  return socket;
}
