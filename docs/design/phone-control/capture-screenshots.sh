#!/bin/bash
# Re-makes screenshots/ from phone-control-mocks.html: every state in the mock's IXG index,
# in light and dark mode, at 390 x 844 points (iPhone 15) and 2x pixels, as lossless WebP.
# Run it after any change to the mock, then commit the mock and the screenshots together.
#
# Needs macOS Google Chrome (or CHROME=/path/to/chrome), ImageMagick 7 with WebP (`magick`),
# and python3.
#
# Chrome will not size a window below about 500 px, so each state loads in a 390 x 844 iframe
# and the shot is cropped to it. Each capture uses a fresh browser profile, so mock options a
# viewer saved earlier cannot leak in. The short virtual-time budget lets the page render but
# stops before the mock's timed changes run (for example, Connecting moves on after 1.1 s).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
html="$here/phone-control-mocks.html"
out="$here/screenshots"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

shoot() { # <state> <theme>
  local key="$1" theme="$2" work
  work="$(mktemp -d)"
  printf '<!doctype html><html><body style="margin:0;background:#000"><iframe src="file://%s?theme=%s&clean=1#%s" style="display:block;border:0;width:390px;height:844px"></iframe></body></html>' \
    "$html" "$theme" "$key" > "$work/wrap.html"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$work/profile" \
    --window-size=640,900 --force-device-scale-factor=2 --virtual-time-budget=600 \
    --allow-file-access-from-files --screenshot="$work/full.png" "file://$work/wrap.html" >/dev/null 2>&1 || true
  if [ -s "$work/full.png" ]; then
    magick "$work/full.png" -crop 780x1688+0+0 +repage -strip -define webp:lossless=true "$out/$theme/$key.webp"
  else
    echo "capture failed: $theme/$key" >&2
  fi
  rm -rf "$work"
}

if [ "${1:-}" = "--one" ]; then
  shoot "$2" "$3"
  exit 0
fi

states="$(python3 -I - "$html" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
ix = re.search(r'var IXG = \[(.*?)\n\];\n', s, re.S).group(1)
print('\n'.join(re.findall(r"\['([a-z0-9-]+)', ", ix)))
PY
)"
count="$(printf '%s\n' "$states" | wc -l | tr -d ' ')"

rm -rf "$out/light" "$out/dark"
mkdir -p "$out/light" "$out/dark"
for theme in light dark; do
  printf '%s\n' "$states" | sed "s/\$/ $theme/"
done | xargs -P 4 -n 2 "$0" --one

made="$(find "$out/light" "$out/dark" -name '*.webp' | wc -l | tr -d ' ')"
echo "$made of $((count * 2)) screenshots made ($count states, light and dark)."
[ "$made" -eq "$((count * 2))" ]
