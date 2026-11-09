// The loader's screens and its header strip, built to the reviewed mocks
// (docs/design/phone-control/phone-control-mocks.html, the Loader group): the same elements,
// classes and words, with the styles in loader.css.
//
// Everything is built with createElement and text nodes through `h()`. The page's policy
// forbids inline styles and requires Trusted Types for scripts, so no markup is ever parsed
// from a string, and `h()` takes only the props listed below.
//
// Each screen's root carries `data-state`, named as in the mock's state index (`laptops`,
// `forget-ask`, `scan`, `paste`, `name`, `code`, …), so tests can wait for a state by name.

import { MESSAGES } from './messages.js';

const SVG_NS = 'http://www.w3.org/2000/svg';

/** @typedef {Node | string | null | undefined | false} Leaf */
/** @typedef {Leaf | ReadonlyArray<Leaf>} Child */
/** @typedef {Record<string, unknown>} Props */
/** @typedef {{ dot: 'on' | 'off' | null, text: string }} StatusLine */
/**
 * A row's handle: shows a new status line in place, without rebuilding the row, so a tap in
 * progress and the list's scroll position survive a presence answer.
 * @typedef {{ setLine(line: StatusLine): void }} RowHandle
 */
/** @typedef {'err' | 'rate' | 'idle' | 'work'} Tone */

/** Props set as attributes, as given. */
const ATTRIBUTES = new Set([
  'id', 'type', 'for', 'name', 'autocomplete', 'role', 'placeholder', 'rows', 'data-state',
  'autocapitalize', 'spellcheck', 'enterkeyhint',
]);

/** Props that add an event listener. */
const LISTENERS = new Map([
  ['onClick', 'click'],
  ['onSubmit', 'submit'],
  ['onInput', 'input'],
  ['onKeyDown', 'keydown'],
]);

/**
 * Builds one element. Children that are strings become text nodes; null, undefined and false
 * are skipped, and arrays are flattened. Props: `class`, `hidden`, `disabled`, `value`,
 * `inputMode`, any `aria-*`, the attributes in ATTRIBUTES, and the listeners `onClick`,
 * `onSubmit`, `onInput` and `onKeyDown`. Anything else throws, so no style, handler text or
 * markup can be passed in by mistake.
 * @template {keyof HTMLElementTagNameMap} K
 * @param {K} tag
 * @param {Props | null} [props]
 * @param {...Child} children
 * @returns {HTMLElementTagNameMap[K]}
 * @throws {TypeError} for a prop that is not allowed, or a listener that is not a function
 */
export function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) setProp(el, key, value);
  }
  appendChildren(el, children);
  return el;
}

/**
 * @param {HTMLElement} el
 * @param {string} key
 * @param {unknown} value
 */
function setProp(el, key, value) {
  if (value === undefined || value === null) return;
  const event = LISTENERS.get(key);
  if (event !== undefined) {
    if (typeof value !== 'function') throw new TypeError(`h: ${key} must be a function`);
    el.addEventListener(event, /** @type {EventListener} */ (value));
    return;
  }
  switch (key) {
    case 'class':
      el.className = String(value);
      return;
    case 'hidden':
      el.hidden = Boolean(value);
      return;
    case 'disabled':
      /** @type {HTMLButtonElement} */ (el).disabled = Boolean(value);
      return;
    case 'value':
      /** @type {HTMLInputElement} */ (el).value = String(value);
      return;
    case 'inputMode':
      el.setAttribute('inputmode', String(value));
      return;
    default:
  }
  if (ATTRIBUTES.has(key) || /^aria-[a-z]+$/.test(key)) {
    el.setAttribute(key, String(value));
    return;
  }
  throw new TypeError(`h: ${key} is not an allowed prop`);
}

/**
 * @param {Element} el
 * @param {ReadonlyArray<Child>} children
 */
function appendChildren(el, children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    if (Array.isArray(child)) {
      appendChildren(el, /** @type {ReadonlyArray<Child>} */ (child));
    } else {
      el.append(/** @type {Node | string} */ (child));
    }
  }
}

// --- icons ------------------------------------------------------------------------------

/**
 * The glyphs of the mock's SVG sprite that the loader uses, as [tag, attributes] pairs on a
 * 24 × 24 view box.
 * @type {Readonly<Record<string, ReadonlyArray<[string, Record<string, string>]>>>}
 */
