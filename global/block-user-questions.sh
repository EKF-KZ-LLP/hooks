#!/usr/bin/env bash
# block-user-questions.sh - PreToolUse hook on Write/Edit.
# Blocks fabricated user-question patterns; assistant must not punt
# decisions back when the plan or ADRs already specify the answer.
# User is business owner, not a code reviewer.

set -euo pipefail

input=$(cat)
content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || true)
if [ -z "$content" ]; then exit 0; fi

bad_patterns=(
    "что нужно от тебя"
    "что нужно от вас"
    "решение нужно"
    "жду решения"
    "true-up polic"
    "decision needed"
    "what should i do"
    "нужно решение"
    "подтверди и продолж"
    "Subagent review: pending"
    "Subagent review:.*pending"
    "Senior Engineer:.*pending"
    "Codex external:.*pending"
)

for p in "${bad_patterns[@]}"; do
    if printf '%s' "$content" | grep -qiE "$p"; then
        echo "::error::block-user-questions: pattern '$p' matched. The plan + ADRs specify the answer; do not fabricate user-decision questions. User is business owner, not code reviewer - SE+Codex run via subagents automatically." >&2
        exit 2
    fi
done

exit 0
