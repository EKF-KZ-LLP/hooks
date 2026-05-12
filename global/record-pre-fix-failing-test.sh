#!/usr/bin/env bash
# Record legitimate pre-fix failing-test evidence for a TASK-ID.
# Usage:
#   record-pre-fix-failing-test.sh TASK-001 -- pytest tests/test_app.py
#
# The command MUST fail. Passing commands are refused because they do not
# prove regression-first behavior.

set -euo pipefail

task_id="${1:?TASK-ID required}"
shift || true
if [ "${1:-}" != "--" ]; then
    echo "::error::record-pre-fix-failing-test: expected '--' before test command." >&2
    exit 2
fi
shift || true
[ "$#" -gt 0 ] || {
    echo "::error::record-pre-fix-failing-test: test command required." >&2
    exit 2
}

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || {
    echo "::error::record-pre-fix-failing-test: must run inside a git repo." >&2
    exit 2
}

case "$task_id" in
    TASK-[0-9A-Z._-]*) ;;
    *)
        echo "::error::record-pre-fix-failing-test: invalid TASK-ID '$task_id'." >&2
        exit 2
        ;;
esac

dir="$repo/.checkpoints/$task_id"
mkdir -p "$dir"
log="$dir/pre-fix-failing-test.log"
evidence="$dir/pre-fix-failing-test.md"
sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

set +e
"$@" >"$log" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
    rm -f "$evidence"
    cat >&2 <<EOF
::error::record-pre-fix-failing-test: command passed, so it is not valid pre-fix failing-test evidence.
Command: $*
Log: $log
EOF
    exit 2
fi

cat >"$evidence" <<EOF
Evidence: pre-fix
Task: $task_id
Command: $*
Result: FAIL
Exit-code: $status
Commit: $sha
Timestamp: $ts
Log: $log
EOF
chmod 444 "$evidence" 2>/dev/null || true
echo "[record-pre-fix-failing-test] recorded FAIL evidence for $task_id at $evidence"
