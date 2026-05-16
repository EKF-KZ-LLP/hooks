#!/bin/bash
set -eu

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/serena-remind-soft-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK="$TMP_ROOT/serena-hooks"
cat > "$MOCK" <<'SH'
#!/bin/bash
cat >/dev/null
if [ "${SERENA_MOCK_MODE:-block}" = "ok" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"ok"}}\n'
  exit 0
fi
printf 'Too many consecutive read calls of files without using symbolic tools.\n' >&2
exit 2
SH
chmod +x "$MOCK"

SCRIPT=/Users/antonsahovskii/.local/share/agent-hooks/serena-remind-soft.sh

BLOCKED_OUTPUT=$(printf '{"tool_name":"Bash"}' | SERENA_HOOKS_BIN="$MOCK" "$SCRIPT" --client=claude-code)
printf '%s' "$BLOCKED_OUTPUT" | /opt/homebrew/bin/node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(0, "utf8"));
if (payload.hookSpecificOutput.hookEventName !== "PreToolUse") process.exit(1);
if (!/demoted from hard block/.test(payload.hookSpecificOutput.additionalContext)) process.exit(1);
if (!/Too many consecutive read calls/.test(payload.hookSpecificOutput.additionalContext)) process.exit(1);
'

CODEX_OUTPUT=$(printf '{"tool_name":"Bash"}' | SERENA_HOOKS_BIN="$MOCK" "$SCRIPT" --client=codex)
printf '%s' "$CODEX_OUTPUT" | /opt/homebrew/bin/node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(0, "utf8"));
if (!/demoted from hard block/.test(payload.additionalContext)) process.exit(1);
'

OK_OUTPUT=$(printf '{"tool_name":"Bash"}' | SERENA_MOCK_MODE=ok SERENA_HOOKS_BIN="$MOCK" "$SCRIPT" --client=claude-code)
printf '%s' "$OK_OUTPUT" | /opt/homebrew/bin/node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(0, "utf8"));
if (payload.hookSpecificOutput.additionalContext !== "ok") process.exit(1);
'

echo "serena-remind-soft.test.sh passed"
