#!/bin/bash
set -u

CLIENT=claude-code
for arg in "$@"; do
  case "$arg" in
    --client=*) CLIENT=${arg#--client=} ;;
  esac
done

SERENA_HOOKS_BIN=${SERENA_HOOKS_BIN:-/Users/antonsahovskii/.local/bin/serena-hooks}
TMP_DIR=${TMPDIR:-/tmp}
IN_FILE=$(mktemp "$TMP_DIR/serena-remind-soft-in.XXXXXX")
OUT_FILE=$(mktemp "$TMP_DIR/serena-remind-soft-out.XXXXXX")
ERR_FILE=$(mktemp "$TMP_DIR/serena-remind-soft-err.XXXXXX")
trap 'rm -f "$IN_FILE" "$OUT_FILE" "$ERR_FILE"' EXIT

cat > "$IN_FILE"

if [ ! -x "$SERENA_HOOKS_BIN" ]; then
  exit 0
fi

"$SERENA_HOOKS_BIN" remind --client="$CLIENT" < "$IN_FILE" > "$OUT_FILE" 2> "$ERR_FILE"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  cat "$OUT_FILE"
  exit 0
fi

MESSAGE=$(cat "$ERR_FILE" "$OUT_FILE" 2>/dev/null | head -c 4000)
if [ -z "$MESSAGE" ]; then
  MESSAGE="Serena reminder requested symbolic tools."
fi

/opt/homebrew/bin/node - "$CLIENT" "$MESSAGE" <<'NODE'
const [client, message] = process.argv.slice(2);
const text = [
  "Serena reminder demoted from hard block to context.",
  message,
  "Use Serena or GitNexus for symbolic/context work before risky source edits."
].join("\n");
if (client === "codex") {
  process.stdout.write(JSON.stringify({ additionalContext: text }) + "\n");
} else {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: text
    }
  }) + "\n");
}
NODE
exit 0
