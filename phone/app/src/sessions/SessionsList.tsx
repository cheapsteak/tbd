/**
 * The sessions screen (spec section 8.2, "Sessions"; mock `sessionsHTML`): the laptop's rows,
 * grouped by repo and sorted newest first (`sessionsView`), each with the time since its newest
 * status change and the status of its most urgent session. A tap on a row opens that session; a
 * tap on a group's name collapses or expands it; a repo group's "+" opens New for that repo.
 * A repo with registry-provider sessions has a filter chip after its name, which hides them
 * (`FilterChip`). `SessionsList()` takes no props, and reads the list and acts through the
 * store's context.
 *
 * The status shows as its symbol alone, with the word for screen readers ("Symbol only", the
 * design the mock review chose), so the mock's `.w` word is left out. The ages are read against
 * a clock that moves every 30 s (`useNow`), which renders the list again.
 */

import { useMemo } from 'react';
import type { JSX } from 'react';
import { useActions, useAppState } from '../state/context.tsx';
import { pendingValues } from '../state/remoteFilter.ts';
import { sessionsView } from '../state/sessionsView.ts';
import type { GroupView, RemoteFilterChip, RowView } from '../state/sessionsView.ts';
import { ago, STATUS } from '../state/status.ts';
import { AGE_REFRESH_MS, StatusGlyph } from '../session/StatusGlyph.tsx';
import { Icon } from '../ui/Icon.tsx';
import { useNow } from '../ui/now.ts';
import { filterChipWords } from './filterWords.ts';

export function SessionsList(): JSX.Element {
  const sessions = useAppState((s) => s.sessions);
  const collapsed = useAppState((s) => s.ui.collapsed);
  const lastRowID = useAppState((s) => s.ui.lastRowID);
  const pending = useAppState((s) => s.ui.remoteFilterPending);
  const now = useNow(AGE_REFRESH_MS);
  const groups = useMemo(() => sessionsView(sessions, { lastRowID, pending: pendingValues(pending) }), [sessions, lastRowID, pending]);
  return (
    <>
      <div className="l-head">
        <h1>Sessions</h1>
      </div>
      <div className="list">
        {groups.map((g) => (
          <Group key={g.group.id} view={g} shut={Object.hasOwn(collapsed, g.group.id)} lastRowID={lastRowID} now={now} />
        ))}
        <div className="list-foot">Newest changes first. Shell and note tabs, and archived worktrees, are not shown.</div>
      </div>
    </>
  );
}

function Group({ view, shut, lastRowID, now }: { view: GroupView; shut: boolean; lastRowID: string | null; now: number }): JSX.Element {
  const actions = useActions();
  const { group, repoID, rows, filter } = view;
  return (
    <>
      <div className={filter === null ? 'repo-row' : 'repo-row filt'}>
        <button className="repo" type="button" aria-expanded={rows.length > 0 ? !shut : undefined} onClick={rows.length > 0 ? () => actions.toggleRepo(group.id) : undefined}>
          <Icon name="chev-d" />
          <span className="rn">{group.name}</span>
        </button>
        {repoID !== null && filter !== null && <FilterChip repoID={repoID} chip={filter} />}
        {repoID !== null && (
          <button
            className="repo-add"
            type="button"
            aria-label={`New session in ${group.name}`}
            onClick={() => actions.openSheet({ name: 'new', repoID, repoName: group.name })}
          >
            <Icon name="plus" />
          </button>
        )}
      </div>
      {!shut && rows.length > 0 && (
        <ul className="rows">
          {rows.map((r) => (
            <li key={r.row.id}>
              <Row view={r} selected={r.row.id === lastRowID} now={now} />
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

/**
 * A repo header's filter chip: off, an outlined pill with the outlined funnel and "Hide <name>";
 * on, an accent-tinted pill with the filled funnel and "<count> hidden" (`filterChipWords`). A tap
 * flips it at once (`toggleRemoteFilter`).
 */
function FilterChip({ repoID, chip }: { repoID: string; chip: RemoteFilterChip }): JSX.Element {
  const actions = useActions();
  const words = filterChipWords(chip);
  return (
    <button className="rf" type="button" aria-pressed={chip.on} aria-label={words.label} onClick={() => void actions.toggleRemoteFilter(repoID)}>
      <span className="rf-pill">
        <Icon name={chip.on ? 'filter-on' : 'filter'} />
        <span className="rf-t">{words.text}</span>
      </span>
    </button>
  );
}

function Row({ view, selected, now }: { view: RowView; selected: boolean; now: number }): JSX.Element {
  const actions = useActions();
  const { row, best, count } = view;
  const st = STATUS[best.status.chip];
  return (
    <button className={`row st-${st.cls}${selected ? ' sel' : ''}`} type="button" aria-current={selected ? 'true' : undefined} onClick={() => actions.openSession(best.ref)}>
      <span className="n">
        {row.name}
        {count > 1 && (
          <>
            {' '}
            <small>({count})</small>
          </>
        )}
      </span>
      {row.remote && (
        <span className="rb">
          <Icon name="cloud" />
          remote
        </span>
      )}
      <span className="t">{ago(now, row.statusChangedAt)}</span>
      <span className="g">
        <StatusGlyph chip={best.status.chip} />
        <span className="sr">{st.word}</span>
      </span>
    </button>
  );
}
