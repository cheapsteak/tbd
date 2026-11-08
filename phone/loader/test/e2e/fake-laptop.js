// The Playwright suite's server: one `http` server on 127.0.0.1 that serves a staged copy of
// the loader, emulates relay API v1 on the same origin through Task 5's fake relay, and runs
// scripted laptops in process.
//
// - The site is staged with phone/scripts/stage-loader.sh, the command the deploy runs, so a
//   file the loader needs that the allowlist misses fails the suite. It is served at `/` with
//   `Access-Control-Allow-Origin: *`, `Cache-Control: no-store` and no policy header, as GitHub
//   Pages sends none.
// - Test-only routes live under `/__test/` and never come from the staged site. One of them is
//   the runner harness (`/__test/runner-harness.html`), which frames runner.html the way
//   sandbox-runner.spec.js asks.
// - A second server on another port, a second origin, serves only the runner harness, so a test
//   can frame runner.html from a page that is not the loader's.
// - `GET /v1/rooms/<room>/presence` answers from the fake relay, and WebSocket upgrades on
//   `/v1/rooms/…` join it.
//
// Node only. Nothing here is staged or served from the loader's own files.

import { execFile } from 'node:child_process';
import { lstat, mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { WebSocketServer } from 'ws';

import { base64urlEncode } from '../../channel/pairingLink.js';
import { createFakeRelay } from '../support/fake-relay.js';
import { createScriptedLaptop } from '../support/scripted-laptop.js';

/** @typedef {import('../support/fake-relay.js').FakeRelay} FakeRelay */
/** @typedef {import('../support/fake-relay.js').RelayHandle} RelayHandle */
/** @typedef {Awaited<ReturnType<typeof createScriptedLaptop>>} ScriptedLaptop */

const run = promisify(execFile);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LOADER_DIR = path.resolve(HERE, '../..');
const PHONE_DIR = path.resolve(LOADER_DIR, '..');
const STAGE_SCRIPT = path.join(PHONE_DIR, 'scripts', 'stage-loader.sh');
const FIXTURES_DIR = path.join(LOADER_DIR, 'test', 'fixtures');
const SUPPORT_DIR = path.join(LOADER_DIR, 'test', 'support');
const VECTORS_DIR = path.join(PHONE_DIR, 'test-vectors');

const BUNDLES = { debug: 'debug-app.js', probe: 'probe-app.js' };
const MAX_PAYLOAD = 65_536;
const PRESENCE_PATH = /^\/v1\/rooms\/([A-Za-z0-9_-]{43})\/presence$/;
const PLAIN_NAME = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/;
const utf8 = new TextEncoder();

/** @type {Record<string, string>} */
const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.txt': 'text/plain; charset=utf-8',
};

/**
 * A one-line page for the test routes the app frame or a new tab navigates to.
 * @param {string} title
 */
