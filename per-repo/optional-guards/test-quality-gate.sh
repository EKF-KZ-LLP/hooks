#!/usr/bin/env bash
# PSA test-quality-gate - static checks a test file after Edit/Write/MultiEdit.
#
# Fails (exit 2 → blocking) on:
#   T1 Trivial assertion     assert.True(t, true), assert True, expect(true).toBe(true), assert 1 == 1
#   T2 Empty test body       `func Test...(t *testing.T) { }`, `it("…", () => {})`
#   T3 Assert-on-nothing     ONLY `assert.NoError(t, err)` / `expect(r).toBeDefined()` without value checks
#   T4 Mock-only             ONLY `mock.On / mock.AssertCalled / vi.fn().toHaveBeenCalled` without SUT call
#   T5 Skip without ticket   `t.Skip()`, `it.skip`, `xdescribe`, `xit`, `pytest.mark.skip` not tied to `#<N>`
#   T6 Assertion density     < 1 assertion per 20 non-blank lines (warning, not block, until 40 lines)
#
# Enforces iron rules 21–24 in CLAUDE.md. Hook contract:
#   stdin = Claude Code hook JSON  (PostToolUse)  OR
#   $CLAUDE_TOOL_INPUT = same JSON
#   $1 = file path (manual invocation / CI)
#
# Exit codes:
#   0  file is not a test (or passes all checks)
#   2  blocking violation (agent must fix)
#
# Writes findings to stderr with markers that surface in the Claude UI.

set -euo pipefail

log()  { printf '%s\n' "$*" >&2; }
fail() { log "❌ test-quality-gate: $*"; exit 2; }
warn() { log "⚠️  test-quality-gate: $*"; }

# ─── 1. Extract target file path ────────────────────────────────────────────
FILE_PATH="${1:-}"
if [ -z "$FILE_PATH" ]; then
  INPUT=""
  if [ -n "${CLAUDE_TOOL_INPUT:-}" ]; then
    INPUT="$CLAUDE_TOOL_INPUT"
  elif [ ! -t 0 ]; then
    INPUT="$(cat || true)"
  fi
  if [ -n "$INPUT" ]; then
    # Prefer jq; fall back to python3; last-resort grep.
    if command -v jq >/dev/null 2>&1; then
      FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // empty' 2>/dev/null || true)
    elif command -v python3 >/dev/null 2>&1; then
      FILE_PATH=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("tool_input",{}).get("file_path") or d.get("file_path") or "")' 2>/dev/null || true)
    else
      FILE_PATH=$(printf '%s' "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)
    fi
  fi
fi

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

# ─── 2. Only inspect test files ─────────────────────────────────────────────
case "$FILE_PATH" in
  *_test.go)                                      LANG=go ;;
  */test_*.py|*_test.py)                          LANG=py ;;
  *.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx)      LANG=ts ;;
  *) exit 0 ;;
esac

CONTENT=$(cat "$FILE_PATH")
# Strip comments + blank lines for density/trivial-assert counting
case "$LANG" in
  go|ts) STRIPPED=$(printf '%s' "$CONTENT" | sed -E 's://.*$::' | sed -E '/\/\*/,/\*\//d' | grep -v '^[[:space:]]*$') ;;
  py)    STRIPPED=$(printf '%s' "$CONTENT" | sed -E 's/#.*$//' | grep -v '^[[:space:]]*$') ;;
esac

NONBLANK=$(printf '%s\n' "$STRIPPED" | wc -l | tr -d ' ')

violations=()

# ─── T1: Trivial assertions ─────────────────────────────────────────────────
trivial_patterns_go='assert\.True\([[:space:]]*t[[:space:]]*,[[:space:]]*true|assert\.False\([[:space:]]*t[[:space:]]*,[[:space:]]*false|assert\.Equal\([[:space:]]*t[[:space:]]*,[[:space:]]*([0-9]+|"[^"]*"|true|false)[[:space:]]*,[[:space:]]*\1[[:space:]]*\)|require\.True\([[:space:]]*t[[:space:]]*,[[:space:]]*true'
trivial_patterns_ts='expect\((true|false|[0-9]+|"[^"]*")\)\.toBe\(\1\)|expect\(true\)\.toBeTruthy|expect\(false\)\.toBeFalsy'
	trivial_patterns_py='^[[:space:]]*assert[[:space:]]+True([[:space:]]*$|[[:space:]]*#)|^[[:space:]]*assert[[:space:]]+1[[:space:]]*==[[:space:]]*1'

