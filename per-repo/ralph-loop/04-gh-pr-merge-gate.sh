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

# Normalised views for pattern matching:
#   cmd_match: ASCII single/double quotes and backslashes stripped so quoted
#     variants of PUT (`-X "PUT"`, `--method='PUT'`, `-X \"PUT\"`) cannot
#     bypass via separators the char class does not list. Variable references
#     (`$N`, `${N}`) preserved so URL_RE can detect them as is_url_based.
#   cmd_token: additionally strips shell variable substitutions so token-name
#     bypass (`en${EMPTY}ablePullRequestAutoMerge`, `merge$VARPullRequest`)
#     collapses back to the literal identifier for regex match.
#   Original $cmd is preserved for fallback `gh pr view` / `glab mr view`.
cmd_match=$(printf '%s' "$cmd" | tr -d '"\\'\''')
cmd_token=$(printf '%s' "$cmd_match" | sed -E 's/\$\{[^}]*\}//g; s/\$[A-Za-z_][A-Za-z0-9_]*//g')

# Explicit emergency bypass.
if printf '%s' "$cmd_match" | grep -qE -- '--ralph-override'; then
    exit 0
fi

# Merge-intent detection. If nothing matches, this hook has nothing to say.
is_gh_merge=0
is_glab_merge=0
is_url_based=0
mr_num=""
provider=""

# GitHub: `gh pr merge` with optional global flags before subcommand.
# Token detection uses cmd_token (variable substitutions stripped) so
# bypasses like `g${EMPTY}h pr merge 9` collapse back to the literal.
if printf '%s' "$cmd_token" | grep -qE '\bgh\b[^|;&]*\bpr[[:space:]]+merge\b'; then
    is_gh_merge=1
    provider="github"
    mr_num=$(printf '%s' "$cmd_token" | grep -oE 'pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)
    [ -n "$mr_num" ] || mr_num=$(gh pr view --json number --jq .number 2>/dev/null || true)
fi

# GitHub: `gh api` direct merge endpoint. URL detection runs against both
# cmd_token (variables stripped - catches `/pul${X}ls/N/merge` split bypass)
# and cmd_match (preserves $N - catches /pulls/$N/merge unresolved-target).
if printf '%s' "$cmd_token" | grep -qE '\bgh\b[^|;&]*\bapi\b' \
   && printf '%s' "$cmd_token" | grep -qE -- '-X[[:space:]=]*PUT|--method[[:space:]=]*PUT' \
   && { printf '%s' "$cmd_token" | grep -qE '/pulls/[A-Za-z0-9$_{}.-]+/merge\b' \
        || printf '%s' "$cmd_match" | grep -qE '/pulls/[A-Za-z0-9$_{}.-]+/merge\b'; }; then
    is_gh_merge=1
    is_url_based=1
    provider="github"
    mr_num=$(printf '%s' "$cmd_token" | grep -oE '/pulls/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
    [ -n "$mr_num" ] || mr_num=$(printf '%s' "$cmd_match" | grep -oE '/pulls/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
fi

# GitLab: `glab api -X PUT .../merge_requests/<N>/merge`.
if printf '%s' "$cmd_token" | grep -qE '\bglab\b[^|;&]*\bapi\b' \
   && printf '%s' "$cmd_token" | grep -qE -- '-X[[:space:]=]*PUT|--method[[:space:]=]*PUT' \
   && { printf '%s' "$cmd_token" | grep -qE '/merge_requests/[A-Za-z0-9$_{}.-]+/merge\b' \
        || printf '%s' "$cmd_match" | grep -qE '/merge_requests/[A-Za-z0-9$_{}.-]+/merge\b'; }; then
    is_glab_merge=1
    is_url_based=1
    provider="gitlab"
    mr_num=$(printf '%s' "$cmd_token" | grep -oE '/merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
    [ -n "$mr_num" ] || mr_num=$(printf '%s' "$cmd_match" | grep -oE '/merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
fi

# GitLab: `glab mr merge` with optional global flags before subcommand.
if printf '%s' "$cmd_token" | grep -qE '\bglab\b[^|;&]*\bmr[[:space:]]+merge\b'; then
    is_glab_merge=1
    provider="gitlab"
    mr_num=$(printf '%s' "$cmd_token" | grep -oE 'mr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' || true)
    [ -n "$mr_num" ] || mr_num=$(glab mr view --output=json 2>/dev/null | jq -r '.iid // empty' || true)
fi

# UNIVERSAL direct-API branch: catches `curl`, `wget`, `httpie`, `python -c
# requests`, `node fetch`, raw API clients hitting the merge endpoint with
# PUT method. Anyone with an API token can otherwise bypass `gh`/`glab` CLI
# entirely.
PUT_RE='(-X|--method|--request)[[:space:]=]*PUT|-XPUT|\b(http|httpie)[[:space:]]+PUT\b|(\.|->)put[[:space:]]*\(|[Mm]ethod[[:space:]]*[:=][[:space:]]*PUT\b|[Hh]ttp[Mm]ethod\.PUT\b|\bNewRequest[[:space:]]*\([[:space:]]*PUT\b|\.request[[:space:]]*\([[:space:]]*PUT\b|\.PUT[[:space:]]*\(|::Put\.new[[:space:]]*\('
# /pulls/<X>/merge and /merge_requests/<X>/merge are unambiguous GitHub/GitLab
# merge-endpoint paths. Drop the /repos/ and /projects/ prefix requirement so
# variable injection between domain and the merge path (e.g. ${PATH_VAR}) cannot
# bypass. Identifier portion still allows shell-variable substitution.
GH_MERGE_URL_RE='/pulls/[A-Za-z0-9$_{}.-]+/merge\b'
GL_MERGE_URL_RE='/merge_requests/[A-Za-z0-9$_{}.-]+/merge\b'
# Generic catch-all for cases where the segment name itself is hidden
# behind a shell variable (e.g. `${SEG}/<N>/merge`). Combined with PUT
# method this is suspicious enough to block as unresolved-provider.
GENERIC_MERGE_URL_RE='/[A-Za-z0-9$_{}.-]+/merge\b'
# GraphQL: mergePullRequest mutation routes via /graphql endpoint, no
# REST /pulls/<N>/merge URL. Catch the mutation name directly.
GH_GRAPHQL_RE='\b(mergePullRequest|enablePullRequestAutoMerge|markPullRequestReadyForReview[[:space:]]*\([^)]*auto[Mm]erge)[[:space:]]*\('

# Universal direct-API branch. PUT_RE uses cmd_token (variable-stripped) so
# token-name bypasses like `\.p${EMPTY}ut(` cannot dodge detection. URL_RE
# uses cmd_match (variables preserved) so /pulls/$N/merge still triggers
# is_url_based path and the unresolved-target guard.
if [ "$is_url_based" -eq 0 ] && printf '%s' "$cmd_token" | grep -qE "$PUT_RE"; then
    # Try cmd_token (collapses split-token URL like /pul${X}ls/N/merge to
    # canonical form), then fall back to cmd_match for variable-PR cases.
    if printf '%s' "$cmd_token" | grep -qE "$GL_MERGE_URL_RE" \
       || printf '%s' "$cmd_match" | grep -qE "$GL_MERGE_URL_RE"; then
        is_glab_merge=1
        is_url_based=1
        provider="gitlab"
        mr_num=$(printf '%s' "$cmd_token" | grep -oE '/merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
        [ -n "$mr_num" ] || mr_num=$(printf '%s' "$cmd_match" | grep -oE '/merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
    elif printf '%s' "$cmd_token" | grep -qE "$GH_MERGE_URL_RE" \
         || printf '%s' "$cmd_match" | grep -qE "$GH_MERGE_URL_RE"; then
        is_gh_merge=1
        is_url_based=1
        provider="github"
        mr_num=$(printf '%s' "$cmd_token" | grep -oE '/pulls/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
        [ -n "$mr_num" ] || mr_num=$(printf '%s' "$cmd_match" | grep -oE '/pulls/[0-9]+/merge' | grep -oE '[0-9]+' | head -1 || true)
    elif printf '%s' "$cmd_match" | grep -qE "$GENERIC_MERGE_URL_RE" \
         || printf '%s' "$cmd_token" | grep -qE "$GENERIC_MERGE_URL_RE"; then
        # Last-resort segment-hidden: PUT + something/<X>/merge but segment
        # name hidden behind variables. Block as unresolved.
        is_gh_merge=1
        is_url_based=1
        provider="github (segment hidden)"
        mr_num=""
    elif printf '%s' "$cmd_match" | grep -qE '\$\{?[A-Za-z_]' \
         && { printf '%s' "$cmd_match" | grep -qiE '(github\.com|gitlab\.com|bitbucket\.org|/repos/|/projects/|/pulls\b|/merge_requests\b|\bGH_TOKEN\b|\bGITHUB_TOKEN\b|\bGITLAB_TOKEN\b|\bpullRequest\b)' \
              || printf '%s' "$cmd_match" | grep -qE '\bbase64[[:space:]]+(-d|--decode)\b' \
              || printf '%s' "$cmd_match" | grep -qE '\b(eval|bash[[:space:]]+-c|sh[[:space:]]+-c|zsh[[:space:]]+-c)\b' \
              || printf '%s' "$cmd_match" | grep -qE '\$\{?(MERGE_URL|MR_URL|PR_URL|PULL_URL|GH_URL|GIT_URL|GITHUB_URL|GITLAB_URL|REMOTE_URL|MERGE_API|MERGE_ENDPOINT)\}?\b'; }; then
        # Paranoid catch. PUT + variable reference AND any of:
        #   * direct GH/GL hint (domain, path, token, pullRequest keyword)
        #   * dynamic URL construction (base64 -d, eval, bash -c, sh -c)
        #   * GH/GL-specific variable name ($MERGE_URL, $PR_URL, $GH_URL, etc.)
        # Generic variable names ($URL, $ENDPOINT, $API_URL, $TARGET) are
        # NOT signals - too common in non-merge API scripts and trigger
        # false-positives. Hidden-URL bypasses via creatively-named vars
        # without any of the above signals are an accepted residual risk.
        is_gh_merge=1
        is_url_based=1
        provider="unknown (variable target, indirection signal present)"
        mr_num=""
    fi
fi

# GraphQL merge mutations (mergePullRequest / enablePullRequestAutoMerge).
# Token detection uses cmd_token so split-token bypasses like
# `en${EMPTY}ablePullRequestAutoMerge` are collapsed back to the literal.
if printf '%s' "$cmd_token" | grep -qE "$GH_GRAPHQL_RE"; then
    is_gh_merge=1
    is_url_based=1
    provider="github"
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
    if [ "$is_url_based" -eq 1 ]; then
        echo "::error::ralph-loop-04: $provider URL-based merge against unresolved target (\$VAR substitution or GraphQL mutation). BLOCKED — cannot validate evidence for unknown PR/MR." >&2
        echo "Resolve: invoke with explicit numeric PR/MR identifier (e.g. gh pr merge 123) or use --ralph-override." >&2
        exit 2
    fi
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
                if [ -f "$evidence_abs" ] && grep -qE '^Verdict:[[:space:]]+PASS([[:space:]]|$)' "$evidence_abs"; then
                    local_pass=1
                fi
            fi
        fi
    fi
fi

if [ -d "$repo/docs/superpowers/reviews" ]; then
    for f in "$repo"/docs/superpowers/reviews/*-pr"$mr_num"-*-codex.md "$repo"/docs/superpowers/reviews/*-mr"$mr_num"-*-codex.md; do
        [ -f "$f" ] || continue
        if grep -qE '^\*?\*?Verdict:?\*?\*?[[:space:]]+APPROVED\b' "$f"; then
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
