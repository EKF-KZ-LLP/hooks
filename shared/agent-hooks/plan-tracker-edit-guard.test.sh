#!/usr/bin/env bash
set -euo pipefail

HOOK="${HOOK:-/Users/antonsahovskii/.local/share/agent-hooks/03-plan-tracker-edit-guard.sh}"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK" >&2; exit 1; }

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/plan-tracker-edit-guard-test.XXXXXX")"
trap 'chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

pass=0
fail=0

make_repo() {
  local mode="$1"
  local repo="$tmp_root/repo-$mode-$RANDOM"
  mkdir -p "$repo/.claude/plans" "$repo/.checkpoints/TASK-1" "$repo/src"
  (
    cd "$repo"
    git init -q
    git config user.email "test@example.invalid"
    git config user.name "Test Runner"
  )
  printf '%s\n' \
    "- [ ] TASK-1: build thing" \
    "  - status: in_progress" \
    "  - evidence: .checkpoints/TASK-1/evidence.md" \
    "  - note: existing context" \
    "- [x] TASK-DONE: closed thing" \
    "  - status: done" \
    "  - evidence: .checkpoints/TASK-1/evidence.md" \
    > "$repo/.claude/plans/current.md"
  if [ "$mode" = "absolute" ]; then
    printf '%s\n' "$repo/.claude/plans/current.md" > "$repo/.claude/active-tracker"
  else
    printf '%s\n' ".claude/plans/current.md" > "$repo/.claude/active-tracker"
  fi
  printf '%s\n' "Verdict: PASS" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  echo "$repo"
}

run_hook() {
  local repo="$1"
  local input="$2"
  (
    cd "$repo"
    printf '%s' "$input" | "$HOOK"
  ) >/tmp/plan-tracker-hook.out 2>&1
}

json_edit() {
  local repo="$1" target="$2" old="$3" new="$4"
  jq -n \
    --arg cwd "$repo" \
    --arg sid "plan-tracker-test-$$" \
    --arg target "$target" \
    --arg old "$old" \
    --arg new "$new" \
    '{tool_name:"Edit", session_id:$sid, cwd:$cwd, tool_input:{file_path:$target, old_string:$old, new_string:$new}}'
}

json_write() {
  local repo="$1" target="$2" content="$3"
  jq -n \
    --arg cwd "$repo" \
    --arg sid "plan-tracker-test-$$" \
    --arg target "$target" \
    --arg content "$content" \
    '{tool_name:"Write", session_id:$sid, cwd:$cwd, tool_input:{file_path:$target, content:$content}}'
}

json_edit_numeric_new_string() {
  local repo="$1" target="$2" old="$3"
  jq -n \
    --arg cwd "$repo" \
    --arg sid "plan-tracker-test-$$" \
    --arg target "$target" \
    --arg old "$old" \
    '{tool_name:"Edit", session_id:$sid, cwd:$cwd, tool_input:{file_path:$target, old_string:$old, new_string:123}}'
}

expect_exit() {
  local name="$1" expected="$2" repo="$3" input="$4"
  set +e
  run_hook "$repo" "$input"
  local status=$?
  set -e
  if [ "$status" = "$expected" ]; then
    printf 'PASS %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s expected=%s got=%s\n' "$name" "$expected" "$status" >&2
    sed -n '1,8p' /tmp/plan-tracker-hook.out >&2
    fail=$((fail + 1))
  fi
}

test_relative_tracker_blocks_close_without_pass() {
  local repo tracker input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  chmod 644 "$repo/.checkpoints/TASK-1/evidence.md"
  printf '%s\n' "Verdict: FAIL" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "- [ ] TASK-1: build thing" "- [x] TASK-1: build thing")"
  expect_exit "relative_tracker_blocks_close_without_pass" 2 "$repo" "$input"
}

test_absolute_tracker_blocks_close_without_pass() {
  local repo tracker input
  repo="$(make_repo absolute)"
  tracker="$repo/.claude/plans/current.md"
  chmod 644 "$repo/.checkpoints/TASK-1/evidence.md"
  printf '%s\n' "Verdict: FAIL" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "- [ ] TASK-1: build thing" "- [x] TASK-1: build thing")"
  expect_exit "absolute_tracker_blocks_close_without_pass" 2 "$repo" "$input"
}

