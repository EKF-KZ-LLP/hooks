#!/usr/bin/env bash
# Ralph Loop UserPromptSubmit hook (PSA edition).
#
# - Injects [PENDING TASKS: N] header showing first open `[ ]` from
#   .evidence/phase0-plan.md.
# - Recognises `OVERRIDE: skip task <CODE>` in user prompt → marks the
#   matching item as `[~] (skipped: <reason>)` so Stop hook stops
#   counting it. Audit trail preserved in plan diff.
#
# Exit always 0 — never block prompt submission.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLAN_FILE="$PROJECT_DIR/.evidence/phase0-plan.md"

[[ -f "$PLAN_FILE" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat || true)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"

# Escape: OVERRIDE: skip task <CODE> [reason: <text>]
if [[ "$PROMPT" =~ OVERRIDE:\ skip\ task\ ([A-Z]-?[0-9]+)([[:space:]]+reason:\ (.+))? ]]; then
  CODE="${BASH_REMATCH[1]}"
  REASON="${BASH_REMATCH[3]:-no reason given}"
  # Replace [ ] with [~] for that code; keep the line for audit.
  if grep -qE "^[[:space:]]*-[[:space:]]+\[ \][[:space:]]+\*\*${CODE}:" "$PLAN_FILE"; then
    awk -v code="$CODE" -v reason="$REASON" '
      $0 ~ ("^[[:space:]]*-[[:space:]]+\\[ \\][[:space:]]+\\*\\*" code ":") {
        sub(/\[ \]/, "[~]")
        printf "%s  <!-- SKIPPED: %s -->\n", $0, reason
        next
      }
      { print }
    ' "$PLAN_FILE" >"$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"
    jq -n --arg code "$CODE" --arg reason "$REASON" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("Ralph Loop: marked task " + $code + " as SKIPPED (" + $reason + ").")}}'
    exit 0
  fi
fi

# Pending tasks header.
UNCHECKED="$(grep -nE '^[[:space:]]*-[[:space:]]+\[ \][[:space:]]+\*\*' "$PLAN_FILE" || true)"
COUNT="$(printf '%s\n' "$UNCHECKED" | sed '/^$/d' | wc -l | tr -d '[:space:]')"

[[ "${COUNT:-0}" -gt 0 ]] || exit 0

FIRST="$(printf '%s\n' "$UNCHECKED" | head -1 | sed -E 's/^[0-9]+://' | sed -E 's/^[[:space:]]+//')"
MSG="[PENDING TASKS: ${COUNT}] First open: ${FIRST}
Plan: .evidence/phase0-plan.md. Use 'OVERRIDE: skip task <CODE> reason: <text>' to skip a task."

jq -n --arg msg "$MSG" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$msg}}'

exit 0