const GLYPHS = Object.freeze({
  laptop: [['rect', { x: '4', y: '5', width: '16', height: '11', rx: '1.5' }], ['path', { d: 'M2 19h20' }]],
  'chev-d': [['path', { d: 'm6 9 6 6 6-6' }]],
  check: [['path', { d: 'm5 12.5 4.5 4.5L19 7.5' }]],
  plus: [['path', { d: 'M12 5v14' }], ['path', { d: 'M5 12h14' }]],
  download: [['path', { d: 'M12 3v12' }], ['path', { d: 'm7 10 5 5 5-5' }], ['path', { d: 'M5 21h14' }]],
  link: [
    ['path', { d: 'M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7' }],
    ['path', { d: 'M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7' }],
  ],
  x: [['path', { d: 'M18 6 6 18M6 6l12 12' }]],
  glass: [
    ['path', { d: 'M5 22h14' }], ['path', { d: 'M5 2h14' }],
    ['path', { d: 'M17 22v-4.17a2 2 0 0 0-.59-1.42L12 12l-4.41 4.41A2 2 0 0 0 7 17.83V22' }],
    ['path', { d: 'M7 2v4.17a2 2 0 0 0 .59 1.42L12 12l4.41-4.41A2 2 0 0 0 17 6.17V2' }],
  ],
  moon: [['path', { d: 'M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z' }]],
  refresh: [['path', { d: 'M21 12a9 9 0 1 1-3-6.7L21 8' }], ['path', { d: 'M21 3v5h-5' }]],
  'wifi-off': [
    ['path', { d: 'M2 2l20 20' }], ['path', { d: 'M8.5 16.5a5 5 0 0 1 7 0' }],
    ['path', { d: 'M5 12.9a10 10 0 0 1 5.2-2.8' }], ['path', { d: 'M19 12.9a10 10 0 0 0-2.3-1.6' }],
    ['path', { d: 'M2 8.8a15 15 0 0 1 4.2-2.6' }], ['path', { d: 'M22 8.8A15 15 0 0 0 11 5' }],
    ['path', { d: 'M12 20h.01' }],
  ],
  warn: [
    ['path', { d: 'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z' }],
    ['path', { d: 'M12 9v4' }], ['path', { d: 'M12 17h.01' }],
  ],
  swap: [
    ['path', { d: 'M7 4 3 8l4 4' }], ['path', { d: 'M3 8h14' }],
    ['path', { d: 'm17 20 4-4-4-4' }], ['path', { d: 'M21 16H7' }],
  ],
});

/**
 * One glyph as an inline SVG, sized by the font size like the mock's `svg.i`.
 * @param {keyof typeof GLYPHS} name
 * @param {string} [cls] an extra class, such as `car` or `tick`
 * @returns {SVGSVGElement}
 */
export function icon(name, cls) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', cls ? `i ${cls}` : 'i');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  for (const [tag, attributes] of GLYPHS[name]) {
    const shape = document.createElementNS(SVG_NS, tag);
    for (const [key, value] of Object.entries(attributes)) shape.setAttribute(key, value);
    svg.append(shape);
  }
  return svg;
}

// --- shared pieces ----------------------------------------------------------------------

/**
 * The bar at the top of a pairing screen: a text button on the left and the title.
 * @param {string} title
 * @param {string} left
 * @param {() => void} onLeft
 */
function nav(title, left, onLeft) {
  return h('div', { class: 'ld-nav' },
    h('button', { class: 'navbtn', type: 'button', onClick: onLeft }, left),
    h('b', null, title),
    h('span'));
}

/**
 * An inline error, styled as the mock's composer refusal; nothing without one.
 * @param {string | null} text
 */
function refusal(text) {
  return text === null ? null : h('div', { class: 'refusal', role: 'alert' }, icon('warn'), h('span', null, text));
}

/**
 * A form's submit listener: hands `field`'s value to `onSubmit` instead of submitting.
 * @param {HTMLInputElement | HTMLTextAreaElement} field
 * @param {(value: string) => void} onSubmit
 * @returns {(event: Event) => void}
 */
function submitValue(field, onSubmit) {
  return (event) => {
    event.preventDefault();
    onSubmit(field.value);
  };
}

/**
 * A status line: an Online/Offline dot when known, and the text.
 * @param {StatusLine} line
 * @returns {Array<HTMLElement | string>}
 */
function statusParts(line) {
  return line.dot === null ? [line.text] : [h('i', { class: line.dot === 'on' ? 'odot on' : 'odot' }), line.text];
}

