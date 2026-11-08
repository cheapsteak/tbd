/**
 * The session screen, put together from the parts' components: the header, the status band, the
 * tab strip when the row has more than one session, then either the Codex note or the transcript
 * and the dock, and the header's menus over them.
 *
 * It shows the session the route names. When no row lists that session it renders nothing. That
 * happens only while the list waits for rows a partial snapshot left for later: once the list is
 * complete, the route goes back to the list with the update that left the session out
 * (`resolveRoute`).
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
import { useAppState } from '../state/context.tsx';
import { findSession } from '../state/route.ts';
import { TranscriptView } from '../transcript/TranscriptView.tsx';

export function SessionScreen(): JSX.Element | null {
  const route = useAppState((s) => s.ui.route);
  const sessions = useAppState((s) => s.sessions);
  const found = useMemo(() => (route.screen === 'session' ? findSession(sessions, route.ref) : null), [route, sessions]);
  if (found === null) return null;
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
