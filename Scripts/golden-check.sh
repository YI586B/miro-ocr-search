#!/bin/bash
# Renders the self-test exports (see SelfTest.swift) and compares them with a saved baseline.
#
#   Scripts/golden-check.sh baseline <dir>   save the current output as the baseline
#   Scripts/golden-check.sh check <dir>      render again and compare with <dir>
#
# Uses miro-files (local, untracked). Matching plans and identical PNG hashes mean font
# detection, layout and rendering are unchanged. Also fails if the preview window's path
# (PreviewModel) disagrees with a batch export; see SelfTest.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
cmd=${1:?baseline|check}; base=${2:?directory}
swift build -c release 2>&1 | grep -E "error|Build complete"
if [ "$cmd" = baseline ]; then
    rm -rf "$base"; mkdir -p "$base"
    .build/release/OCRSearchApp --selftest miro-files "$base" > "$base/../$(basename "$base").log" || { tail -5 "$base/../$(basename "$base").log"; exit 1; }
    grep -E "font detection|preview runs" "$base/../$(basename "$base").log"; echo "baseline written to $base"; exit 0
fi
new=$(mktemp -d)
status=0
.build/release/OCRSearchApp --selftest miro-files "$new" > "$new.log" || status=1
grep -E "^font |font detection|FONT DETECTION|^  IMG" "$new.log"; grep -A30 "preview runs" "$new.log" || tail -5 "$new.log"
# Numbers match within a millionth (CoreText's measurements wobble in the ninth digit between
# calls); text, fonts and PNG hashes must match exactly.
for d in "$base"/*/; do
    c=$(basename "$d")
    python3 - "$base/$c/plan.json" "$new/$c/plan.json" "$c" <<'PY' || status=1
import json, sys
def diff(a, b, where):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return [] if abs(a - b) < 1e-6 else [f"{where}: {a} -> {b}"]
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return [x for i, (p, q) in enumerate(zip(a, b)) for x in diff(p, q, f"{where}[{i}]")]
    if isinstance(a, dict) and isinstance(b, dict) and a.keys() == b.keys():
        return [x for k in a for x in diff(a[k], b[k], f"{where}.{k}")]
    return [] if a == b else [f"{where}: {json.dumps(a)[:80]} -> {json.dumps(b)[:80]}"]
d = diff(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), "")
print(("same      " if not d else "DIFFERENT ") + sys.argv[3])
for x in d[:10]: print("   ", x)
sys.exit(1 if d else 0)
PY
done
[ $status = 0 ] && echo "All cases identical (plans and PNG hashes)." || echo "Output changed; see $new"
exit $status
