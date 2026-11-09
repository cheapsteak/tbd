/**
 * The dock at the bottom of the session screen (mock `sessionHTML`, `.dock`): the card of the
 * prompt waiting in the open session, if any, then the composer. Contract: `Dock({ session })`.
 * The session screen keys it by the session, so a switch to another session mounts it afresh.
 *
 * **Which card.** One at a time, the one `cardFor` picks from the prompt slice: an `elsewhere`
 * card first, since it waits for OK, then one on its way or answered, then the first open prompt
 * in the order the laptop sent. The card is keyed by its prompt's ID, so a new prompt never
 * inherits another's picks, Other text, deny text or hidden state.
 *
 * **No tap lands on a prompt the user has not seen.** Claude often asks for several permissions
 * at once. When one is answered and its resolution takes its card down, the next prompt's card
 * takes its place about one round trip later, so the second tap of a double tap would answer a
 * prompt the user never read. So when the dock replaces the card of one prompt with the card of
 * another, the new card's choices are disabled for `TAP_GUARD_MS` after it appears (`held`). A
 * real `disabled`, so a tap on them does nothing at all. The first card the dock shows, as the
 * session opens, is not held. The prompt shown last is kept across a moment with no card, so a
 * prompt that follows a gap is held too.
 */

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { useAppState } from '../state/context.tsx';
import { cardFor } from '../state/prompts.ts';
import { Composer } from './Composer.tsx';
import { PromptCard } from './PromptCard.tsx';

/** How long a card that took another prompt's place keeps its choices disabled, in milliseconds. */
export const TAP_GUARD_MS = 500;

export function Dock({ session }: { session: PhoneSession }): JSX.Element {
  const prompts = useAppState((s) => s.prompts);
  const ref = session.ref;
  const shown = useMemo(() => cardFor(prompts, ref), [prompts, ref]);
  const id = shown === null ? null : shown.prompt.id;
  const held = useTapGuard(id);
  return (
    <div className="dock">
      {shown !== null && <PromptCard key={shown.prompt.id} session={session} prompt={shown.prompt} card={shown.card} held={held} />}
      <Composer session={session} />
    </div>
  );
}

/**
 * Whether the card of prompt `id` keeps its choices disabled now: from the first render that
 * shows it in place of another prompt's card until `TAP_GUARD_MS` later. The first render is
 * covered by comparing with the prompt shown last before the effect records it, so no frame
 * ever draws the new card's choices enabled; the timer covers the rest.
 */
function useTapGuard(id: string | null): boolean {
  /** The prompt the dock showed last, kept while it shows none. */
  const last = useRef<string | null>(null);
  const [held, setHeld] = useState<string | null>(null);
  const timers = useRef(new Set<ReturnType<typeof setTimeout>>());

  useLayoutEffect(() => {
    if (id === null || last.current === id) return;
    const before = last.current;
    last.current = id;
    if (before === null) return;
    setHeld(id);
    const timer = setTimeout(() => {
      timers.current.delete(timer);
      setHeld((h) => (h === id ? null : h));
    }, TAP_GUARD_MS);
    timers.current.add(timer);
  }, [id]);

  useEffect(() => {
    const pending = timers.current;
    return () => {
      for (const timer of pending) clearTimeout(timer);
      pending.clear();
    };
  }, []);

  if (id === null) return false;
  return held === id || (last.current !== null && last.current !== id);
}
