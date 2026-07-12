#!/usr/bin/env bash
# Per-step verification gate — see docs/plan.md "Verification".
# Godot exits 0 even when scripts fail to parse or _ready() errors out, so this
# gates on exit code AND an error-grep AND a hang timeout.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"

check() { # usage: check <logname> <godot args...>
  local log="/tmp/$1.log"
  shift
  timeout 180 "$GODOT" --headless --path "$REPO" "$@" >"$log" 2>&1
  local code=$?
  cat "$log"
  if [ "$code" -ne 0 ]; then
    echo "FAIL: exit $code (124 = hang/timeout)"
    return 1
  fi
  if grep -qE 'SCRIPT ERROR:|ERROR:' "$log"; then
    echo "FAIL: errors in log"
    return 1
  fi
  return 0
}

echo "== import gate =="
check import --import || exit 1

echo "== per-file parse gate (--check-only) =="
while IFS= read -r -d '' f; do
  rel="${f#"$REPO"/}"
  "$GODOT" --headless --path "$REPO" --check-only --script "res://$rel" >/dev/null 2>&1 \
    || { echo "PARSE FAIL: $rel"; exit 1; }
done < <(find "$REPO/scripts" "$REPO/test" -name '*.gd' -print0 2>/dev/null)

echo "== boot gate =="
check boot --quit || exit 1

if [ -f "$REPO/test/smoke.gd" ]; then
  echo "== smoke gate (--fixed-fps 60) =="
  check smoke --fixed-fps 60 --script res://test/smoke.gd || exit 1
fi

echo "VERIFY OK"
