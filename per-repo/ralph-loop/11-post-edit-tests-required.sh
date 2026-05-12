#!/usr/bin/env bash
# Ralph-Loop hook 11 - PostToolUse Edit/Write/MultiEdit (TDD enforcement).
# Closes audit gap #3: hooks did not enforce TDD-style co-located tests.
# Production code edits without corresponding test mtime update accumulate
# as warnings. ≥3 warnings → exit 2 (next edit blocked until resolved).
#
# Mechanism:
#   - On prod-file Edit (.go|.py|.ts|.tsx, NOT *_test.* / test_*.py / *.test.tsx):
#       look for sibling test file in same dir (or _test.go in same dir, or
#       test_<basename>.py in tests/ subdir).
#   - If test file exists AND its mtime < prod file mtime → emit warning to
#       .checkpoints/<active-slug>/test-debt.log
#   - If warning count > 3 in current session → exit 2.
#
# Bypass: write `.checkpoints/<slug>/test-debt-rationale.md` with a
# justification line to reset the counter.

set -euo pipefail

active_pointer="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")
[ -f "$tracker" ] || exit 0

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[ -n "$file_path" ] || exit 0
[ -f "$file_path" ] || exit 0

# Only act on production source files.
case "$file_path" in
    *_test.go|*test_*.py|*.test.ts|*.test.tsx|*_test.py|*spec.ts|*spec.tsx) exit 0 ;;
    *.go|*.py|*.ts|*.tsx) : ;;
    *) exit 0 ;;
esac

repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ "$branch" = "main" ] && exit 0

slug=$(grep -oE 'evidence:\s*\.checkpoints/[^/]+' "$tracker" 2>/dev/null \
    | sed -E 's|evidence:\s*\.checkpoints/||' \
    | while read -r s; do
        if echo "$branch" | grep -qF "$s"; then echo "$s"; break; fi
      done | head -1)
[ -n "$slug" ] || exit 0

# Bypass: rationale file present.
rationale="$repo/.checkpoints/$slug/test-debt-rationale.md"
[ -f "$rationale" ] && exit 0

# Find sibling test file.
dir=$(dirname "$file_path")
base=$(basename "$file_path")
stem="${base%.*}"
ext="${base##*.}"
test_file=""
case "$ext" in
    go)
        test_file="$dir/${stem}_test.go"
        ;;
    py)
        test_file="$dir/test_${stem}.py"
        [ -f "$test_file" ] || test_file="$dir/tests/test_${stem}.py"
        [ -f "$test_file" ] || test_file="$(dirname "$dir")/tests/test_${stem}.py"
        ;;
    ts|tsx)
        test_file="$dir/${stem}.test.${ext}"
        ;;
esac

[ -n "$test_file" ] && [ -f "$test_file" ] || exit 0

prod_mtime=$(stat -f '%m' "$file_path" 2>/dev/null || stat -c '%Y' "$file_path" 2>/dev/null || echo 0)
test_mtime=$(stat -f '%m' "$test_file" 2>/dev/null || stat -c '%Y' "$test_file" 2>/dev/null || echo 0)

if [ "$test_mtime" -ge "$prod_mtime" ]; then
    exit 0
fi

# Warning: prod modified after test. Append to debt log.
log_dir="$repo/.checkpoints/$slug"
mkdir -p "$log_dir"
log="$log_dir/test-debt.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) prod=$file_path test=$test_file (test older by $((prod_mtime - test_mtime))s)" >> "$log"

count=$(wc -l < "$log" | tr -d ' ')
if [ "$count" -gt 3 ]; then
    cat >&2 <<EOF
::error::ralph-loop-11: TDD violation cap reached for task '$slug' ($count warnings).

Last warning: $(tail -1 "$log")
Log: $log

Either:
  (a) Update tests for the modified prod files, then re-edit (counter not reset until log cleared).
  (b) Write '$rationale' with justification to bypass (e.g. doc-only refactor inside prod file).
EOF
    exit 2
fi

echo "[ralph-loop-11] WARN $count/3: prod-file '$base' modified, test '$(basename "$test_file")' older. Update test."
exit 0
