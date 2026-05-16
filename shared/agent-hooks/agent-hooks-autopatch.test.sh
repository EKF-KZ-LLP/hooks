#!/bin/bash
set -eu

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-hooks-autopatch-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

CLAUDE_MEM_PATCH="$TMP_ROOT/claude-mem-autopatch.sh"
CLAUDE_MEM_WATCHDOG="$TMP_ROOT/claude-mem-watchdog.sh"
GITNEXUS_PATCH="$TMP_ROOT/patch-gitnexus.js"
LOG="$TMP_ROOT/autopatch.log"

cat > "$CLAUDE_MEM_PATCH" <<'SH'
#!/bin/bash
echo claude-mem >> "$AGENT_HOOKS_AUTOPATCH_TEST_LOG"
exit 0
SH
chmod +x "$CLAUDE_MEM_PATCH"

cat > "$CLAUDE_MEM_WATCHDOG" <<'SH'
#!/bin/bash
echo watchdog "$@" >> "$AGENT_HOOKS_AUTOPATCH_TEST_LOG"
exit 0
SH
chmod +x "$CLAUDE_MEM_WATCHDOG"

cat > "$GITNEXUS_PATCH" <<'JS'
#!/usr/bin/env node
const fs = require("fs");
fs.appendFileSync(process.env.AGENT_HOOKS_AUTOPATCH_TEST_LOG, `gitnexus ${process.argv.slice(2).join(" ")}\n`);
process.exit(0);
JS
chmod +x "$GITNEXUS_PATCH"

SCRIPT=/Users/antonsahovskii/.local/bin/agent-hooks-autopatch.sh
AGENT_HOOKS_AUTOPATCH_TEST_LOG="$LOG" \
AGENT_HOOKS_CLAUDE_MEM_AUTOPATCH="$CLAUDE_MEM_PATCH" \
AGENT_HOOKS_CLAUDE_MEM_WATCHDOG="$CLAUDE_MEM_WATCHDOG" \
AGENT_HOOKS_GITNEXUS_PATCH="$GITNEXUS_PATCH" \
"$SCRIPT" --gitnexus-root "$TMP_ROOT/gitnexus" >/tmp/agent-hooks-autopatch-test.out

grep -q '^claude-mem$' "$LOG"
grep -q '^watchdog$' "$LOG"
grep -q -- '^gitnexus --root .*gitnexus$' "$LOG"
grep -q 'agent_hooks_autopatch=ok' /tmp/agent-hooks-autopatch-test.out

echo "agent-hooks-autopatch.test.sh passed"
