#!/usr/bin/env bash
# graphify-hint.sh - PreToolUse hook for Bash.
# When agent runs grep/find/rg/fd and graphify graph exists,
# emit additionalContext hinting to read GRAPH_REPORT.md first.
# Replaces fragile inline python3 one-liner that lived in settings.json.
set -euo pipefail

# stdin = JSON: { "tool_name": "Bash", "tool_input": {"command": "..."} }
INPUT=$(cat)

# Extract command. jq preferred, python3 fallback.
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

# Match search-y commands
case "$CMD" in
  *grep\ *|*\ rg\ *|*ripgrep*|*\ find\ *|*\ fd\ *|*\ ack\ *|*\ ag\ *) ;;
  *) exit 0 ;;
esac

# Only hint if graphify graph exists
if [[ -f graphify-out/graph.json ]]; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"graphify: Knowledge graph exists. Read graphify-out/GRAPH_REPORT.md for god nodes and community structure before searching raw files."}}
JSON
fi
exit 0
