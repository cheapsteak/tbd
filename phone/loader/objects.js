// Shape checks for values that reach the loader from outside its own code: parsed JSON (the
// laptop's messages, the relay's answers), IndexedDB rows, and objects that cross
// `postMessage`. Each rule is defined once here and named for what it admits, so a call site
// says which one it means. runner.js keeps its own check: it runs alone in the sandbox and
// imports nothing.

/**
 * Any object: not null and not a primitive. Arrays, class instances and built-ins pass.
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
export function isObject(value) {
  return typeof value === 'object' && value !== null;
}

/**
 * A JSON object: any object but an array. Parsed JSON holds no other kind of object, so this
 * is the check for it.
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
export function isPlainObject(value) {
  return isObject(value) && !Array.isArray(value);
}

/**
 * An object literal or a null-prototype object; not an array, a Date, a Map or any other
 * built-in or class instance. Structured clone delivers those across `postMessage`, so this
 * is the check for an app body that comes from the app frame.
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
export function isPlainRecord(value) {
  if (!isObject(value)) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}
