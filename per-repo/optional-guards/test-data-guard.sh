#!/usr/bin/env bash
# PSA test-data-guard - block modification of test fixtures that is NOT
# clearly justified by matching production changes in the same commit slice.
#
# Iron rule 22 (CLAUDE.md): fixture data is frozen - you do not re-shape it
# to make a failing test pass. A legitimate fixture edit looks like one of:
#   • fixture-only update (data refresh; no test file touched in the same slice)
#   • fixture + production change (behavior change → new expected data)
#   • fixture + test rewrite with a NEW testcase name (adding a case, not moving the goalposts)
#
# Illegitimate, blocked:
#   • fixture + same test function's assertion edit, no production change
#
# Invocation: PostToolUse hook on Edit/Write/MultiEdit.
#
# Contract matches test-quality-gate.sh (JSON on stdin, $CLAUDE_TOOL_INPUT env,
# or $1 as a path).

set -euo pipefail

log()  { printf '%s\n' "$*" >&2; }
fail() { log "❌ test-data-guard: $*"; exit 2; }
warn() { log "WARN test-data-guard: $*"; }

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

# ─── Is the target file a fixture? ─────────────────────────────────────────
is_fixture=false
case "$FILE_PATH" in
  */testdata/*|*/__fixtures__/*|*/fixtures/*|*.golden|*.golden.json|*.golden.txt) is_fixture=true ;;
  */testdata/*.json|*/testdata/*.csv|*/testdata/*.sql|*/testdata/*.yaml|*/testdata/*.yml) is_fixture=true ;;
esac

$is_fixture || exit 0

# Must be inside a git repo to reason about the slice
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "not a git repo - skipping cross-file analysis for $FILE_PATH"
  exit 0
fi

# ─── Look at the current unstaged + staged slice (the "commit about to happen")
# Any test files touched in the same slice?
CHANGED=$(git status --porcelain 2>/dev/null | awk '{print $2}' | grep -v '^$' || true)
TESTS_TOUCHED=$(printf '%s\n' "$CHANGED" | grep -E '(_test\.go|\.test\.tsx?|\.spec\.tsx?|test_.*\.py|.*_test\.py)$' || true)
PROD_TOUCHED=$(printf '%s\n' "$CHANGED" \
  | grep -vE '(_test\.go|\.test\.tsx?|\.spec\.tsx?|test_.*\.py|.*_test\.py)$' \
  | grep -vE '(^testdata/|/testdata/|/__fixtures__/|/fixtures/|\.golden|\.md$|CONTEXT\.md|WORKPLAN\.md|HANDOFF\.md|CHANGELOG\.md)' || true)

if [ -z "$TESTS_TOUCHED" ]; then
  # Fixture-only update - legitimate (data refresh, e.g. from DWH). Pass.
  exit 0
fi

# Tests touched alongside fixture. Now: was production code touched too?
if [ -n "$PROD_TOUCHED" ]; then
  # Behavior change path: fixture + prod + test - legitimate. Pass with note.
  log "INFO test-data-guard: fixture + production + tests edited together - ok ($FILE_PATH)."
  exit 0
fi

# Tests touched, fixture touched, NO production change. Check whether the
# test diff adds a new test function (adding a case is allowed) or only
# modifies assertions inside an existing one (illegitimate).
ASSERT_LINE_CHANGE=0
NEW_TEST_ADDED=0
while IFS= read -r testfile; do
  [ -z "$testfile" ] && continue
  DIFF=$(git -c color.ui=never -c core.pager=cat diff -- "$testfile" 2>/dev/null; git -c color.ui=never -c core.pager=cat diff --cached -- "$testfile" 2>/dev/null)
  if printf '%s' "$DIFF" | grep -qE '^\+.*(assert\.|require\.|expect\()|^\+[[:space:]]+assert[[:space:]]'; then
    ASSERT_LINE_CHANGE=1
  fi
  if printf '%s' "$DIFF" | grep -qE '^\+.*(func[[:space:]]+Test[A-Z]|it\(|test\(|def[[:space:]]+test_)'; then
    NEW_TEST_ADDED=1
  fi
done <<< "$TESTS_TOUCHED"

if [ "$ASSERT_LINE_CHANGE" -eq 1 ] && [ "$NEW_TEST_ADDED" -eq 0 ]; then
  log ""
  log "┌─ test-data-guard blocked $FILE_PATH ─"
  log "│ Fixture edit + assertion edit + no production change = goalpost move."
  log "│ Iron rule 22 (CLAUDE.md): don't re-shape fixtures to make a red test green."
  log "│"
  log "│ If the test is wrong:   fix the test's expectation against the SPEC, not the fixture."
  log "│ If the fixture is stale: commit fixture-refresh alone (no test change), then react."
  log "│ If behavior changed:     also commit the matching production change."
  log "│"
  log "│ Files in the slice:"
  log "│   fixture:  $FILE_PATH"
  printf '%s\n' "$TESTS_TOUCHED" | awk 'NF{ print "│   test:     " $0 }' >&2
  log "└─"
  exit 2
fi

exit 0
