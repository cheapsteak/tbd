// The placeholder phone app (docs/specs/2026-11-07-phone-control-design.md, section 9). Until the
// real app is built from phone/app/, a phone that connects to TBD runs this, and it says so in
// one line.
//
// It keeps to the runner's contract for a bundle (phone/loader/runner.js): one classic script
// started from a blob: URL, so no module syntax; text set through `textContent`, never an HTML
// string, which Trusted Types refuses; no code made from strings; and no styles injected at
// runtime. Everything sits inside one function, so it defines no globals. It has nothing to tell
// the laptop, so it leaves `tbdHost.port` alone.
(() => {
  'use strict';
  const line = document.createElement('p');
  line.textContent = 'Connected to TBD. The phone app is not built yet.';
  document.body.append(line);
})();
