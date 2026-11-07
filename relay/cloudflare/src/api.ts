// Relay API v1. A stable contract: TBD supports it for good.

export const RELAY_NAME = "tbd-relay";
export const RELAY_VERSION = "1.0.0";
export const API_VERSIONS: readonly number[] = [1];

/** 32 bytes as base64url without padding. */
export const ROOM_ID_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** The largest binary frame the relay forwards: one 65,535-byte Noise message fits. */
export const MAX_FRAME_BYTES = 65_536;

/** Sent to a socket that a newer socket of the same role replaced. */
export const CLOSE_REPLACED = { code: 4000, reason: "replaced" } as const;
/** Sent to a socket that sent a binary frame over MAX_FRAME_BYTES. */
export const CLOSE_TOO_LARGE = { code: 1009, reason: "frame too large" } as const;

/** Relay signals are text frames, so they cannot be confused with forwarded binary frames. */
export const SIGNAL = {
  peerJoined: "peer-joined",
  peerLeft: "peer-left",
  peerAbsent: "peer-absent",
} as const;

/** Keepalive, answered by the runtime's WebSocket auto-response without waking the object. */
export const PING = "ping";
export const PONG = "pong";

export type Role = "laptop" | "phone";

export function isRole(value: string | undefined): value is Role {
  return value === "laptop" || value === "phone";
}

/** The role of a room URL: exactly one `role` parameter, equal to `laptop` or `phone`. */
export function parseRole(url: URL): Role | null {
  const roles = url.searchParams.getAll("role");
  if (roles.length !== 1) return null;
  const role = roles[0];
  return isRole(role) ? role : null;
}

export function otherRole(role: Role): Role {
  return role === "laptop" ? "phone" : "laptop";
}
