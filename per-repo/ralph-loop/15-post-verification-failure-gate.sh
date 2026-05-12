#!/usr/bin/env bash
# Ralph-Loop hook 15 - PostToolUse Bash failure gate.
# Blocks after failed verification commands until HANDOFF.md records a
# machine-readable Ralph Loop attempt with fresh evidence.

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0

validator="${RALPH_GLOBAL_HOOKS_DIR:-$HOME/.claude/hooks}/ralph-loop-validate.py"
if [ ! -x "$validator" ]; then
    echo "::error::ralph-loop-15: missing Ralph Loop validator at '$validator'." >&2
    echo "Install global hooks from /Users/antonsahovskii/Dev/Hooks/global before failed verification can pass." >&2
    exit 2
fi

python3 "$validator" posttool-failure --project "$repo"
