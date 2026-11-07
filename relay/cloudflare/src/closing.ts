// The closing mark: internal to the relay. The room and the tests import it;
// the Worker's entry re-exports nothing from it.

/**
 * The mark on a socket the relay is closing. It is the socket's attachment,
 * which the runtime keeps with the socket across hibernation, so the room tells
 * a closing socket from a live one by the mark as well as by `readyState`.
 *
 * An attachment is allowed under the rule that the relay stores nothing. The
 * rule keeps out the object's own SQLite database, alarms, timers and outbound
 * requests. An attachment is none of them: it holds one flag and no content,
 * it lives only with its socket, and it goes when the socket goes.
 */
export interface ClosingMark {
  readonly closing: true;
}

const CLOSING_MARK: ClosingMark = { closing: true };

/**
 * Marks `ws` as a socket the relay is closing. The room marks a socket before
 * it closes one; a test marks one without closing it.
 */
export function markClosing(ws: WebSocket): void {
  try {
    ws.serializeAttachment(CLOSING_MARK);
  } catch {
    // The socket closed meanwhile; its `readyState` already leaves it out.
  }
}

/** Whether `ws` carries the closing mark. */
export function isMarkedClosing(ws: WebSocket): boolean {
  const attachment: unknown = ws.deserializeAttachment();
  return typeof attachment === "object" && attachment !== null && "closing" in attachment && attachment.closing === true;
}
