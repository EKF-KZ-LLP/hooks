#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/global/ralph-loop-enforce.sh"
VALIDATOR="$ROOT/global/ralph-loop-validate.py"
GUARD="$ROOT/global/guard-no-tracker-overwrite.sh"
SECRET_GUARD="$ROOT/global/guard-no-secrets.sh"
SAFETY_GUARD="$ROOT/global/guard-no-force-push.sh"
SESSION_START="$ROOT/per-repo/ralph-loop/01-session-start-load-context.sh"
HOOK03="$ROOT/per-repo/ralph-loop/03-plan-tracker-edit-guard.sh"
MERGE_GATE="$ROOT/per-repo/ralph-loop/04-gh-pr-merge-gate.sh"
PREF_HELPER="$ROOT/global/record-pre-fix-failing-test.sh"

pass=0
fail=0

note() { printf '%s\n' "$*"; }

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "ralph@example.test"
  git -C "$dir" config user.name "Ralph Test"
  mkdir -p "$dir/.claude" "$dir/.checkpoints/TASK-001" "$dir/.checkpoints/TASK-999" "$dir/src"
  printf 'print("v1")\n' > "$dir/src/app.py"
  printf '# Workplan\n' > "$dir/WORKPLAN.md"
  printf '# Handoff\n' > "$dir/HANDOFF.md"
  git -C "$dir" add WORKPLAN.md HANDOFF.md src/app.py
  git -C "$dir" commit -q -m "initial"
  printf '%s\n' "$dir"
}

head_sha() {
  git -C "$1" rev-parse HEAD
}

task_block() {
  local state="$1" status="$2" result="$3" task_type="${4:-code}" evidence="${5:-pending}" commit="${6:-pending}"
  cat <<EOF
- [$state] TASK-001: Hard gate test
  - type: $task_type
  - required: true
  - scope: src/app.py
  - source_of_truth: negative test
  - success_criteria: hook blocks bypass
  - verification: local hook invocation
  - evidence: $evidence
  - result: $result
  - commit: $commit
  - status: $status
EOF
}

write_attempt_evidence() {
  local repo="$1" task="$2" num="$3" sha="$4"
  local file="$repo/.checkpoints/$task/attempt-$num.md"
  cat > "$file" <<EOF
Command: attempt $num
Command: pytest attempt $num
Result: FAIL
Commit: $sha
repo docs tests git logs
EOF
  printf '%s\n' ".checkpoints/$task/attempt-$num.md"
}

write_handoff_attempts() {
  local repo="$1" task="$2" count="$3" duplicate="${4:-no}" include_docs_search="${5:-yes}" include_consult="${6:-yes}" include_strategy="${7:-yes}"
  local sha
  sha="$(head_sha "$repo")"
  {
    printf '# Handoff\n\n'
    printf '## Attempt Log\n'
    local i
    for i in $(seq 1 "$count"); do
      local ev hyp decision extras
      ev="$(write_attempt_evidence "$repo" "$task" "$i" "$sha")"
      if [ "$duplicate" = "yes" ]; then
        hyp="same hypothesis"
      else
        hyp="hypothesis $i"
      fi
      decision="retry"
      [ "$i" -ge 2 ] && [ "$include_strategy" = "yes" ] && decision="strategy_shift"
      extras="repo docs tests git logs"
      [ "$include_docs_search" = "yes" ] && extras="$extras official docs search Context7 internet"
      [ "$include_consult" = "yes" ] && extras="$extras Senior Engineer codex:rescue codex:codex-rescue"
      cat <<EOF
- attempt: $i
  task_id: $task
  trigger: test_failed
  hypothesis: $hyp
  action: inspect $extras
  command_or_artifact: pytest and rg
  result: failed after $extras
  next_decision: $decision
  evidence: $ev
  commit: $sha
  timestamp: 2026-05-12T00:00:0${i}+03:00
EOF
    done
  } > "$repo/HANDOFF.md"
}

write_review_evidence() {
  local repo="$1" sha="$2" with_codex="$3"
  local file="$repo/.checkpoints/TASK-001/evidence.md"
  {
    printf 'Verdict: PASS\n'
    printf 'Command: review\n'
    printf 'Result: PASS\n'
    printf 'Commit: %s\n' "$sha"
    printf 'Review-scope: full-code-path\n'
    printf 'Diff-only: false\n'
    printf 'Codex review\n'
    if [ "$with_codex" = "yes" ]; then
      printf 'Codex-tool: Claude Code plugin + codex:rescue\n'
      printf 'Codex-subagent: codex:codex-rescue\n'
    fi
  } > "$file"
}

