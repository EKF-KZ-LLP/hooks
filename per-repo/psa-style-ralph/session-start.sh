#!/usr/bin/env bash
# Ralph Loop SessionStart hook.
# It injects global rules, project rules, and the phase0 plan as one structured
# context message while never blocking session startup.
set -euo pipefail

# SessionStart must never block the user from opening a session.
trap 'printf "%s\n" "Ralph Loop SessionStart skipped after hook error." >&2; exit 0' ERR

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CTX_FILE="$(mktemp "${TMPDIR:-/tmp}/ralph-session-context.XXXXXX")"

# Persist run-epoch so PreToolUse mtime gate has a real baseline.
# env vars don't survive across hook invocations; a file does.
PROJECT_KEY="$(printf '%s' "$PROJECT_DIR" | cksum | awk '{print $1}')"
EPOCH_FILE="${TMPDIR:-/tmp}/ralph-run-epoch-${PROJECT_KEY}"
date +%s >"$EPOCH_FILE" 2>/dev/null || true
chmod 0644 "$EPOCH_FILE" 2>/dev/null || true

append_file() {
  local label="$1"
  local path="$2"
  [[ -f "$path" ]] || return 0

  # Use printf for stable output and avoid echo option/subshell surprises.
  printf '\n===== %s =====\n' "$label" >>"$CTX_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >>"$CTX_FILE"
  done <"$path"
}

{
  printf '<system-message name="ralph-loop-session-context">\n'
  printf 'The following content is loaded as Ralph Loop operating context.\n'
  printf 'Temporary context file: %s\n' "$CTX_FILE"
  printf '</system-message>\n'
} >"$CTX_FILE"

append_file "global CLAUDE.md" "$HOME/.claude/CLAUDE.md"

# Rules are sorted by the shell glob order; nullglob avoids a literal *.md.
shopt -s nullglob
for rule_file in "$HOME"/.claude/rules/*.md; do
  append_file "global rule: ${rule_file##*/}" "$rule_file"
done
shopt -u nullglob

append_file "project .claude/CLAUDE.md" "$PROJECT_DIR/.claude/CLAUDE.md"
append_file "project CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
append_file "phase0 plan" "$PROJECT_DIR/.evidence/phase0-plan.md"

if command -v jq >/dev/null 2>&1; then
  jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}' <"$CTX_FILE"
else
  # Startup must always succeed; plain text is a safe fallback if jq is absent.
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
  done <"$CTX_FILE"
fi

exit 0
