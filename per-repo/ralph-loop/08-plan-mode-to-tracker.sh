#!/usr/bin/env bash
# Ralph-Loop hook 08 - PostToolUse on ExitPlanMode.
# Picks up the plan file the agent wrote during plan-mode and registers
# it as the active tracker. Refuses if plan has zero checkboxes; the
# agent must rewrite the plan in `- [ ] task <!-- evidence: ... -->`
# format before exiting plan mode.

set -euo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)

# Only fires after ExitPlanMode tool succeeds.
if [ "$tool_name" != "ExitPlanMode" ]; then
    exit 0
fi

# Read the plan content that the agent passed to ExitPlanMode. This is
# the source of truth for "which plan does this ExitPlanMode refer to".
# Without it we can't safely identify the plan file - aborting is safer
# than guessing by mtime (would risk grabbing another project's plan or
# a stale leftover).
plan_content=$(printf '%s' "$input" | jq -r '.tool_input.plan // .tool_input.content // ""' 2>/dev/null || true)
if [ -z "$plan_content" ]; then
    echo "[ralph-loop-08] ExitPlanMode tool_input has no plan content; refusing to guess by mtime. Active tracker unchanged." >&2
    exit 0
fi

# Canonicalise: strip leading/trailing whitespace + collapse to compute
# a content hash that is stable across jq round-trip (which drops the
# trailing newline) and editor newline policies.
canon_hash() {
    awk 'BEGIN{first=1} { sub(/[ \t]+$/,"") } /./ { if(!first)printf "\n"; printf "%s",$0; first=0 }'
}
content_hash=$(printf '%s' "$plan_content" | canon_hash | shasum -a 256 | awk '{print $1}')

# Find the plan file that matches the ExitPlanMode payload by canonical
# content hash. Restrict the search to a 5-minute window so we never
# pick up yesterday's leftover. If multiple files match (rare
# collision), fail loud rather than picking arbitrarily.
candidates=()
while IFS= read -r p; do
    case "$(basename "$p")" in
        .active-tracker|*-summary.md) continue ;;
    esac
    p_hash=$(canon_hash < "$p" 2>/dev/null | shasum -a 256 | awk '{print $1}')
    if [ "$p_hash" = "$content_hash" ]; then
        candidates+=("$p")
    fi
done < <(find "$HOME/.claude/plans" -maxdepth 1 -type f -name "*.md" -mmin -5 2>/dev/null)

# Also search inside any per-repo plans dir (the agent could have
# written the plan straight into the project).
repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$repo" ] && [ -d "$repo/.claude/plans" ]; then
    while IFS= read -r p; do
        p_hash=$(canon_hash < "$p" 2>/dev/null | shasum -a 256 | awk '{print $1}')
        if [ "$p_hash" = "$content_hash" ]; then
            candidates+=("$p")
        fi
    done < <(find "$repo/.claude/plans" -maxdepth 1 -type f -name "*.md" -mmin -5 2>/dev/null)
fi

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "[ralph-loop-08] no plan file matches ExitPlanMode content hash $content_hash within last 5 min. Active tracker unchanged." >&2
    exit 0
fi
if [ "${#candidates[@]}" -gt 1 ]; then
    echo "::error::ralph-loop-08: ${#candidates[@]} plan files match content hash $content_hash; refusing to pick arbitrarily." >&2
    printf '  %s\n' "${candidates[@]}" >&2
    exit 2
fi
plan="${candidates[0]}"

# Refuse plans without checkboxes.
checkbox_count=$(grep -cE "^- \[[ x]\]" "$plan" 2>/dev/null || echo 0)
if [ "$checkbox_count" -eq 0 ]; then
    cat >&2 <<EOF
::error::ralph-loop-08: plan '$plan' has 0 checkboxes.
Required format per task line:
  - [ ] <task description> <!-- evidence: .checkpoints/<slug>/evidence.md -->

Plan-mode tracker integration requires every task to have an evidence
slug; otherwise the merge-gate / stop-gate hooks have nothing to
enforce. Rewrite the plan with checkboxes and re-exit plan mode.
EOF
    exit 2
fi

# Refuse plans where checkboxes lack evidence: marker.
missing_evidence=$(grep -cE "^- \[[ x]\]" "$plan" | head -1)
if grep -E "^- \[[ x]\]" "$plan" | grep -vqE 'evidence:\s*\.checkpoints/'; then
    cat >&2 <<EOF
::error::ralph-loop-08: plan '$plan' has checkbox lines without 'evidence: .checkpoints/<slug>/evidence.md' markers.
Every task line must declare its evidence slug. Example:
  - [ ] Wire feature X <!-- evidence: .checkpoints/wire-feature-x/evidence.md -->

Rewrite the plan and re-exit plan mode.
EOF
    exit 2
fi

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$repo" ]; then
    echo "[ralph-loop-08] not in a git repo; skipping per-repo tracker registration." >&2
    exit 0
fi

# Move the plan into the project so it lives under repo's git history
# instead of leaking through the shared ~/.claude/plans/ space.
mkdir -p "$repo/.claude/plans"
plan_basename=$(basename "$plan")
project_plan="$repo/.claude/plans/$plan_basename"

# If the plan is already inside the repo, just keep it; otherwise move
# it (mv preserves mtime so hook 01's grep-recent still works on
# subsequent sessions).
case "$plan" in
    "$repo"/*) project_plan="$plan" ;;
    *)
        if [ -e "$project_plan" ] && ! cmp -s "$plan" "$project_plan"; then
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            project_plan="$repo/.claude/plans/${plan_basename%.md}-$ts.md"
        fi
        mv "$plan" "$project_plan"
        ;;
esac

echo "$project_plan" > "$repo/.claude/active-tracker"

# Auto-create task-spec.md per checkbox slug. Hook 09 (task-start) refuses
# without it. We seed from ~/.claude/templates/task-spec.md so the agent
# can fill the 6 sections (Goal/Files/AC/Dependencies/Negative scenarios/
# Plan-vs-code reconciliation) before issuing `START TASK <slug>`.
template="$HOME/.claude/templates/task-spec.md"
if [ -f "$template" ]; then
    grep -oE 'evidence:\s*\.checkpoints/[^/]+' "$project_plan" \
        | sed -E 's|^evidence:\s*\.checkpoints/||' \
        | sort -u \
        | while read -r slug; do
            spec_dir="$repo/.checkpoints/$slug"
            spec_file="$spec_dir/task-spec.md"
            if [ ! -f "$spec_file" ]; then
                mkdir -p "$spec_dir"
                sed -E "s/<slug>/$slug/g" "$template" > "$spec_file"
            fi
        done
    echo "[ralph-loop-08] task-spec.md seeded for each new checkbox slug (hook 09 requires this)."
else
    echo "[ralph-loop-08] WARN: ~/.claude/templates/task-spec.md missing; hook 09 will refuse 'START TASK' until task-specs are created manually." >&2
fi

echo "[ralph-loop-08] active tracker registered (repo-scoped): $project_plan ($checkbox_count tasks)"
exit 0
