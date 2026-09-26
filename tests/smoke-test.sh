#!/usr/bin/env bash
# Bats-style smoke test run directly with bash (no framework dependency).
# Verifies: text report renders, JSON is valid, exit code is in {0,1,2}.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$SCRIPT_DIR/jetson-doctor.sh"
fail=0

# 1. text mode exits with a sane code
"$DOC" > /tmp/jd_text.out; rc=$?
[ $rc -le 2 ] || { echo "FAIL: exit code $rc > 2"; fail=1; }
grep -q "jetson-doctor report" /tmp/jd_text.out || { echo "FAIL: no report header"; fail=1; }

# 2. JSON mode parses
"$DOC" --json > /tmp/jd_json.out 2>/dev/null
python3 -m json.tool < /tmp/jd_json.out >/dev/null || { echo "FAIL: invalid JSON"; fail=1; }

# 3. help works
"$DOC" --help | grep -q "Usage" || { echo "FAIL: --help broken"; fail=1; }

# 4. shellcheck clean if available
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$DOC" || { echo "FAIL: shellcheck"; fail=1; }
fi

[ $fail -eq 0 ] && echo "smoke-test: all OK"
exit $fail
