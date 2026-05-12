#!/usr/bin/env bash
# PSA assertion-change-guard - when an assertion line is changed, require that
# either (a) production code is also changed in the same slice, or (b) the edit
# adds a wholly new test case (new func Test…/it(…)/def test_…), or (c) the
# commit slice contains an explicit testcase-id reference in the diff.
#
# Iron rule 21 (CLAUDE.md): red test → understand why, don't chase green by
# rewriting the assertion. This hook blocks the tempting shortcut.
#
# Invocation: PostToolUse hook on Edit/Write/MultiEdit.

set -euo pipefail

log()  { printf '%s\n' "$*" >&2; }
warn() { log "WARN assertion-change-guard: $*"; }

FILE_PATH="${1:-}"
if [ -z "$FILE_PATH" ]; then
  INPUT=""
  if [ -n "${CLAUDE_TOOL_INPUT:-}" ]; then
    INPUT="$CLAUDE_TOOL_INPUT"
  elif [ ! -t 0 ]; then
    INPUT="$(cat || true)"
  fi
  if [ -n "$INPUT" ]; then
    if command -v jq >/dev/null 2>&1; then
      FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // empty' 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
      FILE_PATH=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("tool_input",{}).get("file_path") or d.get("file_path") or "")' 2>/dev/null || true)
    fi
  fi
fi

[ -z "$FILE_PATH" ] && exit 0

# Only act on test files.
case "$FILE_PATH" in
  *_test.go|*/test_*.py|*_test.py|*.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx) ;;
  *) exit 0 ;;
esac

# Need a git repo for diff reasoning.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# Diff of THIS test file (both unstaged and staged, whichever holds the change).
DIFF=$(git -c color.ui=never -c core.pager=cat diff -- "$FILE_PATH" 2>/dev/null; git -c color.ui=never -c core.pager=cat diff --cached -- "$FILE_PATH" 2>/dev/null)
[ -z "$DIFF" ] && exit 0

# An "assertion change" is a line that *adds or removes* an assert/expect/require.
ASSERT_DIFF=$(printf '%s' "$DIFF" | grep -E '^[+-][^+-].*(assert\.|require\.|expect\()|^[+-][[:space:]]+assert[[:space:]]' || true)
[ -z "$ASSERT_DIFF" ] && exit 0  # no assertion touched

# Case (b): new test func added in the SAME diff → legitimate (adding a case).
if printf '%s' "$DIFF" | grep -qE '^\+(func[[:space:]]+Test[A-Z]|it\(|test\(|def[[:space:]]+test_)'; then
  exit 0
fi

# Case (a): production code in the slice?
CHANGED=$(git status --porcelain 2>/dev/null | awk '{print $2}' | grep -v '^$' || true)
PROD_TOUCHED=$(printf '%s\n' "$CHANGED" \
  | grep -vE '(_test\.go|\.test\.tsx?|\.spec\.tsx?|test_.*\.py|.*_test\.py)$' \
  | grep -vE '(^testdata/|/testdata/|/__fixtures__/|/fixtures/|\.golden|\.md$)' || true)
if [ -n "$PROD_TOUCHED" ]; then
  exit 0
fi

# Case (c): testcase-id reference anywhere in the slice diff?
# Accepts "TC-123", "Refs #N", "Fixes #N", "Closes #N", "testcase:" in a +added comment.
SLICE_DIFF=$(git -c color.ui=never -c core.pager=cat diff 2>/dev/null; git -c color.ui=never -c core.pager=cat diff --cached 2>/dev/null)
if printf '%s' "$SLICE_DIFF" | grep -qE '^\+.*(TC-[0-9]+|testcase[[:space:]]*[:=]|(Refs|Fixes|Closes)[[:space:]]*#[0-9]+)'; then
  exit 0
fi

# All three exits failed. This is a hard block: optional guard means
# "enforced when installed", not a reminder.
log ""
log "assertion-change-guard blocked $FILE_PATH"
log "You modified assertion(s) without:"
log "  - changing production code in the same slice,"
log "  - adding a new test function, or"
log "  - referencing a testcase id / issue in the diff."
log ""
log "A red test is information. Do not silence it by editing the expectation."
log "Changed assertion lines:"
printf '%s\n' "$ASSERT_DIFF" | head -6 | awk '{ print "  " $0 }' >&2

exit 2
