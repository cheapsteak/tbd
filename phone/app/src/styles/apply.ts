/**
 * Puts the app's stylesheet on the document. The stylesheet is a constructed sheet, which the
 * frame's content policy allows where a `<style>` element or a style attribute would not.
 */

import appCss from './app.css';

export function applyStyles(doc: Document, css: string = appCss): void {
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(css);
  doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
}
