#!/usr/bin/env bash
# run-codex-review.sh - the only legitimate path to producing an
# evidence file for a Ralph-Loop tracker task.
#
# Usage:
#   bash ~/.claude/hooks/run-codex-review.sh <task-slug>
#
# Effects (when Codex returns Verdict: PASS):
#   - writes <repo>/.checkpoints/<slug>/codex-review-raw.txt (raw output)
#   - writes <repo>/.checkpoints/<slug>/evidence.md (parsed)
#   - chmod 444 evidence.md
#   - sets mtime to the run-id epoch so hook 03 can verify provenance
#
# Effects on FAIL: writes raw output, exits 2, evidence.md NOT created
# (or kept as previous PASS-state). Agent must continue work and rerun.

set -euo pipefail

slug="${1:?task slug required}"
repo=$(git rev-parse --show-toplevel)
dir="$repo/.checkpoints/$slug"
mkdir -p "$dir"
raw="$dir/codex-review-raw.txt"
evidence="$dir/evidence.md"

epoch=$(date -u +%s)
run_id="codex-${epoch}-${slug}"
sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Real Codex CLI invocation. Uses `codex exec` with explicit prompt that
# requires literal `Verdict: PASS|FAIL` line in output. Falls back to
# companion script if codex binary is unavailable.
PROMPT_TEXT="Review commit ${sha} for task slug '${slug}'. Do NOT review only the diff - read full content of every file in the diff, then trace callers and verify tests cover the change end-to-end.

REQUIRED REVIEW STEPS (perform all):
1. Read full content of each file changed in the diff (not just hunks).
2. For each modified function/method, grep the repo for callers (\`grep -rn '<name>('\` or LSP find-references). List ≥3 callers (or 'no callers' if truly leaf).
3. For each modified function, locate its tests and verify they exercise the new behavior. List the test names.
4. Enumerate negative scenarios (empty input / error path / boundary value / nil/null / edge case). Confirm at least one is covered by tests.
5. Reconcile plan-vs-code: if the parent plan (~/.claude/plans/glistening-skipping-adleman.md or equivalent) says X but code does Y, surface the divergence.

Output format - file MUST contain these 5 sections in order:

## Files reviewed
- <full path>:<line range read>:<sha>
- ...

## Callers traced
- <function/method name>: <list of call sites with file:line, or 'no callers (leaf)'>
- ... (≥3 traced functions for non-trivial PR)

## Tests verified
- <test file>:<test func name>: <which behavior exercised>
- ...

## Negative scenarios checked
- <scenario name>: <test that covers it, or 'GAP — not covered'>
- ... (≥1 scenario explicitly mentioning empty/error/boundary/nil/null/edge)

## Plan-vs-code reconciliation
<one or more lines describing any plan/code divergence, or 'no divergence found'>

## Verdict block (LAST 3 LINES, exact format)
Findings: <one-line summary or 'no blocking issues'>
Subagent ID: <16-hex>
Verdict: PASS

Use 'Verdict: FAIL' if any HIGH/BLOCKING issue OR if any of sections 1-4 cannot be filled (incomplete review = FAIL, not PASS-with-gaps)."

if command -v codex >/dev/null 2>&1; then
    codex exec --skip-git-repo-check --sandbox read-only "$PROMPT_TEXT" > "$raw" 2>&1 || true
elif [ -x "$HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/codex-companion.mjs" ]; then
    node "$HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/codex-companion.mjs" \
        task --json --fresh --prompt "$PROMPT_TEXT" \
        > "$raw" 2>&1 || true
else
    echo "::error::run-codex-review.sh: no Codex binary or companion found." >&2
    exit 2
fi

verdict="UNKNOWN"
if grep -qE '"verdict"[[:space:]]*:[[:space:]]*"PASS"' "$raw" 2>/dev/null; then
    verdict="PASS"
elif grep -qiE 'Verdict:[[:space:]]*PASS([[:space:]]|$)' "$raw" 2>/dev/null; then
    verdict="PASS"
elif grep -qiE 'Verdict:[[:space:]]*(FAIL|FOUND_ISSUES|DISAGREE)' "$raw"; then
    verdict="FAIL"
fi

if [ "$verdict" != "PASS" ]; then
    cat <<EOF
::error::run-codex-review.sh: verdict for slug '$slug' is '$verdict' (not PASS).
Raw output: $raw
Fix the findings and re-run. Iteration counter increments on every push (hook 07).
EOF
    exit 2
fi

# Make any prior PASS evidence writable so we can overwrite.
[ -f "$evidence" ] && chmod 644 "$evidence"

cat > "$evidence" <<EOF
Task: $slug
SHA: $sha
Codex-run-id: $run_id
Verdict: PASS
Findings: $(grep -iE 'No blocking|no high|all clean' "$raw" | head -1 || echo "see raw")
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Set mtime to run epoch so hook 03 can compare.
touch -d "@$epoch" "$evidence" 2>/dev/null || touch -t "$(date -j -f %s "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d @"$epoch" +%Y%m%d%H%M.%S)" "$evidence"
chmod 444 "$evidence"

echo "[run-codex-review] PASS recorded for '$slug' at $evidence"
exit 0
