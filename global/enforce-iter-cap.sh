#!/usr/bin/env bash
# enforce-iter-cap.sh - PreToolUse hook on Bash gh-pr-merge calls.
# Counts iter commits on a PR branch. >3 iter cycles = require explicit
# user override marker in commit message. Plan rule: max 3 iter, then
# /sprint:fail or rethink design.

set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

if ! printf '%s' "$cmd" | grep -qE 'gh\s+pr\s+(merge|create)|gh\s+api\s+[^|;&]*(repos/[^/]+/[^/]+/pulls/[0-9]+/merge|--method[[:space:]]+(PUT|put))'; then
    exit 0
fi

# Block `gh pr merge --admin` outright — it bypasses required status
# checks server-side. The agent must not use admin override; if checks
# aren't green, fix them or escalate to the human operator. --admin
# is NOT a valid bypass for the iteration cap below.
# Block --admin bypass on `gh pr merge`. Also block equivalent
# bypasses: `gh api -X PUT .../merge?merge_method=...` server-side
# merge call which skips required checks; bash variable substitution
# `--$(echo admin)`; quoted/escaped admin like `"--admin"`.
ADMIN_BYPASS_RE='gh\s+pr\s+merge[^|;&]*--admin\b'
ADMIN_BYPASS_RE_ALT='gh\s+pr\s+merge[^|;&]*(\$\([^)]*admin[^)]*\)|"--admin"|'"'"'--admin'"'"')'
ADMIN_BYPASS_RE_API='gh\s+api\s+[^|;&]*(repos/[^/]+/[^/]+/pulls/[0-9]+/merge|--method[[:space:]]+(PUT|put))'

if printf '%s' "$cmd" | grep -qE "$ADMIN_BYPASS_RE"; then
    if ! printf '%s' "$cmd" | grep -qE -- '--ralph-override'; then
        echo "::error::enforce-iter-cap: 'gh pr merge --admin' bypasses required status checks. Make CI green or add --ralph-override (only with explicit user authorisation)." >&2
        exit 2
    fi
fi
if printf '%s' "$cmd" | grep -qE "$ADMIN_BYPASS_RE_ALT"; then
    if ! printf '%s' "$cmd" | grep -qE -- '--ralph-override'; then
        echo "::error::enforce-iter-cap: variable-substituted/quoted --admin on 'gh pr merge' detected (e.g. \$(echo admin), \"--admin\"). Use plain --admin only when CI must be overridden, AND add --ralph-override marker." >&2
        exit 2
    fi
fi
if printf '%s' "$cmd" | grep -qE "$ADMIN_BYPASS_RE_API"; then
    if ! printf '%s' "$cmd" | grep -qE -- '--ralph-override'; then
        echo "::error::enforce-iter-cap: 'gh api .../pulls/N/merge' (or --method PUT to that endpoint) is a server-side merge bypass equivalent to --admin. Add --ralph-override or use 'gh pr merge'." >&2
        exit 2
    fi
fi

# repo root from cwd (best-effort).
repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0

# Best-effort branch detection: look for current branch.
branch=$(git -C "$repo" branch --show-current 2>/dev/null || true)
if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    exit 0
fi

# Count "iter" / "Codex iter-N" / "review iter-N" commits.
iter_count=$(git -C "$repo" log "origin/main..$branch" --oneline 2>/dev/null \
    | grep -ciE "iter-[0-9]|review iter|SE\+Codex iter" || true)

# Allow override. `--admin` is NOT allowed as override here (handled above).
if printf '%s' "$cmd" | grep -qiE 'iter-cap-override'; then
    exit 0
fi

if [ "$iter_count" -gt 3 ]; then
    echo "::error::enforce-iter-cap: $iter_count iteration commits on branch '$branch' (>3). Plan rule: rethink design or /sprint:fail. Append --iter-cap-override to bypass intentionally." >&2
    exit 2
fi

exit 0