/**
 * The `<small>` status line of a Laptops row or a menu item, and its handle.
 * @param {StatusLine} line
 * @returns {{ node: HTMLElement, handle: RowHandle }}
 */
function statusSmall(line) {
  const node = h('small', null, statusParts(line));
  return { node, handle: { setLine: (next) => node.replaceChildren(...statusParts(next)) } };
}

/** The handle of a row that shows no status line, such as one asking to Forget. */
const NO_LINE = Object.freeze({ setLine() {} });

// --- Laptops ----------------------------------------------------------------------------

/**
 * @typedef {object} LaptopRow
 * @property {string} name The laptop's name, or "this laptop" for a damaged record without one.
 * @property {StatusLine} line
 * @property {boolean} asking Whether this row shows its Forget confirmation.
 * @property {(() => void) | null} onOpen Connects to the laptop; null for a damaged record.
 * @property {() => void} onForget Asks for confirmation.
 * @property {() => void} onConfirm
 * @property {() => void} onCancel
 */

/**
 * The Laptops screen: "Pair a laptop", one row per laptop, and the Home Screen hint.
 * @param {{ rows: LaptopRow[], onPair: () => void }} model
 * @returns {{ root: HTMLElement, rows: RowHandle[] }} `rows[i]` updates the status line of
 *   `model.rows[i]` in place; for a row asking to Forget it does nothing
 */
export function renderLaptops({ rows, onPair }) {
  const asking = rows.some((row) => row.asking);
  /** @type {RowHandle[]} */
  const handles = [];
  /** @param {LaptopRow} row */
  const item = (row) => {
    if (row.asking) {
      handles.push(NO_LINE);
      return h('li', null, renderConfirm({ name: row.name, onForget: row.onConfirm, onCancel: row.onCancel }));
    }
    const status = statusSmall(row.line);
    handles.push(status.handle);
    const body = [icon('laptop'), h('span', null, h('b', null, row.name), status.node)];
    return h('li', null,
      row.onOpen === null
        ? h('div', { class: 'lap-row' }, body)
        : h('button', { class: 'lap-row', type: 'button', onClick: row.onOpen }, body),
      h('button', { class: 'forget', type: 'button', 'aria-label': `Forget ${row.name}`, onClick: row.onForget }, 'Forget'));
  };
  const list = rows.length === 0
    ? h('p', null, 'No laptops yet. Pair one to start.')
    : h('ul', { class: 'lap' }, rows.map(item));
  const root = h('div', { class: 'ld', 'data-state': asking ? 'forget-ask' : 'laptops' },
    h('div', { class: 'ld-head' }, h('h1', null, 'Laptops')),
    h('div', { class: 'ld-body' },
      h('button', { class: 'btn pri wide', type: 'button', onClick: onPair }, icon('plus'), 'Pair a laptop'),
      list,
      h('p', { class: 'homehint' }, icon('download'), h('span', null, MESSAGES.homeScreenHint))));
  return { root, rows: handles };
}

/**
 * The Forget confirmation, as the mock asks it on a Laptops row.
 * @param {{ name: string, onForget: () => void, onCancel: () => void }} model
 * @returns {HTMLElement}
 */
export function renderConfirm({ name, onForget, onCancel }) {
  return h('div', { class: 'ask' },
    h('p', null, h('b', null, `Forget ${name}?`), ' This phone deletes its keys for that laptop. You can pair again later.'),
    h('div', null,
      h('button', { class: 'btn danger', type: 'button', onClick: onForget }, 'Forget'),
      h('button', { class: 'btn', type: 'button', onClick: onCancel }, 'Cancel')));
}

// --- Pairing ----------------------------------------------------------------------------

/**
 * The pair screen: the camera view, the way to the laptop's pairing code, and "Paste link
 * instead". The caller starts the scanner on the returned `video`.
 * @param {{ error: string | null, onCancel: () => void, onPaste: () => void }} model
 * @returns {{ root: HTMLElement, video: HTMLVideoElement }}
 */
export function renderPairStart({ error, onCancel, onPaste }) {
  const video = h('video', { class: 'feed', 'aria-hidden': 'true' });
  video.muted = true;
  video.playsInline = true;
  const root = h('div', { class: 'ld', 'data-state': 'scan' },
    nav('Pair a laptop', 'Cancel', onCancel),
    h('div', { class: 'ld-body' },
      h('div', { class: 'cam', role: 'img', 'aria-label': 'Camera view' }, video, h('span', { class: 'brk' })),
      refusal(error),
      h('p', null, 'On the laptop, open TBD Settings, then Phone, then ', h('b', null, 'Pair a Phone…'),
        ' Point this camera at the code it shows.'),
      h('button', { class: 'btn wide', type: 'button', onClick: onPaste }, icon('link'), 'Paste link instead')));
  return { root, video };
}