case "$LANG" in
  go) if grep -nE "$trivial_patterns_go" "$FILE_PATH" >/dev/null 2>&1; then
        violations+=("T1 trivial assertion → $(grep -nE "$trivial_patterns_go" "$FILE_PATH" | head -3)")
      fi ;;
  ts) if grep -nE "$trivial_patterns_ts" "$FILE_PATH" >/dev/null 2>&1; then
        violations+=("T1 trivial assertion → $(grep -nE "$trivial_patterns_ts" "$FILE_PATH" | head -3)")
      fi ;;
  py) if grep -nE "$trivial_patterns_py" "$FILE_PATH" >/dev/null 2>&1; then
        violations+=("T1 trivial assertion → $(grep -nE "$trivial_patterns_py" "$FILE_PATH" | head -3)")
      fi ;;
esac

# ─── T2: Empty test body ────────────────────────────────────────────────────
case "$LANG" in
  go) EMPTY=$(grep -nE '^func[[:space:]]+Test[A-Za-z0-9_]+\([[:space:]]*t[[:space:]]*\*testing\.T[[:space:]]*\)[[:space:]]*\{[[:space:]]*\}$' "$FILE_PATH" || true) ;;
  ts) EMPTY=$(grep -nE "(it|test)\(['\"][^'\"]+['\"][[:space:]]*,[[:space:]]*(async[[:space:]]*)?\([^)]*\)[[:space:]]*=>[[:space:]]*\{[[:space:]]*\}\)" "$FILE_PATH" || true) ;;
  py) EMPTY=$(grep -nE '^def[[:space:]]+test_[A-Za-z0-9_]+\([^)]*\):[[:space:]]*(pass|\.\.\.)[[:space:]]*$' "$FILE_PATH" || true) ;;
esac
[ -n "$EMPTY" ] && violations+=("T2 empty test body → $(printf '%s' "$EMPTY" | head -3)")

# ─── T3: Assert-on-nothing (err-only checks) ────────────────────────────────
# Counts test functions where the ONLY assertion type is error-nil without value inspection.
case "$LANG" in
  go)
    NONERR_COUNT=$(grep -cE 'assert\.(Equal|Contains|NotEmpty|Len|EqualValues|True|False|JSONEq|Greater|Less|InDelta|InEpsilon|NotEqual|NotNil|Implements|IsType)\(|require\.(Equal|Contains|Len|True|False|JSONEq|Greater|Less|InDelta|NotEmpty|NotEqual|NotNil)\(' "$FILE_PATH" || true)
    ERR_ONLY_COUNT=$(grep -cE 'assert\.NoError\(|require\.NoError\(|assert\.Nil\([[:space:]]*t[[:space:]]*,[[:space:]]*err' "$FILE_PATH" || true)
    if [ "$ERR_ONLY_COUNT" -gt 0 ] && [ "$NONERR_COUNT" -eq 0 ]; then
      violations+=("T3 assert-on-nothing: only NoError/Nil(err) checks, no value assertions")
    fi ;;
  ts)
    NONERR_COUNT=$(grep -cE "expect\(.+\)\.(toBe\([^)]+\)|toEqual|toContain|toHaveLength|toHaveBeenCalledWith|toMatch|toStrictEqual|toBeGreater|toBeLess|toBeCloseTo|toBeInstanceOf)" "$FILE_PATH" || true)
    DEF_ONLY_COUNT=$(grep -cE "expect\([^)]+\)\.toBeDefined\(\)|expect\([^)]+\)\.not\.toBeUndefined" "$FILE_PATH" || true)
    if [ "$DEF_ONLY_COUNT" -gt 0 ] && [ "$NONERR_COUNT" -eq 0 ]; then
      violations+=("T3 assert-on-nothing: only toBeDefined/toBeUndefined checks, no value assertions")
    fi ;;
  py)
    # No convenient Python pattern - skip (pytest raises on exception anyway).
    : ;;
esac