test_close_with_pass_allowed() {
  local repo tracker input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  input="$(json_edit "$repo" "$tracker" "- [ ] TASK-1: build thing" "- [x] TASK-1: build thing")"
  expect_exit "close_with_pass_allowed" 0 "$repo" "$input"
}

test_non_tracker_edit_allowed() {
  local repo input
  repo="$(make_repo relative)"
  input="$(json_edit "$repo" "$repo/src/app.js" "old" "new")"
  expect_exit "non_tracker_edit_allowed" 0 "$repo" "$input"
}

test_add_unchecked_task_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md
  - note: existing context"
  new="$old
- [ ] TASK-2: follow up
  - status: planned
  - note: created by agent"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "add_unchecked_task_allowed" 0 "$repo" "$input"
}

test_add_full_task_with_required_evidence_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md
  - note: existing context"
  new="$old
- [ ] TASK-2: follow up
  - type: code
  - required: true
  - scope: src/app.js
  - source_of_truth: user request
  - success_criteria: behavior verified
  - verification: npm test
  - evidence: .checkpoints/TASK-2/evidence.md
  - result: pending
  - commit: pending
  - status: planned"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "add_full_task_with_required_evidence_allowed" 0 "$repo" "$input"
}

test_add_context_to_open_task_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md
  - note: existing context"
  new="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md
  - note: existing context
  - context: checked runtime state"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "add_context_to_open_task_allowed" 0 "$repo" "$input"
}

test_add_evidence_line_blocked() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress"
  new="$old
  - evidence: .checkpoints/FAKE/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "add_evidence_line_blocked" 2 "$repo" "$input"
}

test_delete_task_blocked() {
  local repo tracker content input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  content="- [ ] TASK-1: build thing"
  input="$(json_write "$repo" "$tracker" "$content")"
  expect_exit "delete_task_blocked" 2 "$repo" "$input"
}

test_completed_block_edit_blocked() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [x] TASK-DONE: closed thing
  - status: done"
  new="- [x] TASK-DONE: closed thing
  - status: done
  - note: edit closed block"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "completed_block_edit_blocked" 2 "$repo" "$input"
}

test_direct_evidence_write_blocked() {
  local repo input
  repo="$(make_repo relative)"
  input="$(json_write "$repo" "$repo/.checkpoints/TASK-1/evidence.md" "Verdict: PASS")"
  expect_exit "direct_evidence_write_blocked" 2 "$repo" "$input"
}

test_status_done_with_pass_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [x] TASK-1: build thing
  - status: done
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "status_done_with_pass_allowed" 0 "$repo" "$input"
}

test_reopen_closed_task_allowed() {
  local repo tracker input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  input="$(json_edit "$repo" "$tracker" "- [x] TASK-DONE: closed thing" "- [ ] TASK-DONE: closed thing")"
  expect_exit "reopen_closed_task_allowed" 0 "$repo" "$input"
}

test_reopen_status_to_in_progress_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [x] TASK-DONE: closed thing
  - status: done
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [ ] TASK-DONE: closed thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "reopen_status_to_in_progress_allowed" 0 "$repo" "$input"
}

test_status_failed_with_fail_evidence_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  chmod 644 "$repo/.checkpoints/TASK-1/evidence.md"
  printf '%s\n' "Verdict: FAIL" "Command: codex review" "Result: FAIL" "Commit: $(cd "$repo" && git rev-parse HEAD 2>/dev/null || echo UNKNOWN)" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [ ] TASK-1: build thing
  - status: failed
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "status_failed_with_fail_evidence_allowed" 0 "$repo" "$input"
}

test_status_failed_requires_open_checkbox() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  chmod 644 "$repo/.checkpoints/TASK-1/evidence.md"
  printf '%s\n' "Verdict: FAIL" "Command: codex review" "Result: FAIL" "Commit: $(cd "$repo" && git rev-parse HEAD 2>/dev/null || echo UNKNOWN)" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  old="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [x] TASK-1: build thing
  - status: failed
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "status_failed_requires_open_checkbox" 2 "$repo" "$input"
}

