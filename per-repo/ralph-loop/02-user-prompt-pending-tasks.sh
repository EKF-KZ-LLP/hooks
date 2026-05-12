#!/usr/bin/env bash
# Ralph-Loop hook 02 - UserPromptSubmit.
# Injects pending-tasks list as additionalContext so the agent always
# sees what is left. Also handles the `OVERRIDE: skip task <slug>`
# escape: writes skip-reason.md + flips checkbox to `[x] [SKIP]` for
# the named slug.

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0
active_pointer="$repo/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")
[ -f "$tracker" ] || exit 0

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null || true)

repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# OVERRIDE escape: only matches lines exactly starting with the marker.
# Hardened 2026-05-12 — agent self-SKIP cheat vector closed by adding
# tamper-proof author markers and chmod 444 on skip-reason.md. Hook 03
# now refuses SKIP flip unless skip-reason.md was authored by THIS hook
# (verified via Author + Override-prompt-hash + chmod 444).
override=$(printf '%s' "$prompt" | grep -m1 -oE '^OVERRIDE: skip task [a-z0-9-]+' || true)
if [ -n "$override" ]; then
    slug=$(echo "$override" | awk '{print $4}')
    skip_dir="$repo/.checkpoints/$slug"
    mkdir -p "$skip_dir"
    skip_file="$skip_dir/skip-reason.md"
    # Refuse to re-author skip-reason if it already exists. Single-shot
    # prevents agent overwriting a stale skip with a fresh one to bypass
    # the timestamp check below.
    if [ ! -f "$skip_file" ]; then
        prompt_hash=$(printf '%s' "$prompt" | shasum -a 256 | awk '{print $1}')
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        # Make writable in case a previous chmod 444 attempt landed.
        rm -f "$skip_file"
        cat > "$skip_file" <<EOF
Slug: $slug
Author: user-override-hook02
Override-timestamp: $ts
Override-prompt-hash: $prompt_hash
Override-prompt-excerpt: $(printf '%s' "$prompt" | head -c 200)
Reason: user override via prompt
EOF
        # chmod 444 — agent cannot rewrite or post-hoc tamper.
        chmod 444 "$skip_file"
        # Append to audit log so OVERRIDE flow is auditable.
        audit_log="$HOME/.claude/audit.log"
        mkdir -p "$(dirname "$audit_log")"
        echo "$ts SKIP slug=$slug hash=$prompt_hash repo=$repo" >> "$audit_log"
    fi
    # Flip the checkbox for that slug to [x] [SKIP].
    if grep -q "evidence: \\.checkpoints/$slug/" "$tracker"; then
        # Use python for in-place edit; bash sed -i differs across BSD/GNU.
        python3 - "$tracker" "$slug" <<'PYEOF'
import sys, re
path, slug = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
new = re.sub(
    rf'^- \[ \](.*evidence:\s*\.checkpoints/{re.escape(slug)}/.*)$',
    rf'- [x] [SKIP]\1',
    text,
    flags=re.MULTILINE,
)
if new != text:
    with open(path, 'w') as f:
        f.write(new)
PYEOF
    fi
fi

open_tasks=$(grep -nE "^- \[ \]" "$tracker" 2>/dev/null || true)
open_count=$(printf '%s' "$open_tasks" | grep -c . 2>/dev/null || echo 0)

if [ "$open_count" -eq 0 ]; then
    cat <<EOF
[ralph-loop] all tracker tasks closed. New work goes through plan-edit
flow only - do NOT start free-form coding without adding a checkbox first.
EOF
    exit 0
fi

cat <<EOF
[ralph-loop] PENDING TASKS: $open_count remaining.

First open task:
$(printf '%s' "$open_tasks" | head -1)

Full open list:
$(printf '%s' "$open_tasks")

Tracker: $tracker

Discipline: do NOT declare victory while any [ ] remain. Use
\`OVERRIDE: skip task <slug>\` ONLY when explicitly authorised.
EOF

exit 0