const htmlPage = (title) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${title}</title></head><body><p>${title}</p></body></html>\n`;

/**
 * The runner harness page; its script is `/__test/runner-harness.js`.
 */
const HARNESS_PAGE = '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Runner harness</title>'
  + '<script src="/__test/runner-harness.js"></script></head><body></body></html>\n';

/** @type {Record<string, { type: string, body: string | Uint8Array }>} */
const TEST_PAGES = {
  'runner-harness.html': { type: CONTENT_TYPES['.html'], body: HARNESS_PAGE },
  landing: { type: CONTENT_TYPES['.html'], body: htmlPage('Landing') },
  anchor: { type: CONTENT_TYPES['.html'], body: htmlPage('Anchor') },
  nav: { type: CONTENT_TYPES['.html'], body: htmlPage('Navigated') },
  'blank.html': { type: CONTENT_TYPES['.html'], body: htmlPage('Blank') },
  // A real 1 × 1 PNG, so a probe that is wrongly allowed to load it sees `load`, not `error`.
  'probe-img': {
    type: CONTENT_TYPES['.png'],
    body: Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==', 'base64'),
  },
  'probe-fetch': { type: CONTENT_TYPES['.txt'], body: 'probe\n' },
};

/**
 * @typedef {object} PairingLinkOptions
 * @property {number} [expSeconds] Seconds from now to the offer's `exp`. Default 300.
 * @property {'allow' | 'deny' | 'expire' | 'silent'} [decision] Default 'allow'.
 * @property {string} [pairedRoom] Sent verbatim in `paired` (see the scripted laptop).
 * @property {'immediate' | 'manual'} [deviceJoin] See the scripted laptop.
 */

/**
 * @typedef {object} FakeLaptopServer
 * @property {string} origin `http://127.0.0.1:<port>`, the loader's origin and the relay's.
 * @property {string} otherOrigin `http://127.0.0.1:<other port>`, a second origin that serves
 *   only the runner harness (`/__test/runner-harness.html` and its script). Its requests are not
 *   in `requests`.
 * @property {FakeRelay} relay
 * @property {ScriptedLaptop[]} laptops The first is named by `startFakeLaptop`'s `laptopName`
 *   (`acme-mbp` by default); `addLaptop` adds more.
 * @property {(options: { laptopName: string }) => Promise<ScriptedLaptop>} addLaptop
 * @property {(laptop: ScriptedLaptop, options?: PairingLinkOptions) => string} pairingLink
 *   Opens an offer on `laptop` and returns `${origin}/#p=…`, its relay set to `origin`. The
 *   link names the offer's pairing room; the device's room is the one `paired` carries (a key
 *   of `laptop.devices` once paired).
 * @property {(variant: string) => string} debugBundle The debug bundle with
 *   `globalThis.__debugVariant = <variant>;` prepended, for `laptop.setBundle`.
 * @property {(room: string) => () => void} holdPresence Holds every presence answer for `room`
 *   until the returned function is called.
 * @property {() => () => void} holdUpgrades Parks every WebSocket upgrade on `/v1/rooms/…`
 *   from now on, unanswered, so each phone socket stays connecting, until the returned
 *   function is called. Each parked upgrade is in `requests` on arrival but joins the relay
 *   only on release, in arrival order, and only if its client is still there: one the phone
 *   gave up on meanwhile never joins. Later upgrades go straight through. One hold at a time.
 * @property {string[]} requests Every request path, query included, in arrival order:
 *   pages, files, presence checks and WebSocket upgrades.
 * @property {boolean} refuseUpgrade While true, every WebSocket upgrade gets 503.
 * @property {boolean} refusePresence While true, every presence request fails at the network
 *   level: the socket is destroyed with no response.
 * @property {() => Promise<void>} close Closes every socket and both servers, and removes the
 *   staged site.
 */

/**
 * Starts the server, stages the loader for it and starts the first laptop.
 * @param {{ runnerOrigin?: string, bundle?: 'debug' | 'probe', refuseUpgrade?: boolean, laptopName?: string }} [options]
 *   `runnerOrigin` is stamped into runner.html in place of the server's own origin, so a test
 *   can stamp a foreign one. `bundle` is the app every laptop serves. `laptopName` names the
 *   first laptop, `acme-mbp` by default.
 * @returns {Promise<FakeLaptopServer>}
 */
