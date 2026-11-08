// The phone app's end-to-end server: one `http` server on 127.0.0.1 that serves a staged copy
// of the loader and, beside it, the test host that runs the committed app bundle in the
// loader's real app frame.
//
// - The loader is staged with phone/scripts/stage-loader.sh, the command the deploy runs, with
//   this server's origin stamped into runner.html. The staged site is served at `/` exactly as
//   staged, and the runner, its script and the frame host come only from it, never from
//   phone/loader/ itself. So the frame runs under the runner's own policy, which is its <meta>
//   tag and nothing else: no response from this server carries a policy header, as GitHub
//   Pages sends none.
// - The test host lives under `/__app/`, which the staged site never holds:
//   - `host.html`, `host.js` and `fake-laptop-app.js`, from this folder;
//   - `scenarios/<name>.json`, from `scenarios/`;
//   - `app.js`: Sources/TBDDaemon/Resources/phone-app/app.js, the committed bundle that the
//     bundle check proves is the build of phone/app/src. It is read from disk for each request
//     and sent as it is: never built, patched, wrapped or swapped for a test bundle.
//
// Node only.

import { execFile } from 'node:child_process';
import { lstat, mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PHONE_DIR = path.resolve(HERE, '../../..');
const LOADER_DIR = path.join(PHONE_DIR, 'loader');
const STAGE_SCRIPT = path.join(PHONE_DIR, 'scripts', 'stage-loader.sh');
const SCENARIOS_DIR = path.join(HERE, 'scenarios');
/** The committed bundle. */
export const BUNDLE_PATH = path.resolve(PHONE_DIR, '..', 'Sources', 'TBDDaemon', 'Resources', 'phone-app', 'app.js');

/** The test host's own files, served from this folder under `/__app/`. */
const HOST_FILES = new Set(['host.html', 'host.js', 'fake-laptop-app.js']);
const PLAIN_NAME = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/;

/** @type {Record<string, string>} */
const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

/**
 * @typedef {object} AppHost
 * @property {string} origin `http://127.0.0.1:<port>`: the loader's origin, stamped into the
 *   staged runner.html, and the test host's.
 * @property {() => Promise<void>} close Closes the server and removes the staged site.
 */

/**
 * Starts the server and stages the loader for its origin.
 * @returns {Promise<AppHost>}
 */
export async function startAppHost() {
  const temp = await mkdtemp(path.join(tmpdir(), 'tbd-app-e2e-'));
  const site = path.join(temp, 'site');
  const http = createServer();

  /** @type {AppHost} */
  const host = {
    origin: '',
    close: async () => {
      http.closeAllConnections();
      await new Promise((resolve) => http.close(() => resolve(undefined)));
      await rm(temp, { recursive: true, force: true });
    },
  };

  http.on('request', (req, res) => {
    handleRequest(req, res).catch(() => {
      if (!res.headersSent) send(res, req, 500, CONTENT_TYPES['.txt'], 'error\n');
      else res.destroy();
    });
  });
  http.on('clientError', (_error, socket) => socket.destroy());

  try {
    host.origin = await listen(http);
    await run('bash', [STAGE_SCRIPT, LOADER_DIR, site, host.origin]);
  } catch (error) {
    await host.close();
    throw error;
  }
  return host;

  /**
   * @param {import('node:http').IncomingMessage} req
   * @param {import('node:http').ServerResponse} res
   */
  async function handleRequest(req, res) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      send(res, req, 405, CONTENT_TYPES['.txt'], 'method not allowed\n');
      return;
    }
    const pathname = (req.url ?? '/').split('?')[0];
    if (pathname.startsWith('/__app/')) {
      await appRoute(req, res, pathname.slice('/__app/'.length));
      return;
    }
    const rel = pathname === '/' ? 'index.html' : sitePath(pathname);
    if (rel === null) {
      notFound(req, res);
      return;
    }
    await sendFile(req, res, site, rel);
  }
}

/**
 * The routes under `/__app/`.
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @param {string} route the path after `/__app/`
 */
async function appRoute(req, res, route) {
  if (route === 'app.js') {
    send(res, req, 200, CONTENT_TYPES['.js'], await readFile(BUNDLE_PATH));
    return;
  }
  if (HOST_FILES.has(route)) {
    await sendFile(req, res, HERE, route);
    return;
  }
  if (route.startsWith('scenarios/')) {
    const name = decodeSegment(route.slice('scenarios/'.length));
    if (name !== null && PLAIN_NAME.test(name) && name.endsWith('.json')) {
      await sendFile(req, res, SCENARIOS_DIR, name);
      return;
    }
  }
  notFound(req, res);
}

/**
 * Listens on a free port of 127.0.0.1.
 * @param {import('node:http').Server} server
 * @returns {Promise<string>} the server's origin
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
 * The staged file for a URL path, relative to the site, or null to refuse it. Every segment is
 * decoded once and must be a plain name, so nothing can climb out of the site.
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
  const stat = await lstat(full).catch(() => null);
  if (stat === null || !stat.isFile()) {
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