/**
 * The paste screen: a field for the pairing link the laptop shows as text.
 * @param {{ error: string | null, value: string, onBack: () => void, onSubmit: (text: string) => void }} model
 * @returns {{ root: HTMLElement, field: HTMLTextAreaElement }}
 */
export function renderPaste({ error, value, onBack, onSubmit }) {
  const field = h('textarea', {
    id: 'paste-link', class: 'ta', rows: '3', placeholder: 'https://…/#…', value,
    autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
  });
  const root = h('div', { class: 'ld', 'data-state': 'paste' },
    nav('Paste link', 'Back', onBack),
    h('form', { class: 'ld-body', onSubmit: submitValue(field, onSubmit) },
      h('p', null, 'On the laptop, the pairing sheet shows the same link as text. Copy it there, then paste it here.'),
      h('label', { class: 'sr', for: 'paste-link' }, 'Pairing link'),
      field,
      refusal(error),
      h('button', { class: 'btn pri wide', type: 'submit' }, 'Continue')));
  return { root, field };
}

/**
 * The name screen: the name the laptop shows when it asks to allow this phone.
 * @param {{ laptopName: string, value: string, error: string | null, onBack: () => void,
 *   onSubmit: (name: string) => void }} model
 * @returns {{ root: HTMLElement, field: HTMLInputElement }}
 */
export function renderName({ laptopName, value, error, onBack, onSubmit }) {
  const field = h('input', {
    id: 'phone-name', type: 'text', value, autocomplete: 'off', enterkeyhint: 'go',
  });
  const root = h('div', { class: 'ld', 'data-state': 'name' },
    nav('Name this phone', 'Back', onBack),
    h('form', { class: 'ld-body', onSubmit: submitValue(field, onSubmit) },
      h('p', null, 'Found ', h('b', null, laptopName), '. The laptop shows this name when it asks you to allow this phone.'),
      h('div', { class: 'group' }, h('div', { class: 'frow' }, h('label', { for: 'phone-name' }, 'Phone name'), field)),
      refusal(error),
      h('button', { class: 'btn pri wide', type: 'submit' }, 'Continue')));
  return { root, field };
}

/**
 * `MESSAGES.checkCode(code)` split at its `': '`: the lead, and the code as shown.
 * @param {string} code
 * @returns {{ lead: string, shown: string }}
 */
function checkCodeParts(code) {
  const text = MESSAGES.checkCode(code);
  const at = text.indexOf(': ');
  return at < 0 ? { lead: text, shown: '' } : { lead: text.slice(0, at), shown: text.slice(at + 2) };
}

/**
 * The code screen. Until the laptop answers, `code` is null and the screen waits for it
 * (`data-state="pairing"`). Then it shows the code to compare and waits for Allow. The lead
 * and the code are `MESSAGES.checkCode(code)` in two parts, so together they read as exactly
 * that sentence.
 * @param {{ laptopName: string, phoneName: string, code: string | null, onCancel: () => void }} model
 * @returns {HTMLElement}
 */
export function renderCode({ laptopName, phoneName, code, onCancel }) {
  if (code === null) {
    return h('div', { class: 'ld', 'data-state': 'pairing' },
      nav('Confirm', 'Cancel', onCancel),
      h('div', { class: 'ld-body' },
        h('div', { class: 'waitline', role: 'status' }, h('span', { class: 'spin' }), `Connecting to ${laptopName}…`)));
  }
  const { lead, shown } = checkCodeParts(code);
  return h('div', { class: 'ld', 'data-state': 'code' },
    nav('Confirm', 'Cancel', onCancel),
    h('div', { class: 'ld-body' },
      h('div', { class: 'check' },
        h('p', { class: 'lead' }, lead, h('span', { class: 'sr' }, ': ')),
        h('div', { class: 'code', 'aria-label': code.split('').join(' ') }, shown)),
      h('p', { class: 'c' }, `The laptop asks: "Allow '${phoneName}' to control this laptop?" Choose `,
        h('b', null, 'Allow'), ' there if the codes match.'),
      h('div', { class: 'waitline', role: 'status' }, h('span', { class: 'spin' }), `Waiting for Allow on ${laptopName}…`)));
}

