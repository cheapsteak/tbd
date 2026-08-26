#!/usr/bin/env python3
"""Find what occupies TBD's main thread while terminal output sits undelivered.

This is the instrument that identified SwiftUI's `Update.end` view-graph flush
as the cause of terminal stalls (docs/perf/2026-08-26-main-thread-burst-attribution.md).
It does not take a suspect as input: windows are defined by the symptom, and
attribution is by which run-loop callout the work hangs off.

RECORD (all three instruments in ONE trace, so they share one timeline and
correlation is exact rather than clock-matched):

    xcrun xctrace record --instrument 'Time Profiler' --instrument 'os_signpost' \
        --instrument 'Hangs' --attach <pid> --time-limit 150s --no-prompt \
        --output w.trace

    Verify the recording actually finalised -- it can fail silently, leaving a
    large unfinalised directory and no "Recording completed" line, after which
    export reports "Document Missing Template Error":

        grep -c "Output file saved" w.record.log

ANALYSE:

    scripts/diag/main-thread-attribution.py w.trace [more.trace ...]

WHAT EACH INSTRUMENT COUNTS -- state this before believing any number:

  potential-hangs   Instruments' own main-thread unresponsiveness intervals
                    (100 ms threshold), derived from system responsiveness
                    events. Knows nothing about TBD's code. Used only as a
                    cross-check; it is NOT the same notion as "the main dispatch
                    queue was not drained".

  time-profile      1 ms sampling profiler. Each row is ONE sample of ONE thread
                    with a full symbolicated backtrace. Every sample is counted
                    ONCE into ONE bucket, so a parent is never summed with its
                    own child -- the double-counting that inflated the draw path
                    ~2x in earlier `sample`-based rounds is impossible here.

  os-signpost-interval
                    TBD's own `perf-terminal` intervals (see TerminalSignposts).

WINDOW DEFINITION: a stall window is a period during which at least one
`mainThreadHop` interval was open, i.e. terminal bytes were demonstrably sitting
on the main queue undelivered. Nothing about any suspect enters that definition.

TWO TRAPS, both of which produced wrong readings during the investigation:

  * `xctrace export` ref-compresses backtrace frames (`<frame ref="11"/>`).
    Resolving only the <backtrace> element and not each frame yields a stack
    with one named frame and N unknowns, which reads exactly like a truncated
    stack and is not. This script resolves frame refs (see Refs.put).

  * Raw co-occurrence is not evidence when the suspect occupies a large fraction
    of the timeline. Compute duty cycle and test enrichment against chance. That
    check refuted the poll-cycle hypothesis: it looked like 6x on a small sample
    and measured 1.02x on a large one. `--enrich NAME` does this for any
    interval.
"""
import argparse, os, subprocess, sys
from collections import Counter
import xml.etree.ElementTree as ET

# --- export / parse -------------------------------------------------------