export async function startFakeLaptop({
  runnerOrigin, bundle = 'debug', refuseUpgrade = false, laptopName: firstName = 'acme-mbp',
} = {}) {
  const bundleFile = BUNDLES[bundle];
  if (bundleFile === undefined) throw new RangeError(`unknown bundle ${bundle}`);
  const bundleText = await readFile(path.join(FIXTURES_DIR, bundleFile), 'utf8');
  const debugText = await readFile(path.join(FIXTURES_DIR, BUNDLES.debug), 'utf8');

  const relay = createFakeRelay();
  const temp = await mkdtemp(path.join(tmpdir(), 'tbd-loader-e2e-'));
  const site = path.join(temp, 'site');
  /** @type {Set<import('ws').WebSocket>} */
  const sockets = new Set();
  /** @type {Map<string, Promise<void>>} */
  const held = new Map();
  /** @type {Set<() => void>} */
  const releases = new Set();
  /**
   * Upgrades parked by `holdUpgrades`, or null while none is held.
   * @type {Array<{ req: import('node:http').IncomingMessage, socket: import('node:stream').Duplex,
   *   head: Buffer, url: string }> | null}
   */
  let parked = null;
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD });
  const http = createServer();
  const other = createServer();

  /** @type {FakeLaptopServer} */
  const server = {
    origin: '',
    otherOrigin: '',
    relay,
    laptops: [],
    requests: [],
    refuseUpgrade,
    refusePresence: false,
    addLaptop: async ({ laptopName }) => {
      const laptop = await createScriptedLaptop({ relay, laptopName, bundleText, relayOrigin: server.origin });
      server.laptops.push(laptop);
      return laptop;
    },
    pairingLink: (laptop, options = {}) => {
      const fields = laptop.makeOffer(options);
      return `${server.origin}/#p=${base64urlEncode(utf8.encode(JSON.stringify(fields)))}`;
    },
    debugBundle: (variant) => `globalThis.__debugVariant = ${JSON.stringify(String(variant))};\n${debugText}`,
    holdPresence: (room) => {
      /** @type {() => void} */
      let release = () => {};
      const gate = new Promise((resolve) => {
        release = () => {
          releases.delete(release);
          if (held.get(room) === gate) held.delete(room);
          resolve(undefined);
        };
      });
      held.set(room, /** @type {Promise<void>} */ (gate));
      releases.add(release);
      return release;
    },
    holdUpgrades: () => {
      if (parked !== null) throw new Error('upgrades are already held');
      parked = [];
      const release = () => {
        releases.delete(release);
        const waiting = parked ?? [];
        parked = null;
        for (const { req, socket, head, url } of waiting) {
          if (!socket.destroyed) bridge(req, socket, head, url);
        }
      };
      releases.add(release);
      return release;
    },
    close: async () => {
      for (const { socket } of parked ?? []) socket.destroy();
      parked = null;
      for (const release of [...releases]) release();
      for (const ws of sockets) ws.terminate();
      sockets.clear();
      wss.close();
      for (const listener of [http, other]) {
        listener.closeAllConnections();
        await new Promise((resolve) => listener.close(() => resolve(undefined)));
      }
      await rm(temp, { recursive: true, force: true });
    },
  };

  http.on('request', (req, res) => {
    const url = req.url ?? '/';
    server.requests.push(url);
    handleRequest(req, res, url).catch(() => {
      if (!res.headersSent) send(res, req, 500, CONTENT_TYPES['.txt'], 'error\n');
      else res.destroy();
    });
  });
  http.on('upgrade', (req, socket, head) => {
    const url = req.url ?? '/';
    server.requests.push(url);
    socket.on('error', () => {});
    if (!url.startsWith('/v1/rooms/')) {
      refuse(socket, 404, 'Not Found');
      return;
    }
    if (server.refuseUpgrade) {
      refuse(socket, 503, 'Service Unavailable');
      return;
    }
    if (parked !== null) {
      parked.push({ req, socket, head, url });
      return;
    }
    bridge(req, socket, head, url);
  });
  http.on('clientError', (_error, socket) => socket.destroy());
  // The second origin: the runner harness, and nothing else.
  other.on('request', (req, res) => {
    const pathname = (req.url ?? '/').split('?')[0];
    const route = pathname.startsWith('/__test/') ? pathname.slice('/__test/'.length) : '';
    if ((req.method === 'GET' || req.method === 'HEAD') && HARNESS_ROUTES.has(route)) {
      testRoute(req, res, route).catch(() => res.destroy());
    } else {
      notFound(req, res);
    }
  });
  other.on('clientError', (_error, socket) => socket.destroy());

  server.origin = await listen(http);
  try {
    server.otherOrigin = await listen(other);
  } catch (error) {
    await server.close();
    throw error;
  }

  try {
    await run('bash', [STAGE_SCRIPT, LOADER_DIR, site, runnerOrigin ?? server.origin]);
    await server.addLaptop({ laptopName: firstName });
  } catch (error) {
    await server.close();
    throw error;
  }
  return server;

  /**
   * @param {import('node:http').IncomingMessage} req
   * @param {import('node:http').ServerResponse} res
   * @param {string} url
   */
  async function handleRequest(req, res, url) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      send(res, req, 405, CONTENT_TYPES['.txt'], 'method not allowed\n');
      return;
    }
    const pathname = url.split('?')[0];
    if (pathname.startsWith('/v1/')) {
      await presence(req, res, pathname);
      return;
    }
    if (pathname.startsWith('/__test/')) {
      await testRoute(req, res, pathname.slice('/__test/'.length));
      return;
    }
    const rel = pathname === '/' ? 'index.html' : sitePath(pathname);
    if (rel === null) {
      notFound(req, res);
      return;
    }
    await sendFile(req, res, site, rel);
  }

  /**
   * `GET /v1/rooms/<room>/presence`, from the fake relay.
   * @param {import('node:http').IncomingMessage} req
   * @param {import('node:http').ServerResponse} res
   * @param {string} pathname
   */
  async function presence(req, res, pathname) {
    if (server.refusePresence) {
      req.socket.destroy();
      return;
    }
    const room = PRESENCE_PATH.exec(pathname)?.[1];
    const gate = room === undefined ? undefined : held.get(room);
    if (gate !== undefined) await gate;
    if (server.refusePresence) {
      req.socket.destroy();
      return;
    }
    const answer = relay.presence(pathname);
    if (answer.status !== 200 || answer.body === undefined) {
      notFound(req, res);
      return;
    }
    send(res, req, 200, CONTENT_TYPES['.json'], JSON.stringify(answer.body));
  }

  /**
   * @param {import('node:http').IncomingMessage} req
   * @param {import('node:http').ServerResponse} res
   * @param {string} route the path after `/__test/`
   */
  async function testRoute(req, res, route) {
    const fixed = TEST_PAGES[route];
    if (fixed !== undefined) {
      send(res, req, 200, fixed.type, fixed.body);
      return;
    }
    if (route === 'qr.png') {
      await sendFile(req, res, FIXTURES_DIR, 'qr-sample.png');
      return;
    }
    if (route === 'runner-harness.js') {
      await sendFile(req, res, FIXTURES_DIR, 'runner-harness.js');
      return;
    }
    if (route === 'support/vectors-in-page.js') {
      await sendFile(req, res, SUPPORT_DIR, 'vectors-in-page.js');
      return;
    }
    if (route.startsWith('vectors/')) {
      const name = decodeSegment(route.slice('vectors/'.length));
      if (name !== null && PLAIN_NAME.test(name)) {
        await sendFile(req, res, VECTORS_DIR, name);
        return;
      }
    }
    notFound(req, res);
  }

  /**
   * Joins the fake relay, then completes the upgrade. Signals the relay sends while joining
   * wait until the socket is open, and go out in order.
   * @param {import('node:http').IncomingMessage} req
   * @param {import('node:stream').Duplex} socket
   * @param {Buffer} head
   * @param {string} url
   */
  function bridge(req, socket, head, url) {
    /** @type {import('ws').WebSocket | null} */
    let ws = null;
    /** @type {Array<(ws: import('ws').WebSocket) => void>} */
    const pending = [];
    let ended = false;
    /** @param {(ws: import('ws').WebSocket) => void} deliver */
    const toPhone = (deliver) => {
      if (ended) return;
      if (ws === null) pending.push(deliver);
      else deliver(ws);
    };
    const handle = relay.connect(url, {
      binary: (bytes) => toPhone((s) => s.send(bytes)),
      text: (text) => toPhone((s) => s.send(text)),
      close: (code, reason) => toPhone((s) => {
        try {
          s.close(code, reason);
        } catch {
          // A code `ws` may not send, such as 1005: end the socket without one.
          s.terminate();
        }
      }),
    });
    if (handle === null) {
      refuse(socket, 404, 'Not Found');
      return;
    }
    /** Leaves the relay once, whichever way the socket ended. */
    const leave = () => {
      if (ended) return;
      ended = true;
      handle.close();
    };
    // An upgrade that fails inside `ws` never reaches the callback; the socket still closes.
    socket.once('close', () => {
      if (ws === null) leave();
    });
    wss.handleUpgrade(req, socket, head, (opened) => {
      ws = opened;
      sockets.add(opened);
      opened.on('error', () => {});
      opened.on('message', (data, isBinary) => {
        if (ended) return;
        const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(/** @type {any} */ (data));
        handle.send(isBinary ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : bytes.toString('utf8'));
      });
      opened.on('close', () => {
        sockets.delete(opened);
        leave();
      });
      for (const deliver of pending.splice(0)) deliver(opened);
    });
  }
}

