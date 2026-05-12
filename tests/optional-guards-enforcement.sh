#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSERTION_GUARD="$ROOT/per-repo/optional-guards/assertion-change-guard.sh"
TEST_DATA_GUARD="$ROOT/per-repo/optional-guards/test-data-guard.sh"
TEST_QUALITY_GATE="$ROOT/per-repo/optional-guards/test-quality-gate.sh"
SQL_GUARD="$ROOT/per-repo/optional-guards/destructive-sql-guard.sh"
GRAPHIFY_HINT="$ROOT/per-repo/optional-guards/graphify-hint.sh"
ISSUE_CLOSE="$ROOT/per-repo/optional-guards/validate-issue-close.sh"

pass=0
fail=0

note() { printf '%s\n' "$*"; }

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "optional@example.test"
  git -C "$dir" config user.name "Optional Guard Test"
  printf 'def total():\n    return 1\n' > "$dir/calc.py"
  printf 'def test_total():\n    assert total() == 1\n' > "$dir/calc_test.py"
  mkdir -p "$dir/fixtures"
  printf '{"total":1}\n' > "$dir/fixtures/data.golden"
  git -C "$dir" add calc.py calc_test.py fixtures/data.golden
  git -C "$dir" commit -q -m "initial"
  printf '%s\n' "$dir"
}

expect_block() {
  local name="$1"
  shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    pass=$((pass + 1))
    note "PASS block: $name"
    printf '%s\n' "$output" | head -4
  else
    fail=$((fail + 1))
    note "FAIL no block: $name"
  fi
}

expect_allow() {
  local name="$1"
  shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    pass=$((pass + 1))
    note "PASS allow: $name"
    printf '%s\n' "$output" | head -4
  else
    fail=$((fail + 1))
    note "FAIL unexpected block: $name"
    printf '%s\n' "$output" | head -8
  fi
}

test_assertion_change_blocks() {
  local repo
  repo="$(make_repo)"
  python3 - "$repo/calc_test.py" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("== 1", "== 2"))
PY
  expect_block "assertion-only test change" bash -c "cd '$repo' && '$ASSERTION_GUARD' calc_test.py"
}

test_fixture_plus_assertion_blocks() {
  local repo
  repo="$(make_repo)"
  printf '{"total":2}\n' > "$repo/fixtures/data.golden"
  python3 - "$repo/calc_test.py" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("== 1", "== 2"))
PY
  expect_block "fixture plus assertion without production" bash -c "cd '$repo' && '$TEST_DATA_GUARD' fixtures/data.golden"
}

test_quality_trivial_assertion_blocks() {
  local dir file
  dir="$(mktemp -d)"
  file="$dir/test_quality_test.py"
  printf 'def test_placeholder():\n    assert True\n' > "$file"
  expect_block "trivial Python assertion" "$TEST_QUALITY_GATE" "$file"
}

test_quality_skip_without_ticket_blocks() {
  local dir file
  dir="$(mktemp -d)"
  file="$dir/test_skip_test.py"
  printf 'import pytest\n\n@pytest.mark.skip(reason="later")\ndef test_skip():\n    items = [1]\n    assert len(items) == 1\n' > "$file"
  expect_block "skip without issue ticket" "$TEST_QUALITY_GATE" "$file"
}

test_destructive_sql_blocks_delete() {
  local payload
  payload='{"tool_input":{"command":"psql -c \"delete from users;\""}}'
  expect_block "destructive SQL delete" bash -c "printf '%s' '$payload' | '$SQL_GUARD'"
}

test_destructive_sql_blocks_truncate() {
  local payload
  payload='{"tool_input":{"command":"mysql -e \"TRUNCATE users\""}}'
  expect_block "destructive SQL truncate" bash -c "printf '%s' '$payload' | '$SQL_GUARD'"
}

test_graphify_hint_emits_context() {
  local repo payload output
  repo="$(mktemp -d)"
  mkdir -p "$repo/graphify-out"
  printf '{}\n' > "$repo/graphify-out/graph.json"
  payload='{"tool_input":{"command":"rg service"}}'
  output="$(cd "$repo" && printf '%s' "$payload" | "$GRAPHIFY_HINT")"
  if printf '%s' "$output" | grep -q 'additionalContext'; then
    pass=$((pass + 1))
    note "PASS hint: graphify additionalContext"
    printf '%s\n' "$output" | head -2
  else
    fail=$((fail + 1))
    note "FAIL no hint: graphify additionalContext"
  fi
}

test_issue_close_blocks_unchecked_dod() {
  local repo fakebin
  repo="$(mktemp -d)"
  fakebin="$repo/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "issue view 123 --json body -q .body") printf '%s\n' '- [ ] Ship the acceptance criteria'; exit 0 ;;
  "issue view 123 --json comments -q .comments[].body") printf '%s\n' ''; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$fakebin/gh"
  expect_block "issue close with unchecked DoD" env PATH="$fakebin:$PATH" "$ISSUE_CLOSE" 123
}

test_assertion_change_blocks
test_fixture_plus_assertion_blocks
test_quality_trivial_assertion_blocks
test_quality_skip_without_ticket_blocks
test_destructive_sql_blocks_delete
test_destructive_sql_blocks_truncate
test_graphify_hint_emits_context
test_issue_close_blocks_unchecked_dod

note "optional guard tests passed: $pass"
if [ "$fail" -ne 0 ]; then
  note "optional guard tests failed: $fail"
  exit 1
fi
