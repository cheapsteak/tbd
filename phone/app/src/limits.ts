/**
 * The frame and request limits the app keeps, each the mirror of a limit the loader or the
 * daemon enforces. The app checks them before it posts, because the loader's refusal of an
 * oversized body (`sendFailed: tooLarge`) carries no request ID: a request it refused would
 * otherwise wait for a reply that never comes.
 */

/** The most plaintext one Noise transport message carries (`MAX_PLAINTEXT_LENGTH` in `phone/loader/channel/noise.js`). */
export const MAX_PLAINTEXT = 65_519;

/**
 * The bytes the loader's `{"type":"app","body":…}` adds around an app body: 21 before it and
 * the closing brace after (`PhoneFrameBudget.loaderWrapperBytes` on the daemon's side).
 */
export const LOADER_WRAPPER_BYTES = 22;

/** The most UTF-8 bytes of JSON one app body may take: 65,497. */
export const MAX_BODY_BYTES = MAX_PLAINTEXT - LOADER_WRAPPER_BYTES;

/** The daemon refuses a request past this many running at once from one phone (`PhoneAppConstants.requestsInFlightPerDevice`). */
export const MAX_IN_FLIGHT = 32;

/**
 * How long after its first send an acting request may be sent again. The daemon remembers a
 * request ID for 600 s (`PhoneAppConstants.requestMemory`), so a resend inside that window
 * does nothing twice; 540 s leaves a minute of margin for clocks and transit.
 */
export const RESEND_HORIZON_MS = 540_000;

/**
 * The length of `s` in UTF-8, counted as `TextEncoder` encodes it, without making the bytes.
 * A surrogate pair is one 4-byte scalar. A lone surrogate becomes U+FFFD, 3 bytes.
 */
export function utf8Length(s: string): number {
  let bytes = 0;
  for (let i = 0; i < s.length; i++) {
    const unit = s.charCodeAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < s.length && isLowSurrogate(s.charCodeAt(i + 1))) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/**
 * Whether the loader will send `body` in one frame. It measures the body the way the loader's
 * check does (`sendApp` in `phone/loader/connection.js`: `JSON.stringify`, then UTF-8), less
 * the constant wrapper. A body that JSON cannot encode, such as one with a cycle or a BigInt,
 * never fits: the loader reports it as `tooLarge` too.
 *
 * The body must be JSON-shaped plain data. The loader measures the structured clone of what
 * the app posts, not the app's own object, so the two agree only on plain data: a class
 * instance's `toJSON` is gone from the clone, and a function cannot be posted at all.
 */
export function fitsFrame(body: Record<string, unknown>): boolean {
  let json: string | undefined;
  try {
    json = JSON.stringify(body);
  } catch {
    return false;
  }
  // A body whose toJSON returns undefined has no JSON; the loader would drop it from the wrapper.
  if (typeof json !== 'string') return false;
  return utf8Length(json) <= MAX_BODY_BYTES;
}

function isLowSurrogate(unit: number): boolean {
  return unit >= 0xdc00 && unit <= 0xdfff;
}
