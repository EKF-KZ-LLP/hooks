#!/usr/bin/env bash
# destructive-sql-guard.sh - PreToolUse hook for Bash.
# Blocks destructive SQL invocations through psql/clickhouse-client/mysql/migrate
# that the broad Bash() allow-list could otherwise pass through.
# Replaces fragile leading-* deny patterns ('Bash(*DROP DATABASE*)') that depended
# on prefix-matcher semantics.
set -euo pipefail

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
elif command -v python3 >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('tool_input',d).get('command',''))
except Exception:
    pass
" 2>/dev/null || true)
else
  exit 0
fi

[[ -z "${CMD:-}" ]] && exit 0

# Normalize: lower-case + collapse whitespace for matching
NORM=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')

# Only scan SQL-tool invocations. Commit messages, docs, log searches must not trigger.
case "$NORM" in
  *psql\ *|*psql*--command*|*clickhouse-client*|*clickhouse\ *|\
  *mysql\ *|*mariadb\ *|*pgcli*|*sqlplus*|*mongosh*|*migrate\ -*|*flyway\ *|*liquibase\ *) ;;
  *) exit 0 ;;
esac

# Block patterns inside SQL-tool invocation only.
PATTERNS=(
  'drop database'
  'drop schema'
  'drop table'
  'truncate table'
  'delete from .* where 1=1'
  'delete from .* where 1 = 1'
)

for pat in "${PATTERNS[@]}"; do
  if [[ "$NORM" =~ $pat ]]; then
    cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Destructive SQL pattern detected: '${pat}' in command. If intentional, run via dedicated migration tool with confirmation."}}
JSON
    exit 2
  fi
done

exit 0