/** The routes under `/__test/` that the second origin serves too. */
const HARNESS_ROUTES = new Set(['runner-harness.html', 'runner-harness.js']);

/**
 * Listens on a free port of 127.0.0.1.
 * @param {import('node:http').Server} server
 * @returns {Promise<string>} the server's origin, `http://127.0.0.1:<port>`
 */
async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject);
      resolve(undefined);
    });
  });
  const address = server.address();
  if (address === null || typeof address === 'string') throw new Error('the server has no port');
  return `http://127.0.0.1:${address.port}`;
}

/**
 * The staged file for a URL path, as a path relative to the site, or null to refuse it.
 * Every segment is decoded once and must be a plain name: no empty segment, no `.` or `..`,
 * no dotfile, and no `/`, `\` or NUL inside it, so nothing can climb out of the site.
 * @param {string} pathname starts with `/`
 * @returns {string | null}
 */
function sitePath(pathname) {
  const parts = [];
  for (const raw of pathname.slice(1).split('/')) {
    const part = decodeSegment(raw);
    if (part === null) return null;
    parts.push(part);
  }
  return parts.join('/');
}

/**
 * @param {string} raw one URL path segment
 * @returns {string | null} the decoded segment, or null when it is not a plain file name
 */
function decodeSegment(raw) {
  let part;
  try {
    part = decodeURIComponent(raw);
  } catch {
    return null;
  }
  if (part === '' || part.startsWith('.') || /[/\\\0]/.test(part)) return null;
  return part;
}