invoke_write() {
  local repo="$1" file="$2" content="$3"
  CONTENT="$content" FILE_PATH="$file" python3 - <<'PY' | CLAUDE_PROJECT_DIR="$repo" bash "$HOOK"
import json, os
print(json.dumps({
    "tool_name": "Write",
    "tool_input": {
        "file_path": os.environ["FILE_PATH"],
        "content": os.environ["CONTENT"],
    },
}))
PY
}

invoke_edit_file() {
  local repo="$1" file="$2" content="$3"
  invoke_write "$repo" "$file" "$content"
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
    printf '%s\n' "$output" | head -3
  else
    fail=$((fail + 1))
    note "FAIL no block: $name"
  fi
}

test_blocked_without_attempt() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block " " blocked "missing credential: TEST_TOKEN" code)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  expect_block "TASK-ID blocked without attempt log" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_failed_after_one_attempt() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block " " failed "retry budget exhausted: one attempt is not enough" code)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 1 no yes yes
  expect_block "TASK-ID failed after one attempt" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_duplicate_attempts() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending docs)"
  new="$(task_block " " failed "retry budget exhausted after docs work" docs)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 2 yes yes yes
  expect_block "duplicate attempt hypothesis" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_failed_without_strategy_shift_or_consult() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending docs)"
  new="$(task_block " " failed "retry budget exhausted after docs work" docs)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 2 no yes no no
  expect_block "failed task without strategy shift or consultation" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_invalid_blocker_text() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block " " blocked "тесты падают" code)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 3 no yes yes
  expect_block "invalid blocker text" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_external_without_docs_search() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block " " blocked "external system unavailable: library API returns 503" code)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 3 no no yes
  expect_block "external issue without docs search" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_stuck_without_consult() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block " " blocked "retry budget exhausted after local investigation" code)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 3 no yes no
  expect_block "stuck task without Senior/Codex consultation" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_handoff_not_updated_for_task() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block " " failed "retry budget exhausted after attempts" code)"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-999 3 no yes yes
  expect_block "HANDOFF not updated for failed task" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_done_with_bad_blocked_task() {
  local repo tracker
  repo="$(make_repo)"
  tracker="$(task_block " " blocked "не получилось" code)"
  printf '%s\n' "$tracker" > "$repo/WORKPLAN.md"
  printf '%s\n' "$repo/WORKPLAN.md" > "$repo/.claude/active-tracker"
  write_handoff_attempts "$repo" TASK-001 3 no yes yes
  expect_block "DONE with blocked task without valid blocker" python3 "$VALIDATOR" stop --project "$repo"
}