// --- messages ---------------------------------------------------------------------------

/**
 * @typedef {object} Action
 * @property {string} label
 * @property {'pri' | 'danger'} [kind]
 * @property {() => void} onClick
 */

/**
 * @typedef {object} MessageModel
 * @property {string} state The `data-state` name.
 * @property {Tone} tone
 * @property {keyof typeof GLYPHS} icon
 * @property {string} title
 * @property {Child} [body]
 * @property {Action[]} [actions]
 * @property {HTMLElement | null} [ask] A confirmation shown in place of the actions.
 * @property {{ title: string, left: string, onLeft: () => void } | null} [nav] The pairing
 *   screens' bar; connection screens have the header strip instead.
 */

/**
 * A full-screen message: a status icon, a title, a line of help and its buttons.
 * @param {MessageModel} model
 * @returns {HTMLElement}
 */
export function renderMessage({ state, tone, icon: glyph, title, body, actions = [], ask = null, nav: bar = null }) {
  const center = h('div', { class: `center st-${tone}` },
    h('div', { class: 'e-ic' }, icon(glyph)),
    h('h2', null, title),
    body === undefined || body === null || body === false ? null : h('p', null, body),
    ask ?? h('div', { class: 'acts' }, actions.map((action) => h('button', {
      class: action.kind ? `btn ${action.kind}` : 'btn', type: 'button', onClick: action.onClick,
    }, action.label))));
  if (bar === null) {
    center.setAttribute('data-state', state);
    return center;
  }
  return h('div', { class: 'ld', 'data-state': state }, nav(bar.title, bar.left, bar.onLeft), center);
}

/**
 * A wait with nothing to say yet, such as reading the paired laptops: the connecting
 * screen's spinner, with no text.
 * @returns {HTMLElement}
 */
export function renderLoading() {
  return h('div', { class: 'center', 'data-state': 'loading' },
    h('span', { class: 'spin lg', role: 'status', 'aria-label': 'Loading' }));
}

/**
 * Connecting to a laptop, before its app has started. `setName` changes the laptop's name in
 * place, for a handshake that reports a new one while the screen shows.
 * @param {{ laptopName: string }} model
 * @returns {{ root: HTMLElement, setName: (laptopName: string) => void }}
 */
export function renderConnecting({ laptopName }) {
  /** @param {string} name */
  const text = (name) => `Connecting to ${name}…`;
  const status = h('p', { role: 'status' }, text(laptopName));
  return {
    root: h('div', { class: 'center', 'data-state': 'connecting' }, h('span', { class: 'spin lg' }), status),
    setName: (name) => status.replaceChildren(text(name)),
  };
}

// --- header strip -----------------------------------------------------------------------

/**
 * The header strip's contents: the laptop's name with a dropdown caret, and "Reconnecting…"
 * while the channel is down.
 * @param {{ laptopName: string, reconnecting: boolean, expanded: boolean, onToggle: () => void }} model
 * @returns {{ nodes: HTMLElement[], button: HTMLButtonElement }}
 */
export function renderStrip({ laptopName, reconnecting, expanded, onToggle }) {
  const button = h('button', {
    class: 'lapbtn', type: 'button', 'aria-haspopup': 'menu', 'aria-expanded': String(expanded),
    'aria-label': `Laptop: ${laptopName}. Switch laptop`, onClick: onToggle,
  }, icon('laptop'), h('b', null, laptopName), icon('chev-d', 'car'));
  /** @type {HTMLElement[]} */
  const nodes = [button];
  if (reconnecting) {
    nodes.push(h('span', { class: 're', role: 'status', 'data-state': 'reconnect' },
      h('span', { class: 'spin' }), MESSAGES.reconnecting));
  }
  return { nodes, button };
}

/**
 * @typedef {object} MenuLaptop
 * @property {string} name
 * @property {StatusLine} line
 * @property {boolean} current
 * @property {() => void} onPick
 */

/**
 * The strip's laptop menu, drawn by the loader over the app frame: every paired laptop with
 * its status and a check on the current one, then "Pair a laptop" and "Manage laptops".
 * The first node is a transparent layer under the menu that takes any tap outside it,
 * including one over the app frame, and calls `onDismiss`.
 * @param {{ laptops: MenuLaptop[], onPair: () => void, onManage: () => void, onDismiss: () => void }} model
 * @returns {{ nodes: HTMLElement[], items: HTMLButtonElement[], rows: RowHandle[] }} `items` in
 *   focus order; `rows[i]` updates the status line of `model.laptops[i]` in place
 */
