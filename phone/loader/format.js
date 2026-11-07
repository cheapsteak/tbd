/**
 * Formats a 6-digit confirmation code for display: '012345' becomes '012 345'.
 * @param {string} code
 * @returns {string}
 */
export function formatCode(code) {
  return `${code.slice(0, 3)} ${code.slice(3)}`;
}