test_reopen_failed_status_to_in_progress_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  chmod 644 "$repo/.checkpoints/TASK-1/evidence.md"
  printf '%s\n' "Verdict: FAIL" "Command: codex review" "Result: FAIL" "Commit: $(cd "$repo" && git rev-parse HEAD 2>/dev/null || echo UNKNOWN)" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  perl -0pi -e 's/status: in_progress/status: failed/' "$tracker"
  old="- [ ] TASK-1: build thing
  - status: failed
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [ ] TASK-1: build thing
  - status: in_progress
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "reopen_failed_status_to_in_progress_allowed" 0 "$repo" "$input"
}

test_closed_task_result_commit_verified_allowed() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  old="- [x] TASK-DONE: closed thing
  - status: done
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [x] TASK-DONE: closed thing
  - result: BLOCKED documented - real numbers measured see artifact under .checkpoints; coverage gap 8-12h next-cycle plan
  - commit: a073c55
  - status: verified
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "closed_task_result_commit_verified_allowed" 0 "$repo" "$input"
}

test_closed_task_metadata_without_pass_blocked() {
  local repo tracker old new input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  chmod 644 "$repo/.checkpoints/TASK-1/evidence.md"
  printf '%s\n' "Verdict: FAIL" > "$repo/.checkpoints/TASK-1/evidence.md"
  chmod 444 "$repo/.checkpoints/TASK-1/evidence.md"
  old="- [x] TASK-DONE: closed thing
  - status: done
  - evidence: .checkpoints/TASK-1/evidence.md"
  new="- [x] TASK-DONE: closed thing
  - result: should not pass
  - commit: a073c55
  - status: verified
  - evidence: .checkpoints/TASK-1/evidence.md"
  input="$(json_edit "$repo" "$tracker" "$old" "$new")"
  expect_exit "closed_task_metadata_without_pass_blocked" 2 "$repo" "$input"
}

test_tracker_validation_crash_fail_closed() {
  local repo tracker input
  repo="$(make_repo relative)"
  tracker="$repo/.claude/plans/current.md"
  input="$(json_edit_numeric_new_string "$repo" "$tracker" "- [ ] TASK-1: build thing")"
  expect_exit "tracker_validation_crash_fail_closed" 2 "$repo" "$input"
}

test_active_tracker_swap_to_trivial_blocked() {
  local repo pointer input
  repo="$(make_repo relative)"
  pointer="$repo/.claude/active-tracker"
  printf '%s\n' \
    "- [ ] SESSION-STOP-1: trivial stop" \
    "  - status: planned" \
    "  - evidence: .checkpoints/TASK-1/evidence.md" \
    > "$repo/.claude/plans/trivial.md"
  input="$(json_write "$repo" "$pointer" ".claude/plans/trivial.md")"
  expect_exit "active_tracker_swap_to_trivial_blocked" 2 "$repo" "$input"
}

test_approval_refs_edit_blocked() {
  local repo approval_refs input
  repo="$(make_repo relative)"
  approval_refs="$repo/home/.claude/approval-refs.allow"
  mkdir -p "$(dirname "$approval_refs")"
  input="$(json_write "$repo" "$approval_refs" "deadbeef")"
  expect_exit "approval_refs_edit_blocked" 2 "$repo" "$input"
}

test_relative_tracker_blocks_close_without_pass
test_absolute_tracker_blocks_close_without_pass
test_close_with_pass_allowed
test_non_tracker_edit_allowed
test_add_unchecked_task_allowed
test_add_full_task_with_required_evidence_allowed
test_add_context_to_open_task_allowed
test_add_evidence_line_blocked
test_delete_task_blocked
test_completed_block_edit_blocked
test_direct_evidence_write_blocked
test_status_done_with_pass_allowed
test_reopen_closed_task_allowed
test_reopen_status_to_in_progress_allowed
test_status_failed_with_fail_evidence_allowed
test_status_failed_requires_open_checkbox
test_reopen_failed_status_to_in_progress_allowed
test_closed_task_result_commit_verified_allowed
test_closed_task_metadata_without_pass_blocked
test_tracker_validation_crash_fail_closed
test_active_tracker_swap_to_trivial_blocked
test_approval_refs_edit_blocked

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
