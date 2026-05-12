#!/usr/bin/env bash
# Ralph-Loop hook 12 - PreToolUse Edit (deep-review at DONE).
# Closes audit gap #4: hook 03 only checked literal `Verdict: PASS` in
# evidence file. Codex evidence could be diff-only review, missing full-code
# scan, callers, contract-tests, negative scenarios.
#
# Runs BEFORE hook 03 on tracker checkbox flip. Validates evidence.md
# contains 5 required sections (## Files reviewed / ## Callers traced /
# ## Tests verified / ## Negative scenarios checked / ## Plan-vs-code
# reconciliation). Each section must be non-empty (≥1 bullet/line below
# heading).
#
# If evidence file is from current run-codex-review.sh (which knows the
# strict prompt), sections will exist. Older evidence files or hand-faked
# ones will fail.
#
# Bypass: only operator marker `~/.claude/plans/.allow-deep-review-skip-<slug>`
# (single-shot, deleted after read).

set -euo pipefail

active_pointer="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[ "$file_path" = "$tracker" ] || exit 0

new_string=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""' 2>/dev/null || true)
old_string=$(printf '%s' "$input" | jq -r '.tool_input.old_string // ""' 2>/dev/null || true)

# Only act on `[ ]` -> `[x]` flips (skip [x] [SKIP] which is OVERRIDE path).
printf '%s' "$old_string" | grep -qE '^- \[ \] ' || exit 0
printf '%s' "$new_string" | grep -qE '^- \[x\] ' || exit 0
printf '%s' "$new_string" | grep -q '\[SKIP\]' && exit 0

# Extract evidence path.
evidence_rel=$(printf '%s' "$new_string" | grep -oE 'evidence:[[:space:]]*[^ ]+' | sed -E 's/^evidence:[[:space:]]*//' | head -1)
[ -n "$evidence_rel" ] || exit 0

repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
evidence_abs="$repo/$evidence_rel"
[ -f "$evidence_abs" ] || exit 0  # let hook 03 catch missing-file later

# Extract slug from evidence_rel (.checkpoints/<slug>/evidence.md).
slug=$(printf '%s' "$evidence_rel" | sed -E 's|^\.checkpoints/||; s|/.*||')

# Bypass marker (single-shot).
bypass_marker="$HOME/.claude/plans/.allow-deep-review-skip-$slug"
if [ -f "$bypass_marker" ]; then
    rm -f "$bypass_marker"
    echo "[ralph-loop-12] BYPASS used: marker '$bypass_marker' removed (single-shot)." >&2
    exit 0
fi

required_sections=(
    "## Files reviewed"
    "## Callers traced"
    "## Tests verified"
    "## Negative scenarios checked"
    "## Plan-vs-code reconciliation"
)

missing=()
empty=()
for section in "${required_sections[@]}"; do
    if ! grep -qF "$section" "$evidence_abs"; then
        missing+=("$section")
        continue
    fi
    # Section heading exists; check non-empty body (next non-blank line is not another ## heading).
    body=$(awk -v sec="$section" '
        $0 ~ "^"sec {flag=1; next}
        /^## / {if(flag){exit}; flag=0}
        flag && NF {print; n++}
        END {if(!n) exit 1}
    ' "$evidence_abs" 2>/dev/null || echo "")
    if [ -z "$body" ]; then
        empty+=("$section")
    fi
done

if [ "${#missing[@]}" -gt 0 ] || [ "${#empty[@]}" -gt 0 ]; then
    cat >&2 <<EOF
::error::ralph-loop-12: evidence file '$evidence_abs' fails deep-review schema.

Missing sections:
$(if [ "${#missing[@]}" -gt 0 ]; then printf '  - %s\n' "${missing[@]}"; else echo "  (none)"; fi)

Empty sections (heading present, no body):
$(if [ "${#empty[@]}" -gt 0 ]; then printf '  - %s\n' "${empty[@]}"; else echo "  (none)"; fi)

Re-run run-codex-review.sh with the strict prompt that requires all 5 sections,
OR drop a bypass marker for emergencies:
  touch $bypass_marker
EOF
    exit 2
fi

# Special: ## Negative scenarios checked must mention at least one of
# empty/error/boundary/nil tokens.
neg_body=$(awk '
    /^## Negative scenarios checked/ {flag=1; next}
    /^## / {flag=0}
    flag {print}
' "$evidence_abs")
if ! printf '%s' "$neg_body" | grep -qiE '\bempty\b|\berror\b|\bboundary\b|\bnil\b|\bnull\b|\bedge\b'; then
    cat >&2 <<EOF
::error::ralph-loop-12: ## Negative scenarios checked section in '$evidence_abs' lacks any of: empty/error/boundary/nil/null/edge tokens.
Codex review skipped negative-path enumeration. Re-run review with explicit negative-scenario coverage.
EOF
    exit 2
fi

# Callers traced minimum 3.
callers_count=$(awk '
    /^## Callers traced/ {flag=1; next}
    /^## / {flag=0}
    flag && /^[[:space:]]*-/ {n++}
    END {print n+0}
' "$evidence_abs")
if [ "$callers_count" -lt 3 ]; then
    cat >&2 <<EOF
::error::ralph-loop-12: ## Callers traced lists $callers_count entries (need ≥3).
Codex did not trace enough downstream consumers. Re-run review.
EOF
    exit 2
fi

exit 0
