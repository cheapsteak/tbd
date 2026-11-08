/**
 * The session screen, put together from the parts' components: the header, the status band, the
 * tab strip when the row has more than one session, then either the Codex note or the transcript
 * and the dock, and the header's menus over them.
 *
 * It shows the session the route names. No row may list that session yet while the list waits
 * for rows a partial snapshot left for later, since one of them may hold it. Then it shows a
 * header of its own with the back button, over the loading screen's spinner: `SessionHeader`
 * needs a row and a session. Once the list is complete, the route goes back to the list with
 * the update that left the session out (`resolveRoute`).
 */

import { useMemo } from 'react';
import type { JSX } from 'react';
import { Dock } from '../dock/Dock.tsx';
import { Menus } from '../menus/Menus.tsx';
import { refKey } from '../protocol/wire.ts';
import { CodexNote } from '../session/CodexNote.tsx';
import { SessionHeader } from '../session/SessionHeader.tsx';
import { StatusBand } from '../session/StatusBand.tsx';
import { TabStrip } from '../session/TabStrip.tsx';
import { useActions, useAppState } from '../state/context.tsx';
import { findSession } from '../state/route.ts';
import { TranscriptView } from '../transcript/TranscriptView.tsx';
import { Icon } from '../ui/Icon.tsx';

export function SessionScreen(): JSX.Element | null {
  const route = useAppState((s) => s.ui.route);
  const sessions = useAppState((s) => s.sessions);
  const found = useMemo(() => (route.screen === 'session' ? findSession(sessions, route.ref) : null), [route, sessions]);
  if (found === null) return route.screen === 'session' ? <SessionWaiting /> : null;
  const { row, session } = found;
  // Keyed by the session, so a switch to another tab starts the transcript and the dock afresh
  // rather than carrying one session's scroll or half-chosen answer over to the next.
  const key = refKey(session.ref);
  return (
    <>
      <SessionHeader row={row} session={session} />
      <StatusBand session={session} />
      {row.sessions.length > 1 && <TabStrip row={row} session={session} />}
      {session.agent === 'codex' ? (
        <CodexNote />
      ) : (
        <>
          <TranscriptView key={`transcript ${key}`} session={session} />
          <Dock key={`dock ${key}`} session={session} />
        </>
      )}
      <Menus session={session} />
    </>
  );
}

/** The screen while no row lists the route's session yet: back, and the loading screen's spinner. */
function SessionWaiting(): JSX.Element {
  const actions = useActions();
  return (
    <>
      <div className="s-head">
        <button className="ib" type="button" aria-label="Back to sessions" onClick={() => actions.back()}>
          <Icon name="chev-l" />
        </button>
      </div>
      <div className="center" data-state="session-waiting">
        <span className="spin" />
      </div>
    </>
  );
}
