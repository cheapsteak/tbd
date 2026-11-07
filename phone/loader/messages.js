import { formatCode } from './format.js';

/** User-facing strings. The first five are spec 8.1 copy, verbatim. */
export const MESSAGES = Object.freeze({
  offline: 'Laptop offline',
  updateTBD: 'Update TBD on this laptop',
  reload: 'Reload this page',
  /** @param {string} name */
  removed: (name) => `This phone was removed from ${name}`,
  relay: "Can't reach the relay",
  replaced: 'Connected in another tab',
  /** @param {string} name */
  keyMissing: (name) => `This phone's key for ${name} is missing. Forget it and pair again.`,
  denied: 'Pairing was declined on the laptop.',
  expired: 'This pairing code expired. Make a new one on the laptop.',
  invalidCode: 'This pairing code is no longer valid. Make a new one on the laptop.',
  notLink: 'This is not a TBD pairing link.',
  damagedLink: 'This pairing link is damaged. Make a new one on the laptop.',
  camera: 'Camera unavailable. Paste the link instead.',
  badName: 'Use 1 to 64 letters, with no control characters.',
  /** @param {string} code */
  checkCode: (code) => `Check this code on your laptop: ${formatCode(code)}`,
});
