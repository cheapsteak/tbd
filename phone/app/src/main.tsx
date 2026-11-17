/**
 * The bundle's entry point. The runner starts it as one classic script, with the loader port on
 * the global (`phone/loader/runner.js`). It wires the store, the protocol client, the actions,
 * the history entries and the loader link together, then mounts React into `#app`.
 *
 * A throw here, before React mounts, is a top-level error in the bundle, which the runner reports
 * to the loader as `fault: 'script'`; the loader then shows "Reload this page". `readHost` throws
 * so when the runner's handle is missing, speaks another protocol, or comes from a loader too old
 * to keep the app's history entries.
 */

import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import { createActions } from './actions/index.ts';
import type { Actions } from './actions/index.ts';
import { AppClient } from './client/client.ts';
import { applyTheme } from './env.ts';
import { HostLink, readHost } from './host.ts';
import { AppContext } from './state/context.tsx';
import { HistoryLink } from './state/historyLink.ts';
import { createStore } from './state/store.ts';
import { applyStyles } from './styles/apply.ts';

const host = readHost(globalThis);
applyStyles(document);

const root = document.createElement('div');
root.id = 'app';
document.body.append(root);

const store = createStore();

// The client, the actions, the history entries and the link each need another of them. The link
// goes last, because its constructor starts the port, and messages the loader queued begin to
// arrive then. So the others close over `actions` and `link`, which are set below. Both are set
// before any of their calls can run: the client posts and calls back only on a loader message,
// the entries post only when an action moves the route, and the port delivers messages as later
// tasks, never inside the constructor.
let actions!: Actions;
let link!: HostLink;

// The history entries the loader keeps for the app, asked for over the link.
const entries = new HistoryLink((request) => link.postHistory(request));

const client = new AppClient({
  post: (body) => link.postApp(body),
  onEvent: (event) => actions.onEvent(event),
  onUp: () => actions.onChannelUp(),
  onDown: () => actions.onChannelDown(),
});

actions = createActions({
  store,
  client,
  link: { openLink: (url) => link.openLink(url) },
  entries,
  // Wall time, because the ages the app shows are measured from the laptop's Unix timestamps.
  now: () => Date.now(),
});

link = new HostLink(host.port, {
  onApp: (body) => client.handle({ t: 'app', body }),
  onChannel: (up) => client.handle({ t: 'channel', up }),
  onSendFailed: (reason) => client.handle({ t: 'sendFailed', reason }),
  // A route message comes when the frame starts and after each move of the browser's history.
  // Its move count goes on the history requests that follow.
  onRoute: (state, move) => {
    entries.seen(move);
    actions.onRoute(state);
  },
  onEnv: (env) => {
    store.update((s) => ({ ...s, env }));
    applyTheme(document, env.colorScheme);
  },
});

const app = { store, actions };
createRoot(root).render(
  <AppContext.Provider value={app}>
    <App root={root} />
  </AppContext.Provider>,
);