/**
 * Sends `rel` from under `root`: a regular file, not a symlink, that resolves inside `root`.
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @param {string} root
 * @param {string} rel
 */
async function sendFile(req, res, root, rel) {
  const full = path.resolve(root, rel);
  const inside = path.relative(root, full);
  if (inside === '' || inside.startsWith('..') || path.isAbsolute(inside)) {
    notFound(req, res);
    return;
  }
  let stat;
  try {
    stat = await lstat(full);
  } catch {
    notFound(req, res);
    return;
  }
  if (!stat.isFile()) {
    notFound(req, res);
    return;
  }
  const type = CONTENT_TYPES[path.extname(full).toLowerCase()] ?? 'application/octet-stream';
  send(res, req, 200, type, await readFile(full));
}

/**
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 */
function notFound(req, res) {
  send(res, req, 404, CONTENT_TYPES['.txt'], 'not found\n');
}

/**
 * Every response carries the same two headers, and no policy header.
 * @param {import('node:http').ServerResponse} res
 * @param {import('node:http').IncomingMessage} req
 * @param {number} status
 * @param {string} type
 * @param {string | Uint8Array} body
 */
function send(res, req, status, type, body) {
  const bytes = typeof body === 'string' ? Buffer.from(body, 'utf8') : body;
  res.writeHead(status, {
    'Content-Type': type,
    'Content-Length': String(bytes.byteLength),
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(req.method === 'HEAD' ? undefined : bytes);
}

/**
 * Answers an upgrade with an HTTP error and closes the socket.
 * @param {import('node:stream').Duplex} socket
 * @param {number} status
 * @param {string} text
 */
function refuse(socket, status, text) {
  if (!socket.writable) {
    socket.destroy();
    return;
  }
  socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n`);
}
