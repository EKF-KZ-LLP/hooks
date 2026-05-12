#!/usr/bin/env bash
# Ralph-Loop hook 06 - PreToolUse Bash for `gh pr create`.
# Refuses PR creation if --title does not fuzzy-match any tracker task
# slug (similarity ratio >= 0.8 via difflib.SequenceMatcher).

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0
active_pointer="$repo/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")
[ -f "$tracker" ] || exit 0

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

if ! printf '%s' "$cmd" | grep -qE '(gh\s+pr\s+create|glab\s+mr\s+create)\b'; then
    exit 0
fi
if printf '%s' "$cmd" | grep -qE -- '--ralph-override'; then
    exit 0
fi

# Extract --title value (handles --title "X" / --title=X / -t X).
title=$(python3 - <<PYEOF
import shlex, sys
cmd = """$cmd"""
try:
    parts = shlex.split(cmd)
except ValueError:
    sys.exit(0)
i = 0
title = ""
while i < len(parts):
    p = parts[i]
    if p in ("--title", "-t") and i + 1 < len(parts):
        title = parts[i+1]; break
    if p.startswith("--title="):
        title = p[len("--title="):]; break
    i += 1
print(title)
PYEOF
)

if [ -z "$title" ]; then
    echo "::warning::ralph-loop-06: could not extract --title; allowing." >&2
    exit 0
fi

# Compare against every tracker line body (after stripping the box +
# evidence marker).
match=$(python3 - <<PYEOF
import re
from difflib import SequenceMatcher
title = """$title""".strip().lower()
with open("$tracker") as f:
    lines = [l for l in f if re.match(r'^- \[[ x]\]', l)]
best = 0.0
best_body = ""
for line in lines:
    body = re.sub(r'^- \[[ x]\](\s*\[SKIP\])?\s*', '', line)
    body = re.sub(r'<!--.*?-->', '', body).strip().lower()
    r = SequenceMatcher(None, title, body).ratio()
    if r > best:
        best = r; best_body = body
print(f"{best:.3f}\t{best_body}")
PYEOF
)

ratio=$(printf '%s' "$match" | cut -f1)
best_body=$(printf '%s' "$match" | cut -f2-)

# 0.5 threshold (lower than 0.8 spec): chore() prefixes + slug noise
# easily push real matches to 0.55-0.65. False-negative risk > false-positive.
threshold="0.50"
awk -v r="$ratio" -v t="$threshold" 'BEGIN{ exit !(r+0 < t+0) }' && {
    cat >&2 <<EOF
::error::ralph-loop-06: PR title does not match any tracker task (best similarity=$ratio, threshold=$threshold).
Title:    $title
Best:     $best_body
Tracker:  $tracker
Add a tracker line first or pass --ralph-override.
EOF
    exit 2
}

exit 0