def export(trace, schema, suffix):
    """Export one table, caching beside the trace. Re-exports an empty cache."""
    path = f"{trace}.{suffix}.xml"
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        with open(path, "wb") as fh:
            r = subprocess.run(
                ["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                 f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                stdout=fh, stderr=subprocess.PIPE)
        if r.returncode != 0:
            os.unlink(path)
            sys.exit(f"export of {schema} from {trace} failed: "
                     f"{r.stderr.decode().strip()}\n"
                     f"If this says 'Document Missing Template Error', the "
                     f"recording never finalised and the trace is unusable.")
    return path

class Refs:
    """xctrace XML compresses repeated values as id/ref pairs, including nested
    elements and individual backtrace frames. Register whole subtrees and never
    clear a parsed row, or later refs dangle."""
    def __init__(self): self.d = {}
    def put(self, el):
        for sub in el.iter():
            i = sub.get("id")
            if i and i not in self.d: self.d[i] = sub
        return el
    def get(self, el):
        r = el.get("ref")
        if r: return self.d[r]
        self.put(el); return el

def _rows(path):
    for _, el in ET.iterparse(path, events=("end",)):
        if el.tag == "row": yield el

def parse_intervals(path, name_index):
    R, out = Refs(), []
    for row in _rows(path):
        k = list(row)
        s = int(R.get(k[0]).text); d = int(R.get(k[1]).text)
        out.append((s, s + d, d, R.get(k[name_index]).text))
    return out

def parse_samples(path):
    """-> [(time_ns, is_main_thread, [(frame_name, binary_name), ...outer..leaf])]"""
    R, out = Refs(), []
    for row in _rows(path):
        k = list(row)
        t = int(R.get(k[0]).text)
        th = R.get(k[1]); is_main = "Main Thread" in (th.get("fmt") or "")
        frames = []
        for x in k[2:]:
            x = R.get(x)
            if x.tag == "backtrace":
                for f in x.findall("frame"):
                    fr = R.get(f)
                    b = fr.find("binary")
                    b = R.get(b) if b is not None else None
                    frames.append((fr.get("name") or "?",
                                   b.get("name") if b is not None else "?"))
        out.append((t, is_main, list(reversed(frames))))
    return out

# --- interval algebra -----------------------------------------------------

def merge(spans):
    spans, out = sorted(spans), []
    for s, e in spans:
        if out and s <= out[-1][1]: out[-1][1] = max(out[-1][1], e)
        else: out.append([s, e])
    return [(a, b) for a, b in out]

def in_any(t, spans):
    lo, hi = 0, len(spans) - 1
    while lo <= hi:
        m = (lo + hi) // 2
        a, b = spans[m]
        if t < a: hi = m - 1
        elif t > b: lo = m + 1
        else: return True
    return False

# --- attribution ----------------------------------------------------------

CALLOUTS = [
    ("runloop observer (CA commit / SwiftUI flush)",
     "__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__"),
    ("main-dispatch-queue block", "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__"),
    ("runloop timer", "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__"),
    ("source0 (NSEvent / perform)", "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__"),
    ("source1 (mach port)", "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__"),
    ("block on a runloop", "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__"),
]

def trigger(frames):
    """Which run-loop callout does this sample hang off? Innermost wins, so a
    nested run loop is attributed to the inner callout."""
    names = [n for n, _ in frames]
    best = None
    for label, marker in CALLOUTS:
        for i, n in enumerate(names):
            if marker in n and (best is None or i > best[0]):
                best = (i, label)
    if best: return best[1]
    if any("_DPSNextEvent" in n or "nextEventMatchingMask" in n for n in names):
        return "app event pump (idle/blocked)"
    return "other / outside runloop"

def tbd_entry(frames):
    """Outermost TBDApp frame -- names OUR code inside the callout."""
    for n, b in frames:
        if b == "TBDApp" and not n.startswith(("static TBDAppMain", "TBDApp_main")):
            return n
    return "<no TBDApp frame>"

# Specific activities are tested BEFORE the generic AttributeGraph bucket:
# AG frames appear on virtually every SwiftUI stack because AG is the driver,
# so testing for them first would swallow every sample.
INSIDE_RULES = [
    ("view-list rebuild (ForEach/ViewList applyNodes)",
     lambda ns: any("applyNodes" in n or "ForEachState" in n or "DynamicViewList" in n
                    or "_ViewList_" in n or "SubgraphList" in n for n in ns)),
    ("body evaluation (a View.body getter ran)",
     lambda ns: any(".body.getter" in n for n in ns)),
    ("attribute-graph update (AG::Graph)",
     lambda ns: any(n.startswith("AG::") or "AttributeGraph" in n for n in ns)),
    ("display-list / layout",
     lambda ns: any("DisplayList" in n or "layout" in n.lower() for n in ns)),
]

def inside_bucket(frames):
    ns = [n for n, _ in frames]
    for label, pred in INSIDE_RULES:
        if pred(ns): return label
    return "other flush machinery"

def runs_of(main_samples, gap_ns=3e6):
    """Group consecutive samples into uninterrupted callout runs. A run SPLITS
    (never merges) when the thread leaves the CPU, so every duration is a LOWER
    bound on the true callout length."""
    runs, cur = [], None
    for s in main_samples:
        t = trigger(s[2])
        if cur and t == cur[0] and s[0] - cur[2] <= gap_ns:
            cur[2] = s[0]; cur[3].append(s)
        else:
            if cur: runs.append(cur)
            cur = [t, s[0], s[0], [s]]
    if cur: runs.append(cur)
    return runs

def pct(sorted_vals, q):
    if not sorted_vals: return float("nan")
    return sorted_vals[min(len(sorted_vals) - 1, int(q / 100 * (len(sorted_vals) - 1)))]

# --- report ---------------------------------------------------------------

def analyse(trace, thresh_ms, enrich_names, verbose):
    samples = parse_samples(export(trace, "time-profile", "tp"))
    sps = parse_intervals(export(trace, "os-signpost-interval", "sp"), 3)
    hops = [(a, b, d) for a, b, d, n in sps if n == "mainThreadHop"]
    if not hops:
        sys.exit(f"{trace}: no mainThreadHop intervals — was the app built with "
                 f"TerminalSignposts, and did any terminal produce output?")
    spans = [(a, b) for a, b in merge([(a, b) for a, b, _ in hops])
             if b - a >= thresh_ms * 1e6]
    span = max(s[0] for s in samples) - min(s[0] for s in samples)
    stall = sum(b - a for a, b in spans)
    main_s = sorted([s for s in samples if s[1]], key=lambda s: s[0])
    inh = [s for s in main_s if in_any(s[0], spans)]
    out = [s for s in main_s if not in_any(s[0], spans)]
    ds = sorted(d for _, _, d in hops)

    print(f"\n=== {trace}   {span/1e9:.0f}s")
    print(f"  mainThreadHop  n={len(ds)}  p50={pct(ds,50)/1e6:.2f}ms  "
          f"p99={pct(ds,99)/1e6:.1f}ms  max={ds[-1]/1e6:.1f}ms")
    print(f"  stall windows (bytes undelivered >= {thresh_ms:.0f}ms): {len(spans)}, "
          f"{stall/1e6:.0f}ms = {stall/span*100:.2f}% of wall")
    if not inh:
        print("  no main-thread samples inside stall windows — nothing to attribute")
        return
    print(f"  main thread on-CPU: {len(inh)/(stall/1e6)*100:.0f}% inside stalls, "
          f"{len(out)/((span-stall)/1e6)*100:.0f}% outside")

    def table(title, keyfn, src_in, src_out, n=12):
        ci = Counter(keyfn(s[2]) for s in src_in)
        co = Counter(keyfn(s[2]) for s in src_out)
        print(f"\n  --- {title} ---")
        print(f"  {'ms':>7s} {'in%':>6s} {'out%':>6s} {'enrich':>8s}  bucket")
        for k, c in ci.most_common(n):
            si = c / len(src_in) * 100
            so = co[k] / len(src_out) * 100 if src_out else 0
            e = f"{si/so:7.2f}x" if so else "     inf"
            print(f"  {c:7d} {si:5.1f}% {so:5.1f}% {e}  {k[:88]}")

    table("TRIGGER: which run-loop callout the burst hangs off", trigger, inh, out)

    all_runs = runs_of(main_s)
    print(f"\n  --- uninterrupted callout runs (ms; lower bounds) ---")
    print(f"  {'trigger':46s} {'n':>5s} {'p50':>6s} {'p90':>7s} {'max':>7s} {'>50ms':>6s}")
    by = {}
    for t, a, b, _ in all_runs: by.setdefault(t, []).append((b - a) / 1e6)
    for t, dd in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        dd.sort()
        print(f"  {t[:46]:46s} {len(dd):5d} {pct(dd,50):6.1f} {pct(dd,90):7.1f} "
              f"{dd[-1]:7.1f} {sum(1 for d in dd if d > 50):6d}")

    OBS = "runloop observer (CA commit / SwiftUI flush)"
    fat = [s for r in all_runs if r[0] == OBS and (r[2]-r[1]) >= 50e6 for s in r[3]]
    thin = [s for r in all_runs if r[0] == OBS and (r[2]-r[1]) < 10e6 for s in r[3]]
    if fat:
        print(f"\n  --- inside EXPENSIVE flushes ({len(fat)}ms of CPU) ---")
        c = Counter(inside_bucket(s[2]) for s in fat)
        for k, n_ in c.most_common():
            print(f"  {n_:7d}ms {n_/len(fat)*100:5.1f}%  {k}")
        if verbose and thin:
            table("entry point into an expensive flush (control: cheap flushes)",
                  tbd_entry, fat, thin)

    for name in enrich_names:
        sp = merge([(a, b) for a, b, _, n in sps if n == name])
        if not sp:
            print(f"\n  enrichment: no intervals named {name!r}")
            continue
        duty = sum(b - a for a, b in sp) / span
        hit = sum(1 for a, _ in spans if in_any(a, sp))
        exp = duty * len(spans)
        enr = hit / exp if exp else float("nan")
        print(f"\n  --- enrichment of {name!r} against chance ---")
        print(f"  duty={duty*100:.1f}%  windows-inside={hit}  expected={exp:.1f}  "
              f"enrichment={enr:.2f}x   (n={len(spans)} windows)")
        print(f"  1.0x means co-occurrence is exactly what chance predicts — no evidence.")
        if len(spans) < 40:
            print(f"  !! n={len(spans)} is SMALL. This exact measurement read 6.04x on "
                  f"n=14 and 1.02x on n=363 for the same suspect —")
            print(f"     the 6x was noise and a hypothesis was retracted because of it. "
                  f"Do not conclude from a window count this low.")
        print(f"  Note: windows here are MERGED undelivered-bytes periods, not "
              f"individual stalled chunks, so n is")
        print(f"  much smaller than a per-stall count over the same trace. Lower "
              f"--threshold-ms to raise n.")

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--threshold-ms", type=float, default=50.0,
                    help="minimum undelivered-bytes window to attribute (default 50)")
    ap.add_argument("--enrich", action="append", default=[], metavar="NAME",
                    help="duty-cycle-corrected enrichment for a signpost interval "
                         "(e.g. --enrich rpc.pollCycle). Repeatable.")
    ap.add_argument("--verbose", action="store_true",
                    help="also break expensive flushes down by TBD entry point")
    a = ap.parse_args()
    for t in a.traces:
        analyse(t, a.threshold_ms, a.enrich, a.verbose)

if __name__ == "__main__":
    main()
