/**
 * The bundle's entry point. The runner starts it as one classic script, with the loader port on
 * the global (`phone/loader/runner.js`). It wires the store, the protocol client, the actions and
 * the loader link together, then mounts React into `#app`.
 *
 * A throw here, before React mounts, is a top-level error in the bundle, which the runner reports
 * to the loader as `fault: 'script'`; the loader then shows "Reload this page". `readHost` throws
 * so when the runner's handle is missing or speaks another protocol.
 */

import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import { createActions } from './actions/index.ts';
import type { Actions } from './actions/index.ts';
import { AppClient } from './client/client.ts';
import { applyTheme } from './env.ts';
import { HostLink, readHost } from './host.ts';
import { AppContext } from './state/context.tsx';
import { RouteHistory, windowHistory } from './state/history.ts';
import { createStore } from './state/store.ts';
import { applyStyles } from './styles/apply.ts';

const host = readHost(globalThis);
applyStyles(document);

const root = document.createElement('div');
root.id = 'app';
document.body.append(root);

const store = createStore();
// The frame's current history entry becomes the app's first, showing the route the app starts on.
const routeHistory = new RouteHistory(windowHistory(window), store.get().ui.route);

// The client, the actions and the link each need another of them. The link goes last, because
// its constructor starts the port, and messages the loader queued begin to arrive then. So the
// client and the actions close over `actions` and `link`, which are set below. Both are set
// before any of their calls can run: the client posts and calls back only on a loader message,
// and the port delivers messages as later tasks, never inside the constructor.
let actions!: Actions;
let link!: HostLink;

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
  routeHistory,
  // Wall time, because the ages the app shows are measured from the laptop's Unix timestamps.
  now: () => Date.now(),
});

// The browser's back and forward buttons, and `back`, move between the app's entries.
routeHistory.onPop((route) => actions.onPopState(route));

link = new HostLink(host.port, {
  onApp: (body) => client.handle({ t: 'app', body }),
  onChannel: (up) => client.handle({ t: 'channel', up }),
  onSendFailed: (reason) => client.handle({ t: 'sendFailed', reason }),
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
