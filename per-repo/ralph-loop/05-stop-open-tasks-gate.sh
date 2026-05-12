#!/usr/bin/env bash
# Ralph-Loop hook 05 - Stop / SubagentStop.
# Three gates fired on Stop:
#   G_OPEN  Refuses stop while open `[ ]` checkboxes remain in active-tracker.
#   G15     Refuses stop when HANDOFF.md mtime is older than last code commit
#           by more than HANDOFF_STALE_SEC (default 7200 = 2h).
#   G32     Refuses stop when last commit body contains an invalid-blocker
#           phrase ("не получилось", "тесты падают", "probably impossible"...)
#           without an explicit attempt log entry in HANDOFF.md.
# Override marker: `touch <repo>/.claude/.allow-stop`.

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0

override_marker="$repo/.claude/.allow-stop"
[ -f "$override_marker" ] && exit 0

# ----------------------------------------------------------------------
# G_OPEN: open `[ ]` tasks in active-tracker.
# ----------------------------------------------------------------------
active_pointer="$repo/.claude/active-tracker"
if [ -f "$active_pointer" ]; then
    tracker=$(<"$active_pointer")
    if [ -f "$tracker" ]; then
        open_tasks=$(grep -nE "^- \[ \]" "$tracker" 2>/dev/null || true)
        if [ -n "$open_tasks" ]; then
            first=$(printf '%s' "$open_tasks" | head -1)
            cat <<EOF >&2
::error::ralph-loop-05: open tracker tasks remain. Cannot stop session.

First open task:
  $first

Tracker: $tracker
Total open: $(printf '%s' "$open_tasks" | wc -l | tr -d ' ')

Resume work on the first open task. To intentionally end early, the
operator must \`touch $override_marker\` and re-trigger Stop.
EOF
            exit 2
        fi
    fi
fi

# ----------------------------------------------------------------------
# G15: HANDOFF.md freshness vs last code commit.
# ----------------------------------------------------------------------
handoff="$repo/HANDOFF.md"
if [ -f "$handoff" ]; then
    last_code_ts=$(git -C "$repo" log -1 --format=%ct -- \
        '*.go' '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.sh' '*.sql' \
        2>/dev/null || echo 0)
    handoff_mtime=$(stat -f %m "$handoff" 2>/dev/null || stat -c %Y "$handoff" 2>/dev/null || echo 0)
    stale_sec="${HANDOFF_STALE_SEC:-7200}"
    if [ "$last_code_ts" -gt 0 ] && [ $((handoff_mtime + stale_sec)) -lt "$last_code_ts" ]; then
        last_code_iso=$(date -r "$last_code_ts" -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -d @"$last_code_ts" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$last_code_ts")
        handoff_iso=$(date -r "$handoff_mtime" -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -d @"$handoff_mtime" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$handoff_mtime")
        cat <<EOF >&2
::error::ralph-loop-05 (G15): HANDOFF.md stale.
  last code commit: $last_code_iso
  HANDOFF.md mtime: $handoff_iso
  gap > ${stale_sec}s (HANDOFF_STALE_SEC).
Update HANDOFF.md with current state, what changed, next steps, then re-trigger Stop.
EOF
        exit 2
    fi
fi

# ----------------------------------------------------------------------
# G32: invalid-blocker phrases in last commit body without attempt log.
# ----------------------------------------------------------------------
last_commit_body=$(git -C "$repo" log -1 --format=%B 2>/dev/null || true)
if printf '%s' "$last_commit_body" | grep -qiE 'не получилось|тесты падают|probably impossible|неясно почему|нужно разобраться|не работает совсем'; then
    if [ -f "$handoff" ]; then
        if ! grep -qE '^[[:space:]]*-?[[:space:]]*attempt:[[:space:]]+[0-9]+' "$handoff"; then
            cat <<EOF >&2
::error::ralph-loop-05 (G32): last commit body contains an invalid-blocker
phrase but HANDOFF.md has no '- attempt: N' machine-readable log.
Add an attempt entry with task_id, hypothesis, action, command_or_artifact,
result, next_decision, evidence, timestamp - then re-trigger Stop.
EOF
            exit 2
        fi
    fi
fi

exit 0
