#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/global/ralph-loop-enforce.sh"
VALIDATOR="$ROOT/global/ralph-loop-validate.py"
GUARD="$ROOT/global/guard-no-tracker-overwrite.sh"
SECRET_GUARD="$ROOT/global/guard-no-secrets.sh"
SAFETY_GUARD="$ROOT/global/guard-no-force-push.sh"
SESSION_START="$ROOT/per-repo/ralph-loop/01-session-start-load-context.sh"
HOOK02="$ROOT/per-repo/ralph-loop/02-user-prompt-pending-tasks.sh"
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
  {
    printf 'Command: attempt %s\n' "$num"
    printf 'Command: pytest attempt %s\n' "$num"
    printf 'Result: FAIL\n'
    printf 'Commit: %s\n' "$sha"
    printf 'repo docs tests git logs\n'
  } > "$file"
  printf '%s\n' ".checkpoints/$task/attempt-$num.md"
}

write_handoff_attempts() {
  local repo="$1" task="$2" count="$3" duplicate="${4:-no}" include_docs_search="${5:-yes}" include_consult="${6:-yes}" include_strategy="${7:-yes}"
  local sha
  sha="$(head_sha "$repo")"
  printf '# Handoff\n\n## Attempt Log\n' > "$repo/HANDOFF.md"
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
    {
      printf -- '- attempt: %s\n' "$i"
      printf '  task_id: %s\n' "$task"
      printf '  trigger: test_failed\n'
      printf '  hypothesis: %s\n' "$hyp"
      printf '  action: inspect %s\n' "$extras"
      printf '  command_or_artifact: pytest and rg\n'
      printf '  result: failed after %s\n' "$extras"
      printf '  next_decision: %s\n' "$decision"
      printf '  evidence: %s\n' "$ev"
      printf '  commit: %s\n' "$sha"
      printf '  timestamp: 2026-05-12T00:00:0%s+03:00\n' "$i"
    } >> "$repo/HANDOFF.md"
  done
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
      printf 'AGENTS.md: read\n'
      printf 'Verbatim: preserved\n'
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
    printf '%s\n' "$output" | head -3
  else
    fail=$((fail + 1))
    note "FAIL unexpected block: $name"
    printf '%s\n' "$output" | head -10
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

test_done_with_zero_required_tracker() {
  local repo tracker
  repo="$(make_repo)"
  tracker="$repo/.claude/sprints/trivial.md"
  mkdir -p "$repo/.claude/sprints"
  cat > "$tracker" <<EOF
- [ ] SESSION-STOP-001: trivial stop tracker
  - type: other
  - required: false
  - scope: .claude/sprints/trivial.md
  - source_of_truth: negative test
  - success_criteria: should not be accepted as real active tracker
  - verification: python3 ralph-loop-validate.py stop
  - evidence: pending
  - result: pending
  - commit: pending
  - status: planned
EOF
  printf '%s\n' ".claude/sprints/trivial.md" > "$repo/.claude/active-tracker"
  expect_block "DONE with zero required active tracker" python3 "$VALIDATOR" stop --project "$repo"
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

test_merge_head_accepts_first_parent_evidence() {
  local repo base first side merge tree evidence branch
  repo="$(make_repo)"
  branch="$(git -C "$repo" branch --show-current)"
  base="$(head_sha "$repo")"

  git -C "$repo" commit --allow-empty -q -m "local verified parent"
  first="$(head_sha "$repo")"

  git -C "$repo" checkout -q -b side "$base"
  git -C "$repo" commit --allow-empty -q -m "main side parent"
  side="$(head_sha "$repo")"
  git -C "$repo" checkout -q "$branch"

  evidence="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$evidence" <<EOF
Command: local verify
Command: pytest tests/test_app.py && ruff check src/app.py
Result: PASS pytest and ruff
Commit: $first
Senior Engineer PASS
Review-scope: full-code-path
Diff-only: false
Claude Code plugin
codex:rescue
codex:codex-rescue
AGENTS.md
Verbatim output preserved
EOF
  cat > "$repo/WORKPLAN.md" <<EOF
- [x] TASK-001: Merge-parent evidence task
  - type: code
  - required: true
  - scope: src/app.py
  - source_of_truth: negative test
  - success_criteria: merge pre-push accepts first-parent evidence
  - verification: python3 ralph-loop-validate.py stop
  - evidence: .checkpoints/TASK-001/evidence.md
  - result: verified on first parent before merge
  - commit: $first
  - status: done
EOF
  printf '# Handoff\n' > "$repo/HANDOFF.md"
  printf '%s\n' "$repo/WORKPLAN.md" > "$repo/.claude/active-tracker"
  git -C "$repo" add WORKPLAN.md HANDOFF.md .claude/active-tracker .checkpoints/TASK-001/evidence.md
  tree="$(git -C "$repo" write-tree)"
  merge="$(printf 'merge commit\n' | git -C "$repo" commit-tree "$tree" -p "$first" -p "$side")"
  git -C "$repo" reset -q --hard "$merge"

  expect_allow "merge HEAD accepts first-parent evidence" python3 "$VALIDATOR" stop --project "$repo"
}

test_metadata_head_accepts_first_parent_evidence() {
  local repo first evidence
  repo="$(make_repo)"
  git -C "$repo" commit --allow-empty -q -m "verified code parent"
  first="$(head_sha "$repo")"

  evidence="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$evidence" <<EOF
Command: local verify
Command: pytest tests/test_app.py && ruff check src/app.py
Result: PASS pytest and ruff
Commit: $first
Senior Engineer PASS
Review-scope: full-code-path
Diff-only: false
Claude Code plugin
codex:rescue
codex:codex-rescue
AGENTS.md
Verbatim output preserved
EOF
  cat > "$repo/WORKPLAN.md" <<EOF
- [x] TASK-001: Metadata-parent evidence task
  - type: code
  - required: true
  - scope: src/app.py
  - source_of_truth: negative test
  - success_criteria: metadata-only evidence commit accepts first-parent evidence
  - verification: python3 ralph-loop-validate.py stop
  - evidence: .checkpoints/TASK-001/evidence.md
  - result: verified on first parent before metadata commit
  - commit: $first
  - status: done
EOF
  printf '# Handoff\n' > "$repo/HANDOFF.md"
  printf '%s\n' "$repo/WORKPLAN.md" > "$repo/.claude/active-tracker"
  git -C "$repo" add WORKPLAN.md HANDOFF.md .claude/active-tracker .checkpoints/TASK-001/evidence.md
  git -C "$repo" commit -q -m "record evidence for verified parent"

  expect_allow "metadata HEAD accepts first-parent evidence" python3 "$VALIDATOR" stop --project "$repo"
}

test_code_head_rejects_first_parent_evidence() {
  local repo first evidence
  repo="$(make_repo)"
  git -C "$repo" commit --allow-empty -q -m "verified code parent"
  first="$(head_sha "$repo")"

  evidence="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$evidence" <<EOF
Command: local verify
Command: pytest tests/test_app.py && ruff check src/app.py
Result: PASS pytest and ruff
Commit: $first
Senior Engineer PASS
Review-scope: full-code-path
Diff-only: false
Claude Code plugin
codex:rescue
codex:codex-rescue
AGENTS.md
Verbatim output preserved
EOF
  cat > "$repo/WORKPLAN.md" <<EOF
- [x] TASK-001: Code-parent evidence task
  - type: code
  - required: true
  - scope: src/app.py
  - source_of_truth: negative test
  - success_criteria: code commit cannot inherit stale first-parent evidence
  - verification: python3 ralph-loop-validate.py stop
  - evidence: .checkpoints/TASK-001/evidence.md
  - result: verified on first parent before code change
  - commit: $first
  - status: done
EOF
  printf '# Handoff\n' > "$repo/HANDOFF.md"
  printf '%s\n' "$repo/WORKPLAN.md" > "$repo/.claude/active-tracker"
  git -C "$repo" add WORKPLAN.md HANDOFF.md .claude/active-tracker .checkpoints/TASK-001/evidence.md
  git -C "$repo" commit -q -m "record evidence for verified parent"
  printf 'print("changed after evidence")\n' > "$repo/src/app.py"
  git -C "$repo" add src/app.py
  git -C "$repo" commit -q -m "change code after evidence"

  expect_block "code HEAD rejects first-parent evidence" python3 "$VALIDATOR" stop --project "$repo"
}

test_unrelated_code_change_does_not_stale_closed_task_evidence() {
  local repo first evidence
  repo="$(make_repo)"
  mkdir -p "$repo/docs"
  printf 'hook audit\n' > "$repo/docs/hook-audit.md"
  git -C "$repo" add docs/hook-audit.md
  git -C "$repo" commit -q -m "verified docs task"
  first="$(head_sha "$repo")"

  evidence="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$evidence" <<EOF
Command: local verify
Command: rg TASK docs/hook-audit.md
Result: PASS docs hook audit
Commit: $first
Senior Engineer PASS
Review-scope: full-code-path
Diff-only: false
Claude Code plugin
codex:rescue
codex:codex-rescue
AGENTS.md
Verbatim output preserved
EOF
  cat > "$repo/WORKPLAN.md" <<EOF
- [x] TASK-001: Docs scoped task
  - type: docs
  - required: true
  - scope: docs/hook-audit.md
  - source_of_truth: negative test
  - success_criteria: unrelated later code changes do not stale this evidence
  - verification: python3 ralph-loop-validate.py stop
  - evidence: .checkpoints/TASK-001/evidence.md
  - result: verified docs task before unrelated code change
  - commit: $first
  - status: done
EOF
  printf '# Handoff\n' > "$repo/HANDOFF.md"
  printf '%s\n' "$repo/WORKPLAN.md" > "$repo/.claude/active-tracker"
  git -C "$repo" add WORKPLAN.md HANDOFF.md .claude/active-tracker .checkpoints/TASK-001/evidence.md
  git -C "$repo" commit -q -m "record docs evidence"
  printf 'print("unrelated code")\n' > "$repo/src/app.py"
  git -C "$repo" add src/app.py
  git -C "$repo" commit -q -m "change unrelated code"

  expect_allow "unrelated code change does not stale closed task evidence" python3 "$VALIDATOR" stop --project "$repo"
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

test_override_without_approval_ref_blocks() {
  local repo home tracker
  repo="$(make_repo)"
  home="$repo/home"
  tracker="$repo/.claude/sprints/current.md"
  mkdir -p "$home/.claude" "$repo/.claude/sprints" "$repo/.checkpoints/foo"
  printf '%s\n' '- [ ] foo task evidence: .checkpoints/foo/evidence.md' > "$tracker"
  printf '%s\n' ".claude/sprints/current.md" > "$repo/.claude/active-tracker"
  expect_block "OVERRIDE without approval ref" env HOME="$home" bash -c "cd '$repo' && printf '%s' '{\"prompt\":\"OVERRIDE: skip task foo\"}' | bash '$HOOK02'"
}

test_override_with_approval_ref_allows() {
  local repo home tracker prompt hash
  repo="$(make_repo)"
  home="$repo/home"
  tracker="$repo/.claude/sprints/current.md"
  prompt="OVERRIDE: skip task foo"
  hash="$(printf '%s' "$prompt" | shasum -a 256 | awk '{print $1}')"
  mkdir -p "$home/.claude" "$repo/.claude/sprints" "$repo/.checkpoints/foo"
  printf '%s\n' "$hash" > "$home/.claude/approval-refs.allow"
  printf '%s\n' '- [ ] foo task evidence: .checkpoints/foo/evidence.md' > "$tracker"
  printf '%s\n' ".claude/sprints/current.md" > "$repo/.claude/active-tracker"
  expect_allow "OVERRIDE with approval ref" env HOME="$home" bash -c "cd '$repo' && printf '%s' '{\"prompt\":\"OVERRIDE: skip task foo\"}' | bash '$HOOK02'"
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

test_approval_refs_bash_write_blocks() {
  local repo payload
  repo="$(make_repo)"
  mkdir -p "$repo/home/.claude"
  payload="{\"tool_input\":{\"command\":\"printf deadbeef >> $repo/home/.claude/approval-refs.allow\"}}"
  expect_block "Bash write to approval refs" bash -c "printf '%s' '$payload' | bash '$GUARD'"
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

test_main_push_without_pr_blocks() {
  local payload
  payload='{"tool_input":{"command":"git push origin main"}}'
  expect_block "direct main push without PR blocks" bash -c "printf '%s' '$payload' | bash '$SAFETY_GUARD'"
}

test_no_verify_blocks() {
  local payload
  payload='{"tool_input":{"command":"git commit --no-verify -m bypass"}}'
  expect_block "git no-verify blocks" bash -c "printf '%s' '$payload' | bash '$SAFETY_GUARD'"
}

test_feature_push_allows() {
  local payload
  payload='{"tool_input":{"command":"git push origin feature/hook-layering"}}'
  expect_allow "feature branch push allows" bash -c "printf '%s' '$payload' | bash '$SAFETY_GUARD'"
}

write_scoped_task() {
  local task="$1" scope="$2" status="${3:-in_progress}" result="${4:-pending}" commit="${5:-pending}"
  cat <<EOF
- [ ] $task: Scoped task
  - type: code
  - required: true
  - scope: $scope
  - source_of_truth: negative test
  - success_criteria: staged files map to task scope
  - verification: local precommit validation
  - evidence: .checkpoints/$task/evidence.md
  - result: $result
  - commit: $commit
  - status: $status
EOF
}

test_precommit_selects_matching_later_active_task() {
  local repo tracker
  repo="$(make_repo)"
  mkdir -p "$repo/.claude" "$repo/.checkpoints/TASK-OLD" "$repo/.checkpoints/TASK-NEW"
  printf 'print("old")\n' > "$repo/src/old.py"
  printf 'print("new")\n' > "$repo/src/new.py"
  tracker="$repo/.claude/tracker.md"
  {
    write_scoped_task TASK-OLD src/old.py in_progress
    write_scoped_task TASK-NEW src/new.py in_progress
  } > "$tracker"
  printf '%s\n' "$tracker" > "$repo/.claude/active-tracker"
  git -C "$repo" add src/new.py
  touch "$repo/WORKPLAN.md" "$repo/HANDOFF.md"
  expect_allow "precommit selects matching later active task" python3 "$VALIDATOR" precommit --project "$repo"
}

test_precommit_blocks_ambiguous_active_scope_match() {
  local repo tracker
  repo="$(make_repo)"
  mkdir -p "$repo/.claude" "$repo/.checkpoints/TASK-A" "$repo/.checkpoints/TASK-B"
  printf 'print("shared")\n' > "$repo/src/shared.py"
  tracker="$repo/.claude/tracker.md"
  {
    write_scoped_task TASK-A src/shared.py in_progress
    write_scoped_task TASK-B src/shared.py in_progress
  } > "$tracker"
  printf '%s\n' "$tracker" > "$repo/.claude/active-tracker"
  git -C "$repo" add src/shared.py
  touch "$repo/WORKPLAN.md" "$repo/HANDOFF.md"
  expect_block "precommit blocks ambiguous active scope match" python3 "$VALIDATOR" precommit --project "$repo"
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
Codex review full-code-path
Codex-tool: Claude Code plugin + codex:rescue
Codex-subagent: codex:codex-rescue
AGENTS.md: read
Verbatim: preserved
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

test_merge_without_codex_evidence_blocks() {
  local repo fakebin local_sha ev
  repo="$(make_repo)"
  local_sha="$(head_sha "$repo")"
  mkdir -p "$repo/.checkpoints/TASK-001" "$repo/.claude"
  ev="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$ev" <<EOF
Verdict: PASS
Command: senior review
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
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/gh"
  expect_block "merge without Codex evidence" env PATH="$fakebin:$PATH" bash -c "cd '$repo' && printf '%s' '{\"tool_input\":{\"command\":\"gh pr merge 1\"}}' | bash '$MERGE_GATE'"
}

test_pending_human_review_allowed_with_codex() {
  local repo fakebin local_sha ev
  repo="$(make_repo)"
  local_sha="$(head_sha "$repo")"
  mkdir -p "$repo/.checkpoints/TASK-001" "$repo/.claude"
  ev="$repo/.checkpoints/TASK-001/evidence.md"
  cat > "$ev" <<EOF
Verdict: PASS
Command: codex review
Result: PASS
Commit: $local_sha
Review-scope: full-code-path
Diff-only: false
Codex review full-code-path
Codex-tool: Claude Code plugin + codex:rescue
Codex-subagent: codex:codex-rescue
AGENTS.md: read
Verbatim: preserved
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
  *"reviewDecision,reviewRequests"*) printf '{"reviewDecision":"CHANGES_REQUESTED","reviewRequests":[{"login":"business-owner"}]}\n'; exit 0 ;;
  *"statusCheckRollup"*) printf '{"statusCheckRollup":[{"name":"CodeQL","conclusion":"SUCCESS"}]}\n'; exit 0 ;;
  *"headRefOid"*) printf '%s\n' "$local_sha"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/gh"
  expect_allow "pending GitHub human review allowed with Codex evidence" env PATH="$fakebin:$PATH" bash -c "cd '$repo' && printf '%s' '{\"tool_input\":{\"command\":\"gh pr merge 1\"}}' | bash '$MERGE_GATE'"
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
test_done_with_zero_required_tracker
test_codex_not_rescue
test_review_old_sha
test_merge_head_accepts_first_parent_evidence
test_metadata_head_accepts_first_parent_evidence
test_code_head_rejects_first_parent_evidence
test_unrelated_code_change_does_not_stale_closed_task_evidence
test_skip_reason_direct_bash
test_skip_reason_write_tool
test_override_without_approval_ref_blocks
test_override_with_approval_ref_allows
test_handoff_attempt_history_deletion
test_touch_workplan_freshness_forgery
test_approval_refs_bash_write_blocks
test_source_edit_without_active_plan
test_behavior_code_without_prefix_test
test_failed_verification_without_fresh_attempt
test_failed_verification_duplicate_latest_hypothesis
test_failed_verification_without_workplan_update
test_session_start_invalid_tracker_contract
test_secret_write_blocks
test_destructive_rm_without_approval
test_main_push_without_pr_blocks
test_no_verify_blocks
test_feature_push_allows
test_precommit_selects_matching_later_active_task
test_precommit_blocks_ambiguous_active_scope_match
test_pr_head_mismatch_blocks_merge
test_merge_without_codex_evidence_blocks
test_pending_human_review_allowed_with_codex
test_prefix_helper_rejects_passing_test

note "negative tests passed: $pass"
if [ "$fail" -ne 0 ]; then
  note "negative tests failed: $fail"
  exit 1
fi
