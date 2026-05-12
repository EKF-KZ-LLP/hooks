#!/usr/bin/env bash
# Ralph-Loop hook 04 - PreToolUse Bash for merge intents:
#   - `gh pr merge <N>`
#   - `glab mr merge <N>` / `glab api -X PUT /merge_requests/<N>/merge`
#
# FAIL-CLOSED policy. The default for any merge command is BLOCK.
# A merge is permitted only when ALL applicable gates below pass:
#
#   GitHub gates:
#     G9   CI required checks green (`gh pr checks --required`)
#     G10  reviewDecision = APPROVED, no pending review requests
#     G23  CodeQL check (if attached) = SUCCESS or NEUTRAL
#     G24  Stale-SHA: reviewed commit is ancestor of HEAD
#     GVerdict  At least one of: local tracker evidence with
#               `Verdict: PASS`, OR docs/superpowers/reviews/*-pr<N>-*-codex.md
#               with `Verdict: APPROVED`
#
#   GitLab gates:
#     GVerdict  Local tracker evidence with `Verdict: PASS`, OR
#               server-side `glab api .../notes` body with `Verdict: APPROVED`
#
# Bypass: `--ralph-override` (only with explicit user authorisation).
#
# Previous version exited 0 in repos without `.claude/active-tracker` -
# Codex round flagged that as fail-open and Round-2 hardens this to
# fail-closed merge protection.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Explicit emergency bypass.
if printf '%s' "$cmd" | grep -qE -- '--ralph-override'; then
    exit 0
fi

# Merge-intent detection. If nothing matches, this hook has nothing to say.
is_gh_merge=0
is_glab_merge=0
mr_num=""
provider=""

