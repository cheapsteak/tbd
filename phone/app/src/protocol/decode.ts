/**
 * Decoder combinators for the app protocol. The laptop's bodies are untrusted input: the loader
 * hands them on unread, and a later part renders them. So every decoder checks each value's
 * type and builds a fresh value from the fields it knows. It never spreads, copies or returns
 * the input object, and it drops fields it does not know.
 *
 * Each decoder is `(raw, path) => T`, and throws `DecodeError` naming the dotted path of the
 * value it refused, such as `rows[2].sessions[0].status.chip`. The path is relative to the
 * value decoded, so a result's paths do not start with `result`.
 *
 * The rules the daemon's encoder keeps (`PhoneAppCoding.makeEncoder`) are the rules here:
 * - An absent optional field stays absent. The daemon never writes `null`, so a `null` is
 *   refused wherever it appears (`nullableNever`).
 * - Integers pass `Number.isSafeInteger`.
 * - A string-valued enum outside its list is refused (`oneOf`).
 */

/** Decodes one value at `path`, or throws `DecodeError`. */
export type Decoder<T> = (raw: unknown, path?: string) => T;

/** A value the decoders refused, with the dotted path to it. */
export class DecodeError extends Error {
  /** The dotted path of the refused value, `''` for the value decoded itself. */
  readonly path: string;

  constructor(path: string, problem: string) {
    super(path === '' ? problem : `${path}: ${problem}`);
    this.name = 'DecodeError';
    this.path = path;
  }
}

/** The path of field `key` under `path`. */
export function fieldPath(path: string, key: string): string {
  return path === '' ? key : `${path}.${key}`;
}

/** Longest stretch of a refused string quoted in an error message. */
const QUOTE_LIMIT = 64;

/** A short description of `raw` for an error message. */
function describe(raw: unknown): string {
  if (raw === null) return 'null';
  if (Array.isArray(raw)) return 'an array';
  if (typeof raw === 'string') {
    const quoted = JSON.stringify(raw.length > QUOTE_LIMIT ? `${raw.slice(0, QUOTE_LIMIT)}…` : raw);
    return `the string ${quoted}`;
  }
  if (typeof raw === 'number') return `the number ${String(raw)}`;
  return typeof raw;
}

export const str: Decoder<string> = (raw, path = '') => {
  if (typeof raw !== 'string') throw new DecodeError(path, `expected a string, got ${describe(raw)}`);
  return raw;
};

export const int: Decoder<number> = (raw, path = '') => {
  if (typeof raw !== 'number' || !Number.isSafeInteger(raw)) {
    throw new DecodeError(path, `expected a safe integer, got ${describe(raw)}`);
  }
  return raw;
};

export const bool: Decoder<boolean> = (raw, path = '') => {
  if (typeof raw !== 'boolean') throw new DecodeError(path, `expected a boolean, got ${describe(raw)}`);
  return raw;
};

/** A string that must be one of `values`. */
export function oneOf<K extends string>(values: readonly K[]): Decoder<K> {
  return (raw, path = '') => {
    const s = str(raw, path);
    if (!(values as readonly string[]).includes(s)) {
      throw new DecodeError(path, `${describe(s)} is not one of ${values.join(', ')}`);
    }
    return s as K;
  };
}

/** An array whose every element `item` decodes, as a new array. */
export function arr<T>(item: Decoder<T>): Decoder<T[]> {
  return (raw, path = '') => {
    if (!Array.isArray(raw)) throw new DecodeError(path, `expected an array, got ${describe(raw)}`);
    const out: T[] = [];
    for (let i = 0; i < raw.length; i++) out.push(item(raw[i], `${path}[${i}]`));
    return out;
  };
}

/** `raw` as an object to read fields from, or a `DecodeError` when it is not a JSON object. */
export function plainObject(raw: unknown, path = ''): Readonly<Record<string, unknown>> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new DecodeError(path, `expected an object, got ${describe(raw)}`);
  }
  return raw as Record<string, unknown>;
}

/**
 * Whether `o` holds field `key` itself. Inherited fields never count, so a field is never read
 * from a prototype. An `undefined` value counts as absent: JSON has none, and an object the app
 * built may hold one for a field it left out.
 */
export function has(o: Readonly<Record<string, unknown>>, key: string): boolean {
  return Object.hasOwn(o, key) && o[key] !== undefined;
}

/** Field `key` of `o`, decoded by `decode`; a `DecodeError` names it when it is missing. */
export function field<T>(o: Readonly<Record<string, unknown>>, key: string, decode: Decoder<T>, path: string): T {
  const at = fieldPath(path, key);
  if (!has(o, key)) throw new DecodeError(at, 'is missing');
  return decode(o[key], at);
}

/**
 * The decoder for an optional field's value: `null` is refused, everything else goes to
 * `decode`. The daemon leaves a nil optional out and never writes `null`, so a `null` means the
 * body did not come from it.
 */
export function nullableNever<T>(decode: Decoder<T>): Decoder<T> {
  return (raw, path = '') => {
    if (raw === null) throw new DecodeError(path, 'is null; the daemon leaves an absent field out instead');
    return decode(raw, path);
  };
}

/** The keys of `T` that are not optional. */
type RequiredKeys<T> = { [K in keyof T]-?: {} extends Pick<T, K> ? never : K }[keyof T];
/** The keys of `T` that are optional. */
type OptionalKeys<T> = Exclude<keyof T, RequiredKeys<T>>;

/**
 * An object with the fields `T` names. Pass `T` explicitly: the compiler then checks that
 * `required` lists exactly `T`'s required fields and `optional` exactly its optional ones.
 *
 * Fields neither table names are dropped. An optional field that is absent stays absent: it is
 * never set to `undefined`, and a `null` is refused.
 */
export function obj<T>(
  required: { readonly [K in RequiredKeys<T>]: Decoder<T[K]> },
  optional: { readonly [K in OptionalKeys<T>]: Decoder<Exclude<T[K], undefined>> },
): Decoder<T> {
  const requiredFields = Object.entries(required) as Array<[string, Decoder<unknown>]>;
  const optionalFields = (Object.entries(optional) as Array<[string, Decoder<unknown>]>)
    .map(([key, decode]): [string, Decoder<unknown>] => [key, nullableNever(decode)]);
  return (raw, path = '') => {
    const o = plainObject(raw, path);
    // Every key written here is a name from the two tables above, never one from the wire.
    const out: Record<string, unknown> = {};
    for (const [key, decode] of requiredFields) out[key] = field(o, key, decode, path);
    for (const [key, decode] of optionalFields) {
      if (has(o, key)) out[key] = decode(o[key], fieldPath(path, key));
    }
    return out as T;
  };
}

/**
 * A string-keyed map whose every value `value` decodes, such as a question answer's `answers`.
 * Its keys come from the wire, so the map is built on a null prototype and each entry is
 * defined, never assigned. A key such as `__proto__` or `constructor`, which `JSON.parse` keeps
 * as an ordinary own key, then stays an ordinary entry: it cannot set the map's prototype or
 * reach `Object.prototype`. Such keys are kept, not refused, because the daemon accepts any
 * key, and a question's text is the key of its answer.
 */
export function record<T>(value: Decoder<T>): Decoder<Record<string, T>> {
  return (raw, path = '') => {
    const o = plainObject(raw, path);
    const out = Object.create(null) as Record<string, T>;
    for (const key of Object.keys(o)) {
      Object.defineProperty(out, key, {
        value: value(o[key], `${path}[${JSON.stringify(key)}]`),
        enumerable: true,
        writable: true,
        configurable: true,
      });
    }
    return out;
  };
}
