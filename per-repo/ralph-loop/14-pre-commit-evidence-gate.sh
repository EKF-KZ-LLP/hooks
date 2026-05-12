#!/usr/bin/env bash
# Ralph-Loop hook 14 - PreToolUse Bash for git commit.
# Blocks commits when WORKPLAN/HANDOFF or tracker evidence are stale.

set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

if ! printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit([[:space:]]|$)'; then
    exit 0
fi

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0

validator="${RALPH_GLOBAL_HOOKS_DIR:-$HOME/.claude/hooks}/ralph-loop-validate.py"
if [ ! -x "$validator" ]; then
    echo "::error::ralph-loop-14: missing Ralph Loop validator at '$validator'." >&2
    echo "Install global hooks from /Users/antonsahovskii/Dev/Hooks/global before git commit can pass." >&2
    exit 2
fi

python3 "$validator" precommit --project "$repo"
exit 0