test_closed_without_evidence() {
  local repo old new
  repo="$(make_repo)"
  old="$(task_block " " in_progress pending code)"
  new="$(task_block "x" done pending code pending "$(head_sha "$repo")")"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  expect_block "checkbox closed without evidence" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_done_with_open_required() {
  local repo tracker
  repo="$(make_repo)"
  tracker="$(task_block " " in_progress pending code)"
  printf '%s\n' "$tracker" > "$repo/WORKPLAN.md"
  printf '%s\n' "$repo/WORKPLAN.md" > "$repo/.claude/active-tracker"
  expect_block "DONE with open required TASK-ID" python3 "$VALIDATOR" stop --project "$repo"
}

test_codex_not_rescue() {
  local repo old new sha
  repo="$(make_repo)"
  sha="$(head_sha "$repo")"
  write_review_evidence "$repo" "$sha" no
  old="$(task_block " " in_progress pending review)"
  new="$(task_block "x" done "review passed" review ".checkpoints/TASK-001/evidence.md" "$sha")"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  expect_block "Codex evidence not via codex:rescue" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_review_old_sha() {
  local repo old new old_sha new_sha
  repo="$(make_repo)"
  old_sha="$(head_sha "$repo")"
  printf 'print("v2")\n' > "$repo/src/app.py"
  git -C "$repo" add src/app.py
  git -C "$repo" commit -q -m "change code"
  new_sha="$(head_sha "$repo")"
  write_review_evidence "$repo" "$old_sha" yes
  old="$(task_block " " in_progress pending review)"
  new="$(task_block "x" done "review passed" review ".checkpoints/TASK-001/evidence.md" "$new_sha")"
  printf '%s\n' "$old" > "$repo/WORKPLAN.md"
  expect_block "review evidence on old SHA" invoke_write "$repo" "$repo/WORKPLAN.md" "$new"
}

test_skip_reason_direct_bash() {
  local repo payload
  repo="$(make_repo)"
  payload="{\"tool_input\":{\"command\":\"printf forged > $repo/.checkpoints/foo/skip-reason.md\"}}"
  expect_block "direct Bash write to skip-reason" bash -c "printf '%s' '$payload' | bash '$GUARD'"
}

test_skip_reason_write_tool() {
  local repo
  repo="$(make_repo)"
  printf '%s\n' "$repo/tracker.md" > "$repo/.claude/active-tracker"
  printf '%s\n' '- [ ] legacy task <!-- evidence: .checkpoints/foo/evidence.md -->' > "$repo/tracker.md"
  mkdir -p "$repo/.checkpoints/foo"
  expect_block "direct Write to skip-reason" env CONTENT="forged" FILE_PATH="$repo/.checkpoints/foo/skip-reason.md" bash -c '
python3 - <<PY | (cd "$0" && bash "$1")
import json, os
print(json.dumps({"tool_name":"Write","tool_input":{"file_path":os.environ["FILE_PATH"],"content":os.environ["CONTENT"]}}))
PY
' "$repo" "$HOOK03"
}

test_handoff_attempt_history_deletion() {
  local repo old new
  repo="$(make_repo)"
  write_handoff_attempts "$repo" TASK-001 2 no yes yes
  old="$(cat "$repo/HANDOFF.md")"
  new="$(printf '%s\n' "$old" | awk 'BEGIN{drop=0} /^- attempt: 2/{drop=1} drop && /^- attempt: 3/{drop=0} !drop{print}')"
  expect_block "HANDOFF attempt history deletion" invoke_write "$repo" "$repo/HANDOFF.md" "$new"
}

test_touch_workplan_freshness_forgery() {
  local repo payload
  repo="$(make_repo)"
  payload="{\"tool_input\":{\"command\":\"touch $repo/WORKPLAN.md\"}}"
  expect_block "touch WORKPLAN freshness forgery" bash -c "printf '%s' '$payload' | bash '$GUARD'"
}

test_source_edit_without_active_plan() {
  local repo
  repo="$(make_repo)"
  expect_block "source edit without active TASK-ID" invoke_edit_file "$repo" "$repo/src/app.py" 'print("changed")'
}

test_behavior_code_without_prefix_test() {
  local repo plan
  repo="$(make_repo)"
  plan="$(task_block " " in_progress pending code)"
  printf '%s\n' "$plan" > "$repo/WORKPLAN.md"
  cat >> "$repo/HANDOFF.md" <<EOF
plan_vs_code_check: TASK-001
files: src/app.py
mismatch: none
decision: proceed
EOF
  expect_block "behavior code without pre-fix failing test" invoke_edit_file "$repo" "$repo/src/app.py" 'print("changed")'
}

test_failed_verification_without_fresh_attempt() {
  local repo payload
  repo="$(make_repo)"
  printf '%s\n' "$(task_block " " in_progress pending code)" > "$repo/WORKPLAN.md"
  payload='{"tool_name":"Bash","tool_input":{"command":"pytest tests/test_app.py"},"tool_response":{"exit_code":1}}'
  expect_block "failed verification without fresh attempt" bash -c "printf '%s' '$payload' | python3 '$VALIDATOR' posttool-failure --project '$repo'"
}

test_failed_verification_duplicate_latest_hypothesis() {
  local repo payload
  repo="$(make_repo)"
  printf '%s\n' "$(task_block " " in_progress pending code)" > "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 2 yes yes yes
  touch "$repo/WORKPLAN.md"
  payload='{"tool_name":"Bash","tool_input":{"command":"pytest tests/test_app.py"},"tool_response":{"exit_code":1}}'
  expect_block "failed verification duplicate latest hypothesis" bash -c "printf '%s' '$payload' | python3 '$VALIDATOR' posttool-failure --project '$repo'"
}

test_failed_verification_without_workplan_update() {
  local repo payload
  repo="$(make_repo)"
  printf '%s\n' "$(task_block " " in_progress pending code)" > "$repo/WORKPLAN.md"
  touch -t 202001010000 "$repo/WORKPLAN.md"
  write_handoff_attempts "$repo" TASK-001 1 no yes yes
  payload='{"tool_name":"Bash","tool_input":{"command":"pytest tests/test_app.py"},"tool_response":{"exit_code":1}}'
  expect_block "failed verification without WORKPLAN update" bash -c "printf '%s' '$payload' | python3 '$VALIDATOR' posttool-failure --project '$repo'"
}

test_session_start_invalid_tracker_contract() {
  local repo tracker
  repo="$(make_repo)"
  tracker="$repo/tracker.md"
  printf '%s\n' '- [ ] free checkbox without metadata' > "$tracker"
  printf '%s\n' "$tracker" > "$repo/.claude/active-tracker"
  expect_block "session start invalid tracker contract" env RALPH_GLOBAL_HOOKS_DIR="$ROOT/global" bash -c "cd '$repo' && '$SESSION_START'"
}

test_secret_write_blocks() {
  local payload
  payload='{"tool_name":"Write","tool_input":{"file_path":"tmp.txt","content":"api_key = \"1234567890abcdef\""}}'
  expect_block "secret write blocks" bash -c "printf '%s' '$payload' | bash '$SECRET_GUARD'"
}

test_destructive_rm_without_approval() {
  local repo payload
  repo="$(make_repo)"
  payload="{\"tool_input\":{\"command\":\"rm -rf $repo/src\"}}"
  expect_block "destructive rm without approval" bash -c "printf '%s' '$payload' | bash '$SAFETY_GUARD'"
}

test_pr_head_mismatch_blocks_merge() {
  local repo fakebin local_sha pr_sha ev
  repo="$(make_repo)"
  local_sha="$(head_sha "$repo")"
  pr_sha="1111111111111111111111111111111111111111"
  mkdir -p "$repo/.checkpoints/TASK-001" "$repo/.claude"
  ev="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$ev" <<EOF
Verdict: PASS
Command: review
Result: PASS
Commit: $local_sha
Review-scope: full-code-path
Diff-only: false
Senior review full-code-path
EOF
  cat > "$repo/tracker.md" <<EOF
- [x] PR #1 pr-1-merged evidence: .checkpoints/TASK-001/evidence.md
EOF
  printf '%s\n' "$repo/tracker.md" > "$repo/.claude/active-tracker"
  fakebin="$repo/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "pr checks 1 --required") exit 0 ;;
  *"reviewDecision,reviewRequests"*) printf '{"reviewDecision":"APPROVED","reviewRequests":[]}\n'; exit 0 ;;
  *"statusCheckRollup"*) printf '{"statusCheckRollup":[]}\n'; exit 0 ;;
  *"headRefOid"*) printf '%s\n' "$pr_sha"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/gh"
  expect_block "PR head mismatch review evidence" env PATH="$fakebin:$PATH" bash -c "cd '$repo' && printf '%s' '{\"tool_input\":{\"command\":\"gh pr merge 1\"}}' | bash '$MERGE_GATE'"
}

