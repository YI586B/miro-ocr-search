#!/bin/bash
# Renders the self-test exports (see SelfTest.swift) and compares them with a saved baseline.
#
#   Scripts/golden-check.sh baseline <dir>   save the current output as the baseline
#   Scripts/golden-check.sh check <dir>      render again and compare with <dir>
#
# Uses miro-files (local, untracked). Identical plan.json and PNG hashes mean font detection,
# layout and rendering are unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."
cmd=${1:?baseline|check}; base=${2:?directory}
swift build -c release 2>&1 | grep -E "error|Build complete"
if [ "$cmd" = baseline ]; then
    rm -rf "$base"; .build/release/OCRSearchApp --selftest miro-files "$base" >/dev/null
    echo "baseline written to $base"; exit 0
fi
new=$(mktemp -d)
.build/release/OCRSearchApp --selftest miro-files "$new" >/dev/null
status=0
for d in "$base"/*/; do
    c=$(basename "$d")
    if cmp -s "$base/$c/plan.json" "$new/$c/plan.json"; then echo "same      $c"
    else echo "DIFFERENT $c"; diff "$base/$c/plan.json" "$new/$c/plan.json" | head -20; status=1; fi
done
[ $status = 0 ] && echo "All cases identical (plans and PNG hashes)." || echo "Output changed; see $new"
exit $status
