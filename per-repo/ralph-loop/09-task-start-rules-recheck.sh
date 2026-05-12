#!/usr/bin/env bash
# Ralph-Loop hook 09 - UserPromptSubmit (task-start rule re-load).
# Closes audit gap #1: per-task hooks did not enforce re-reading global +
# project rules + active-task spec at task-start. Hook 01 only ran at
# SessionStart.
#
# Triggers when prompt contains literal `START TASK <slug>` (or
# `RESUME TASK <slug>`). Refuses (exit 2) if `.checkpoints/<slug>/task-spec.md`
# does not exist + has all 6 required sections (Goal/Files/AC/Dependencies/
# Negative scenarios/Plan-vs-code reconciliation).
#
# On success: injects FULL global rules + project rules + AGENTS.md (if exists)
# + task-spec.md as additionalContext (no truncation - this is the one
# place where full re-read is enforced).

set -euo pipefail

active_pointer="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")
[ -f "$tracker" ] || exit 0
repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
validator="${RALPH_GLOBAL_HOOKS_DIR:-$HOME/.claude/hooks}/ralph-loop-validate.py"
if [ ! -x "$validator" ]; then
    echo "::error::ralph-loop-09: missing Ralph Loop validator at '$validator'." >&2
    echo "Install global hooks from /Users/antonsahovskii/Dev/Hooks/global before START TASK can pass." >&2
    exit 2
fi
python3 "$validator" validate-file --project "$repo" --file "$tracker"

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null || true)

# Match literal task-start markers (case-insensitive).
slug=$(printf '%s' "$prompt" | grep -ioE '^(START|RESUME)[[:space:]]+TASK[[:space:]]+[a-z0-9-]+' | head -1 | awk '{print tolower($NF)}' || true)
[ -n "$slug" ] || exit 0

spec="$repo/.checkpoints/$slug/task-spec.md"

if [ ! -f "$spec" ]; then
    cat >&2 <<EOF
::error::ralph-loop-09: task-spec missing for slug '$slug'.
Expected: $spec

Run plan-mode + ExitPlanMode to auto-generate via hook 08, OR copy from
~/.claude/templates/task-spec.md and fill all 6 sections (Goal/Files/AC/
Dependencies/Negative scenarios/Plan-vs-code reconciliation).
EOF
    exit 2
fi

# Validate all 6 required sections exist.
required_sections=("## Goal" "## Files" "## AC" "## Dependencies" "## Negative scenarios" "## Plan-vs-code reconciliation")
missing=()
for section in "${required_sections[@]}"; do
    if ! grep -qF "$section" "$spec"; then
        missing+=("$section")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    cat >&2 <<EOF
::error::ralph-loop-09: task-spec '$spec' missing required sections:
$(printf '  - %s\n' "${missing[@]}")

Fill them before re-issuing 'START TASK $slug'.
EOF
    exit 2
fi

# Full re-load of rules + spec as additionalContext (stdout).
cat <<EOF
[ralph-loop-09] task-start re-read for slug '$slug'.

=== GLOBAL RULES (~/.claude/CLAUDE.md, full) ===
$(cat "$HOME/.claude/CLAUDE.md" 2>/dev/null || echo '(missing)')

=== PROJECT RULES ($repo/CLAUDE.md, full) ===
$(cat "$repo/CLAUDE.md" 2>/dev/null || echo '(missing)')

=== PROJECT AGENTS ($repo/AGENTS.md, if exists) ===
$(cat "$repo/AGENTS.md" 2>/dev/null || echo '(no AGENTS.md)')

=== TASK SPEC ($spec) ===
$(cat "$spec")

DISCIPLINE: read all sections above. Apply Pre-step protocol from glistening-skipping-adleman.md before first edit.
EOF

exit 0