# GitHub: `gh pr merge` with optional global flags before subcommand.
# Examples caught:
#   gh pr merge 123
#   gh pr merge 123 --auto --squash
#   gh -R owner/repo pr merge 123
#   gh --repo owner/repo pr merge 123
#   gh --hostname github.com pr merge 123
if printf '%s' "$cmd" | grep -qE '\bgh\b[^|;&]*\bpr[[:space:]]+merge\b'; then
    is_gh_merge=1
    provider="github"
    mr_num=$(printf '%s' "$cmd" | grep -oE 'pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)
    [ -n "$mr_num" ] || mr_num=$(gh pr view --json number --jq .number 2>/dev/null || true)
fi

# GitHub: `gh api` direct merge endpoint:
#   gh api -X PUT /repos/<owner>/<repo>/pulls/<N>/merge
#   gh api --method PUT /repos/<owner>/<repo>/pulls/<N>/merge
#   gh api /repos/o/r/pulls/N/merge -X PUT
if printf '%s' "$cmd" | grep -qE '\bgh\b[^|;&]*\bapi\b' \
   && printf '%s' "$cmd" | grep -qE -- '-X[[:space:]]*PUT|--method[[:space:]]+PUT' \
   && printf '%s' "$cmd" | grep -qE '/pulls/[0-9]+/merge\b'; then
    is_gh_merge=1
    provider="github"
    mr_num=$(printf '%s' "$cmd" | grep -oE '/pulls/[0-9]+/merge' | grep -oE '[0-9]+' || true)
fi

# GitLab: `glab api -X PUT .../merge_requests/<N>/merge` with optional global flags.
if printf '%s' "$cmd" | grep -qE '\bglab\b[^|;&]*\bapi\b' \
   && printf '%s' "$cmd" | grep -qE -- '-X[[:space:]]*PUT|--method[[:space:]]+PUT' \
   && printf '%s' "$cmd" | grep -qE '/merge_requests/[0-9]+/merge\b'; then
    is_glab_merge=1
    provider="gitlab"
    mr_num=$(printf '%s' "$cmd" | grep -oE '/merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' || true)
fi

# GitLab: `glab mr merge` with optional global flags before subcommand.
if printf '%s' "$cmd" | grep -qE '\bglab\b[^|;&]*\bmr[[:space:]]+merge\b'; then
    is_glab_merge=1
    provider="gitlab"
    mr_num=$(printf '%s' "$cmd" | grep -oE 'mr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)
    [ -n "$mr_num" ] || mr_num=$(glab mr view --output=json 2>/dev/null | jq -r '.iid // empty' || true)
fi

# No merge intent. Hook is silent.
if [ "$is_gh_merge" -eq 0 ] && [ "$is_glab_merge" -eq 0 ]; then
    exit 0
fi

# From here on: merge intent confirmed. Default = BLOCK.

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$repo" ]; then
    echo "::error::ralph-loop-04: merge command outside any git repo. BLOCKED." >&2
    exit 2
fi

if [ -z "$mr_num" ]; then
    echo "::error::ralph-loop-04: $provider merge requested but PR/MR number could not be resolved." >&2
    echo "Resolve: pass an explicit PR number (gh pr merge <N>) or use --ralph-override." >&2
    exit 2
fi

# -----------------------------------------------------------
# Codex/Senior verdict check (tracker + project review + server)
# -----------------------------------------------------------
local_pass=0
project_pass=0
server_pass=0
current_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)

review_evidence_ok() {
    f="$1"
    [ -f "$f" ] || return 1
    grep -qE '^Verdict:[[:space:]]+(PASS|APPROVED)\b' "$f" || return 1
    grep -qE '^(Command|Verify command|Verify|Test command|How verified):' "$f" || return 1
    grep -qE '^(Result|Outcome|Logs|Output):' "$f" || return 1
    grep -qE '^(Commit|SHA|Fix commit):' "$f" || return 1
    if grep -qiE 'codex' "$f"; then
        grep -qiE 'Claude Code plugin' "$f" || return 1
        grep -qiE 'codex:rescue' "$f" || return 1
        grep -qiE 'codex:codex-rescue' "$f" || return 1
    fi
    if grep -qiE 'review|codex|senior' "$f"; then
        grep -qiE 'full-code-path' "$f" || return 1
        if grep -qiE 'diff-only' "$f" && ! grep -qiE 'diff-only:[[:space:]]*false' "$f"; then
            return 1
        fi
    fi
    if [ -n "$current_sha" ] && ! grep -q "$current_sha" "$f"; then
        return 1
    fi
    return 0
}

active_pointer="$repo/.claude/active-tracker"
if [ -f "$active_pointer" ]; then
    tracker=$(<"$active_pointer")
    if [ -f "$tracker" ]; then
        line=$(grep -nE "^- \[[ x]\].*(MR|PR)[ -]?#?$mr_num\b.*pr-${mr_num}-merged" "$tracker" 2>/dev/null | head -1 || true)
        [ -n "$line" ] || line=$(grep -nE "^- \[[ x]\].*(MR|PR)[ -]?#?$mr_num\b" "$tracker" 2>/dev/null | head -1 || true)
        [ -n "$line" ] || line=$(grep -nE "^- \[[ x]\].*(mr|pr)-$mr_num\b" "$tracker" 2>/dev/null | head -1 || true)
        if [ -n "$line" ]; then
            evidence_rel=$(printf '%s' "$line" | grep -oE 'evidence:[[:space:]]*[^ ]+' | sed -E 's/^evidence:[[:space:]]*//' | head -1 || true)
            if [ -n "$evidence_rel" ]; then
                evidence_abs="$repo/$evidence_rel"
                if review_evidence_ok "$evidence_abs"; then
                    local_pass=1
                fi
            fi
        fi
    fi
fi

if [ -d "$repo/docs/superpowers/reviews" ]; then
    for f in "$repo"/docs/superpowers/reviews/*-pr"$mr_num"-*-codex.md "$repo"/docs/superpowers/reviews/*-mr"$mr_num"-*-codex.md; do
        [ -f "$f" ] || continue
        if review_evidence_ok "$f"; then
            project_pass=1
            break
        fi
    done
fi

if [ "$is_glab_merge" -eq 1 ] && command -v glab >/dev/null 2>&1; then
    notes=$(glab api "projects/$(glab repo view --output=json 2>/dev/null | jq -r '.path_with_namespace // empty' | sed 's|/|%2F|')/merge_requests/$mr_num/notes" 2>/dev/null || echo "[]")
    if printf '%s' "$notes" | jq -r '.[].body // empty' 2>/dev/null | grep -qE '^Verdict:[[:space:]]*APPROVED\b'; then
        server_pass=1
    fi
fi

if [ "$local_pass" -ne 1 ] && [ "$server_pass" -ne 1 ] && [ "$project_pass" -ne 1 ]; then
    cat >&2 <<EOF
::error::ralph-loop-04: $provider PR/MR #$mr_num merge BLOCKED - no Codex/Senior verdict evidence.
Acceptable evidence (any one):
  - tracker line referencing pr-${mr_num}-merged with evidence:<path>.md containing 'Verdict: PASS'
  - docs/superpowers/reviews/*-pr${mr_num}-*-codex.md with 'Verdict: APPROVED'
  - (GitLab only) MR note body with 'Verdict: APPROVED' from Codex
Bypass: --ralph-override (with explicit user authorisation).
EOF
    exit 2
fi

# -----------------------------------------------------------
# GitHub extra gates (G9 / G10 / G23 / G24). MANDATORY for gh merges.
# -----------------------------------------------------------
if [ "$is_gh_merge" -eq 1 ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "::error::ralph-loop-04: gh CLI required for PR merge gate but not installed." >&2
        exit 2
    fi

    # G9: CI required checks
    if ! gh pr checks "$mr_num" --required >/tmp/ralph-04-ci.out 2>/tmp/ralph-04-ci.err; then
        echo "::error::ralph-loop-04: PR #$mr_num CI required checks NOT green (G9)." >&2
        head -20 /tmp/ralph-04-ci.out >&2 2>/dev/null
        exit 2
    fi

    # G10: review approval
    review_json=$(gh pr view "$mr_num" --json reviewDecision,reviewRequests 2>/dev/null || echo '{}')
    review_decision=$(printf '%s' "$review_json" | jq -r '.reviewDecision // ""' 2>/dev/null || true)
    pending_reviewers=$(printf '%s' "$review_json" | jq -r '.reviewRequests | length' 2>/dev/null || echo 0)
    if [ "$review_decision" != "APPROVED" ]; then
        echo "::error::ralph-loop-04: PR #$mr_num reviewDecision='$review_decision' (need APPROVED) (G10)." >&2
        exit 2
    fi
    if [ "${pending_reviewers:-0}" -gt 0 ]; then
        echo "::error::ralph-loop-04: PR #$mr_num has $pending_reviewers pending review request(s) (G10)." >&2
        exit 2
    fi

    # G23: CodeQL state
    rollup_json=$(gh pr view "$mr_num" --json statusCheckRollup 2>/dev/null || echo '{}')
    codeql_state=$(printf '%s' "$rollup_json" \
        | jq -r '.statusCheckRollup[]? | select((.name // .context // "") | test("[Cc]ode[Qq][Ll]")) | (.conclusion // .state // "")' \
        2>/dev/null | head -1 || true)
    if [ -n "$codeql_state" ] && [ "$codeql_state" != "SUCCESS" ] && [ "$codeql_state" != "NEUTRAL" ]; then
        echo "::error::ralph-loop-04: PR #$mr_num CodeQL state='$codeql_state' (need SUCCESS/NEUTRAL) (G23)." >&2
        exit 2
    fi

    # G24: stale-SHA
    head_sha=$(gh pr view "$mr_num" --json headRefOid --jq .headRefOid 2>/dev/null || true)
    if [ -n "$head_sha" ]; then
        ev_dir="$repo/.claude/evidence/PR-$mr_num"
        stale_files=""
        if [ -d "$ev_dir" ]; then
            for f in "$ev_dir"/*.md; do
                [ -f "$f" ] || continue
                reviewed_sha=$(grep -oiE '(reviewed|reviewed commit|commit|head)[[:space:]]*:[[:space:]]*[0-9a-f]{40}' "$f" \
                    | head -1 | grep -oE '[0-9a-f]{40}' || true)
                [ -n "$reviewed_sha" ] || continue
                if [ "$reviewed_sha" != "$head_sha" ]; then
                    if ! git merge-base --is-ancestor "$reviewed_sha" "$head_sha" 2>/dev/null; then
                        stale_files="$stale_files\n  - $f reviewed=$reviewed_sha vs HEAD=$head_sha"
                    fi
                fi
            done
        fi
        if [ -n "$stale_files" ]; then
            echo "::error::ralph-loop-04: PR #$mr_num STALE review evidence (G24):" >&2
            printf '%b\n' "$stale_files" >&2
            echo "Resolve: re-run Senior + codex:rescue review on current HEAD, update evidence files." >&2
            exit 2
        fi
    fi
fi

exit 0
