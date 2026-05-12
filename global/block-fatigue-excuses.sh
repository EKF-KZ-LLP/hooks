#!/usr/bin/env bash
# block-fatigue-excuses.sh - PreToolUse on Write/Edit. Blocks "tired"
# class excuses in commit messages, retrospectives, reports. LLM does
# not fatigue; using fatigue as a reason for plan-drift is a lie.

set -euo pipefail

input=$(cat)
content=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || true)
if [ -z "$content" ]; then exit 0; fi

bad_patterns=(
    "устал"
    "утомил"
    "exhausted"
    "ran out of steam"
    "limited time budget"
    "time-wise i could not"
    "не успел из-за"
    "iteration fatigue"
)

for p in "${bad_patterns[@]}"; do
    if printf '%s' "$content" | grep -qiE "$p"; then
        echo "::error::block-fatigue-excuses: pattern '$p' matched. LLM does not fatigue. Use real reasons (design failure, plan ambiguity, blocking dep) or fix the underlying issue." >&2
        exit 2
    fi
done

exit 0
