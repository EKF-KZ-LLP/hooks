#!/usr/bin/env bash
# Ralph-Loop hook 07 - PreToolUse Bash for gh pr create / push.
# Tracks per-task iteration count. >=3 forces a SKIP path (write
# skip-reason.md + flip checkbox to [x] [SKIP]). Prevents the
# "patch forever" failure mode that produced PR #94's 9-iter cycle.

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0
active_pointer="$repo/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")
[ -f "$tracker" ] || exit 0

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Trigger on push or pr-create (both signal a new iter).
if ! printf '%s' "$cmd" | grep -qE '(gh\s+pr\s+create|git\s+push)\b'; then
    exit 0
fi
if printf '%s' "$cmd" | grep -qE -- '--ralph-override|--iter-cap-override'; then
    exit 0
fi

# Resolve current branch -> slug from tracker (looks for branch name in
# tracker line; if not found, no-op).
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ -n "$branch" ] || exit 0
[ "$branch" = "main" ] && exit 0

slug=$(grep -oE 'evidence:\s*\.checkpoints/[^ ]+' "$tracker" 2>/dev/null \
    | sed -E 's|evidence:\s*\.checkpoints/||; s|/.*||' \
    | while read s; do
        if echo "$branch" | grep -qF "$s"; then echo "$s"; break; fi
      done | head -1)

if [ -z "$slug" ]; then
    exit 0
fi

repo=$(git rev-parse --show-toplevel)
counter_file="$repo/.checkpoints/$slug/iteration-count"
mkdir -p "$repo/.checkpoints/$slug"
[ -f "$counter_file" ] || echo 0 > "$counter_file"
n=$(<"$counter_file")
n=$((n + 1))
echo "$n" > "$counter_file"

if [ "$n" -gt 3 ]; then
    cat >&2 <<EOF
::error::ralph-loop-07: iteration cap reached for task '$slug' (count=$n, max=3).
Plan rule: max 3 iterations per task; on exceed write
.checkpoints/$slug/skip-reason.md with the design-failure cause and use
\`OVERRIDE: skip task $slug\` from the user prompt to flip the checkbox.

If you genuinely need iteration N>3, append --ralph-override to bypass.
EOF
    exit 2
fi

echo "[ralph-loop-07] iteration $n/3 for task '$slug'."
exit 0