# ─── T4: Mock-only (no call to System Under Test) ───────────────────────────
case "$LANG" in
  go)
    MOCK_ASSERTS=$(grep -cE 'mock\.AssertCalled|mock\.AssertExpectations|mock\.AssertNotCalled|mock\.On\(' "$FILE_PATH" || true)
    # Heuristic: SUT call = identifier.Method( that is NOT a testify/mock helper.
    # Two-pass via pipe (BSD grep has no PCRE negative lookahead).
    SUT_CALLS=$(grep -E '^[[:space:]]+[a-z][A-Za-z0-9_]*\.[A-Z][A-Za-z0-9_]*\(' "$FILE_PATH" 2>/dev/null \
                | grep -vE '\.(On|AssertCalled|AssertExpectations|AssertNotCalled|Return)\(' \
                | wc -l | tr -d ' ' || true)
    SUT_CALLS=${SUT_CALLS:-0}
    if [ "$MOCK_ASSERTS" -gt 0 ] && [ "$SUT_CALLS" -le "$MOCK_ASSERTS" ]; then
      # Only warn, not block (hard to detect perfectly without AST)
      warn "possible T4 mock-only test - ${MOCK_ASSERTS} mock assertions, ${SUT_CALLS} SUT-like calls in $FILE_PATH"
    fi ;;
  ts)
    MOCK_ASSERTS=$(grep -cE 'toHaveBeenCalled|toHaveBeenCalledWith|toHaveBeenCalledTimes' "$FILE_PATH" || true)
    SUT_CALLS=$(grep -cE "await[[:space:]]+[a-z]|render\(|renderHook\(|renderWithProviders\(" "$FILE_PATH" || true)
    if [ "$MOCK_ASSERTS" -gt 0 ] && [ "$SUT_CALLS" -eq 0 ]; then
      violations+=("T4 mock-only: only toHaveBeenCalled checks, no render/renderHook/await SUT call")
    fi ;;
  py)
    MOCK_ASSERTS=$(grep -cE '\.assert_called|\.assert_called_with|\.assert_not_called|\.called[[:space:]]*==' "$FILE_PATH" || true)
    SUT_CALLS=$(grep -cE '^[[:space:]]+result[[:space:]]*=|^[[:space:]]+await[[:space:]]+[a-z]' "$FILE_PATH" || true)
    if [ "$MOCK_ASSERTS" -gt 0 ] && [ "$SUT_CALLS" -eq 0 ]; then
      violations+=("T4 mock-only: only *.assert_called* checks, no SUT invocation (result = …)")
    fi ;;
esac

# ─── T5: Skip without ticket reference ──────────────────────────────────────
case "$LANG" in
  go) SKIPS=$(grep -nE 't\.Skip(Now)?\(' "$FILE_PATH" || true) ;;
  ts) SKIPS=$(grep -nE '(\.skip\(|^[[:space:]]*xit\(|^[[:space:]]*xdescribe\()' "$FILE_PATH" || true) ;;
  py) SKIPS=$(grep -nE '@pytest\.mark\.skip|pytest\.skip\(|unittest\.skip' "$FILE_PATH" || true) ;;
esac
if [ -n "$SKIPS" ]; then
  # Require #<number> within 2 lines of the skip
  while IFS= read -r skip_line; do
    [ -z "$skip_line" ] && continue
    LN=${skip_line%%:*}
    CTX=$(sed -n "$((LN-2)),$((LN+1))p" "$FILE_PATH" 2>/dev/null || true)
    if ! printf '%s' "$CTX" | grep -qE '#[0-9]+'; then
      violations+=("T5 skip without ticket → $skip_line (add '#<issue>' in a nearby comment)")
    fi
  done <<< "$SKIPS"
fi

# ─── T6: Density (soft warning) ─────────────────────────────────────────────
case "$LANG" in
  go) ASSERT_COUNT=$(grep -cE 'assert\.[A-Z]|require\.[A-Z]' "$FILE_PATH" || true) ;;
  ts) ASSERT_COUNT=$(grep -cE 'expect\(' "$FILE_PATH" || true) ;;
  py) ASSERT_COUNT=$(grep -cE '^[[:space:]]*assert[[:space:]]' "$FILE_PATH" || true) ;;
esac
if [ "$NONBLANK" -gt 40 ] && [ "$ASSERT_COUNT" -gt 0 ]; then
  RATIO=$(( NONBLANK / ASSERT_COUNT ))
  if [ "$RATIO" -gt 20 ]; then
    warn "low assertion density - ${ASSERT_COUNT} asserts / ${NONBLANK} non-blank lines (1 per ${RATIO}, target ≤ 20) in $FILE_PATH"
  fi
fi

# ─── Verdict ────────────────────────────────────────────────────────────────
if [ ${#violations[@]} -gt 0 ]; then
  log ""
  log "┌─ test-quality-gate refused $FILE_PATH ─"
  for v in "${violations[@]}"; do
    log "│ $v"
  done
  log "└─ Fix per CLAUDE.md rules 21–24 / docs/TESTING_RULES.md, then resave."
  exit 2
fi

exit 0
