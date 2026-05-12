#!/usr/bin/env bash
# Ralph Loop Stop hook.
# It keeps the session alive while unchecked phase0 plan items remain, unless
# the last commit explicitly waives the loop.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLAN_FILE="$PROJECT_DIR/.evidence/phase0-plan.md"

json_continue() {
  local count="$1"
  local message="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg message "$message" --argjson count "$count" \
      '{continue:true,uncheckedCount:$count,hookSpecificOutput:{hookEventName:"Stop",additionalContext:$message}}'
  else
    # Fallback stays valid JSON; omit dynamic text because escaping needs jq.
    printf '{"continue":true,"uncheckedCount":%s,"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"Finish remaining .evidence/phase0-plan.md items or commit with WAIVE: token."}}\n' "$count"
  fi
}

[[ -f "$PLAN_FILE" ]] || exit 0

# Count only real plan items, not the format legend near the top of the file.
UNCHECKED_LINES="$(grep -E '^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+\*\*' "$PLAN_FILE" || true)"
UNCHECKED_COUNT="$(printf '%s\n' "$UNCHECKED_LINES" | sed '/^$/d' | wc -l | tr -d '[:space:]')"

[[ "${UNCHECKED_COUNT:-0}" -gt 0 ]] || exit 0

# The contract asks for git log --oneline -1 and a literal WAIVE: token.
LAST_COMMIT="$(git -C "$PROJECT_DIR" log --oneline -1 2>/dev/null || true)"
case "$LAST_COMMIT" in
  *"WAIVE: "*) exit 0 ;;
esac

MESSAGE="$(printf 'Ralph Loop: %s unchecked item(s) remain in .evidence/phase0-plan.md.\nFinish them or make the last commit message contain WAIVE: to allow exit.\n\nRemaining:\n%s' "$UNCHECKED_COUNT" "$UNCHECKED_LINES")"
json_continue "$UNCHECKED_COUNT" "$MESSAGE"

# Exit 1 is intentional: Stop must block close when unfinished work remains.
exit 1
