#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/per-repo/ralph-loop/05-stop-open-tasks-gate.sh"
VALIDATOR_DIR="$ROOT/global"

PASS=0
FAIL=0

tmpdirs=()
cleanup() {
  for d in "${tmpdirs[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

make_repo() {
  local dir
  dir="$(mktemp -d)"
  tmpdirs+=("$dir")
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Hook Test"
  mkdir -p "$dir/.claude/sprints" "$dir/.checkpoints/TASK-001"
  printf '# Workplan\n' > "$dir/WORKPLAN.md"
  printf '# Handoff\n\n## Attempt Log\n' > "$dir/HANDOFF.md"
  printf 'print("hello")\n' > "$dir/app.py"
  git -C "$dir" add WORKPLAN.md HANDOFF.md app.py
  git -C "$dir" commit -q -m init
  printf '%s\n' ".claude/sprints/current.md" > "$dir/.claude/active-tracker"
  cat > "$dir/.claude/sprints/current.md" <<'EOF'
- [ ] TASK-001: Open task
  - type: code
  - required: true
  - scope: app.py
  - source_of_truth: test
  - success_criteria: test
  - verification: test
  - evidence: pending
  - result: pending
  - commit: pending
  - status: in_progress
EOF
  printf '%s\n' "$dir"
}

run_hook() {
  local repo="$1" payload="${2:-{}}"
  cd "$repo"
  printf '%s' "$payload" | RALPH_GLOBAL_HOOKS_DIR="$VALIDATOR_DIR" bash "$HOOK"
}

expect_allow() {
  local name="$1"; shift
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "PASS allow: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL expected allow: $name rc=$rc"
    printf '%s\n' "$out"
    FAIL=$((FAIL + 1))
  fi
}

expect_block() {
  local name="$1"; shift
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "PASS block: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL expected block: $name"
    printf '%s\n' "$out"
    FAIL=$((FAIL + 1))
  fi
}

test_open_tasks_default_allow() {
  local repo
  repo="$(make_repo)"
  expect_allow "open tasks default Stop does not loop" run_hook "$repo" '{}'
}

test_open_tasks_strict_blocks() {
  local repo
  repo="$(make_repo)"
  expect_block "open tasks strict Stop blocks" env RALPH_STOP_STRICT=1 RALPH_GLOBAL_HOOKS_DIR="$VALIDATOR_DIR" bash -c "cd '$repo' && printf '{}' | '$HOOK'"
}

test_missing_tracker_default_allow() {
  local repo
  repo="$(make_repo)"
  rm -f "$repo/.claude/active-tracker"
  expect_allow "missing tracker default Stop does not loop" run_hook "$repo" '{}'
}

test_open_tasks_completion_claim_blocks() {
  local repo transcript payload
  repo="$(make_repo)"
  transcript="$repo/transcript.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Готово. Все задачи завершены."}]}}' > "$transcript"
  payload="{\"transcript_path\":\"$transcript\"}"
  expect_block "open tasks completion claim blocks" run_hook "$repo" "$payload"
}

test_open_tasks_default_allow
test_open_tasks_strict_blocks
test_missing_tracker_default_allow
test_open_tasks_completion_claim_blocks

if [ "$FAIL" -ne 0 ]; then
  echo "stop-open-tasks-gate tests failed: PASS=$PASS FAIL=$FAIL"
  exit 1
fi

echo "stop-open-tasks-gate tests passed: $PASS"