test_prefix_helper_rejects_passing_test() {
  local repo
  repo="$(make_repo)"
  expect_block "pre-fix helper rejects passing command" bash -c "cd '$repo' && '$PREF_HELPER' TASK-001 -- true"
}

test_blocked_without_attempt
test_failed_after_one_attempt
test_duplicate_attempts
test_failed_without_strategy_shift_or_consult
test_invalid_blocker_text
test_external_without_docs_search
test_stuck_without_consult
test_handoff_not_updated_for_task
test_done_with_bad_blocked_task
test_closed_without_evidence
test_done_with_open_required
test_codex_not_rescue
test_review_old_sha
test_skip_reason_direct_bash
test_skip_reason_write_tool
test_handoff_attempt_history_deletion
test_touch_workplan_freshness_forgery
test_source_edit_without_active_plan
test_behavior_code_without_prefix_test
test_failed_verification_without_fresh_attempt
test_failed_verification_duplicate_latest_hypothesis
test_failed_verification_without_workplan_update
test_session_start_invalid_tracker_contract
test_secret_write_blocks
test_destructive_rm_without_approval
test_pr_head_mismatch_blocks_merge
test_prefix_helper_rejects_passing_test

note "negative tests passed: $pass"
if [ "$fail" -ne 0 ]; then
  note "negative tests failed: $fail"
  exit 1
fi