export function renderMenu({ laptops, onPair, onManage, onDismiss }) {
  /** @type {HTMLButtonElement[]} */
  const items = [];
  /** @type {RowHandle[]} */
  const rows = [];
  for (const laptop of laptops) {
    const status = statusSmall(laptop.line);
    rows.push(status.handle);
    items.push(h('button', {
      class: 'ldi', type: 'button', role: 'menuitemradio', 'aria-checked': String(laptop.current), onClick: laptop.onPick,
    }, icon('laptop'), h('span', null, laptop.name, status.node), laptop.current ? icon('check', 'tick') : null));
  }
  const pair = h('button', { class: 'ldi act', type: 'button', role: 'menuitem', onClick: onPair },
    icon('plus'), h('span', null, 'Pair a laptop'));
  const manage = h('button', { class: 'ldi act', type: 'button', role: 'menuitem', onClick: onManage },
    icon('laptop'), h('span', null, 'Manage laptops'));
  const all = [...items, pair, manage];
  const drop = h('div', {
    class: 'lapdrop', role: 'menu', 'aria-label': 'Laptops', 'data-state': 'lapmenu',
    onKeyDown: (/** @type {KeyboardEvent} */ event) => moveFocus(event, all),
  }, items, h('div', { class: 'ldsep', role: 'separator' }), pair, manage);
  const catcher = h('div', { class: 'lapcatch', 'aria-hidden': 'true', onClick: onDismiss });
  return { nodes: [catcher, drop], items: all, rows };
}

/**
 * Arrow keys, Home and End move the focus between menu items.
 * @param {KeyboardEvent} event
 * @param {HTMLElement[]} items
 */
function moveFocus(event, items) {
  const at = items.indexOf(/** @type {HTMLElement} */ (document.activeElement));
  let next;
  switch (event.key) {
    case 'ArrowDown':
      next = at < 0 ? 0 : (at + 1) % items.length;
      break;
    case 'ArrowUp':
      next = at < 0 ? items.length - 1 : (at - 1 + items.length) % items.length;
      break;
    case 'Home':
      next = 0;
      break;
    case 'End':
      next = items.length - 1;
      break;
    default:
      return;
  }
  event.preventDefault();
  items[next].focus();
}

// --- link sheet -------------------------------------------------------------------------

/**
 * Asks before opening a link the app passed up, showing the whole URL. `onOpen` runs inside
 * the tap's click handler, so the browser lets it open a tab.
 *
 * A key held down when the sheet opens never presses its buttons. The app opens a link on its
 * Enter, and the loader then focuses Open, so a held Enter's auto-repeat would land on Open
 * and open the link without the sheet being read. A repeated Enter or Space does nothing here
 * (`ignoreHeldKey`), and a fresh press works as on any button.
 * @param {{ url: string, onOpen: () => void, onCancel: () => void }} model
 * @returns {{ nodes: HTMLElement[], open: HTMLButtonElement }}
 */
export function renderLinkSheet({ url, onOpen, onCancel }) {
  const open = h('button', { class: 'btn pri wide', type: 'button', onClick: onOpen }, 'Open');
  const sheet = h('div', {
    class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'link-title', 'data-state': 'link',
    onKeyDown: ignoreHeldKey,
  },
  h('div', { class: 'grab' }),
  h('div', { class: 'sh-top' }, h('p', { class: 'sh-title', id: 'link-title' }, 'Open link')),
  h('p', { class: 'sh-sub url' }, url),
  open,
  h('button', { class: 'btn wide', type: 'button', onClick: onCancel }, 'Cancel'));
  const scrim = h('div', { class: 'scrim', 'aria-hidden': 'true', onClick: onCancel });
  return { nodes: [scrim, sheet], open };
}

/**
 * Drops an auto-repeated Enter or Space, the two keys that press a button. Preventing the
 * keydown also stops the keypress that Enter presses with, and the active state that Space's
 * keyup presses from, so a key that went down before the sheet opened, and repeats into it,
 * cannot press Open or Cancel.
 * @param {KeyboardEvent} event
 */
function ignoreHeldKey(event) {
  if (event.repeat && (event.key === 'Enter' || event.key === ' ')) event.preventDefault();
}
