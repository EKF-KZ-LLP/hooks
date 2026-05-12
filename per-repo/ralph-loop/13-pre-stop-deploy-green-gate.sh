#!/usr/bin/env bash
# Ralph-Loop hook 13 - Stop / SubagentStop pre-deploy-green-gate.
# Refuses session-end (and sprint-complete claims) when the latest
# build-deploy.yml run on the default branch is NOT green.
#
# Closes the audit gap exposed 2026-05-11: agent merged 11 PRs across
# the session WITHOUT noticing that every triggered deploy was failing
# (64/64 fails on deployments page). "Merge != deploy" was treated as
# acceptable; this hook makes it a hard stop.
#
# Per-repo opt-in via marker:  <repo>/.claude/.deploy-check-enabled
# Bypass (single-shot):        touch <repo>/.claude/.allow-stop-deploy-red
#   The bypass marker is consumed on use to force a fresh decision each
#   time deploy is red.

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0

# Per-repo opt-in.
[ -f "$repo/.claude/.deploy-check-enabled" ] || exit 0

# Single-shot bypass.
bypass="$repo/.claude/.allow-stop-deploy-red"
if [ -f "$bypass" ]; then
    reason=$(head -1 "$bypass" 2>/dev/null || echo "(no reason)")
    rm -f "$bypass"
    echo "[ralph-loop-13] BYPASS used: '$bypass' (single-shot, reason: $reason)" >&2
    exit 0
fi

# Need gh CLI to query.
if ! command -v gh >/dev/null 2>&1; then
    echo "[ralph-loop-13] gh CLI not installed; cannot verify deploy status. Skipping (no-op fallback)." >&2
    exit 0
fi

# Check most recent build-deploy.yml run.
last=$(gh run list --workflow build-deploy.yml --limit 1 \
    --json conclusion,status,databaseId,createdAt 2>/dev/null \
    | jq -r '.[0] | "\(.status)|\(.conclusion // "")|\(.databaseId)|\(.createdAt)"' 2>/dev/null || echo "")

if [ -z "$last" ] || [ "$last" = "null|null|null|null" ]; then
    echo "[ralph-loop-13] no build-deploy.yml runs found yet — allowing stop." >&2
    exit 0
fi

status=$(echo "$last" | cut -d'|' -f1)
conclusion=$(echo "$last" | cut -d'|' -f2)
run_id=$(echo "$last" | cut -d'|' -f3)
created=$(echo "$last" | cut -d'|' -f4)

case "$status:$conclusion" in
    completed:success)
        exit 0
        ;;
    completed:skipped|completed:cancelled|completed:neutral)
        # Skipped runs are not failures (often path-filter skips or
        # cancellation by superseding push).
        exit 0
        ;;
    completed:failure|completed:timed_out|completed:startup_failure|completed:action_required)
        cat >&2 <<EOF
::error::ralph-loop-13: build-deploy.yml last run #$run_id ($created) ended '$conclusion'.

Sprint is NOT complete until deploy is green. Cannot stop session.

Options:
  (a) Investigate: gh run view $run_id --log-failed
  (b) Re-trigger:  gh workflow run build-deploy.yml -f component=all
  (c) Bypass (single-shot, requires rationale):
        echo "<your reason>" > $bypass

The bypass file is deleted after use. Each red deploy demands a fresh
operator decision.
EOF
        exit 2
        ;;
    *)
        # in_progress / queued / waiting / requested / etc.
        cat >&2 <<EOF
::error::ralph-loop-13: build-deploy.yml run #$run_id is '$status' (not yet completed).
Wait for green deploy before ending session.

Watch: gh run watch $run_id
EOF
        exit 2
        ;;
esac
