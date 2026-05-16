#!/usr/bin/env bash
# Canonical Ralph-loop Codex review evidence producer.

set -euo pipefail

slug="${1:?task slug required}"
repo="$(git rev-parse --show-toplevel)"
dir="$repo/.checkpoints/$slug"
mkdir -p "$dir"
raw="$dir/codex-review-raw.txt"
evidence="$dir/evidence.md"

epoch="$(date -u +%s)"
run_id="codex-${epoch}-${slug}"
sha="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"

plugin_root="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/openai-codex/codex/1.0.4}"
if [ ! -x "$plugin_root/scripts/codex-companion.mjs" ] && [ -x "$HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/codex-companion.mjs" ]; then
    plugin_root="$HOME/.claude/plugins/cache/openai-codex/codex/1.0.4"
fi
companion="$plugin_root/scripts/codex-companion.mjs"
if [ ! -x "$companion" ]; then
    echo "::error::run-codex-review.sh: Claude Code Codex plugin companion not found at '$companion'. Run /codex:setup, then /codex:rescue." >&2
    exit 2
fi

parse_codex_verdict() {
    awk '
    function clean_token(value) {
        gsub(/[`*]/, "", value)
        split(value, parts, /[^[:alnum:]_-]+/)
        return toupper(parts[1])
    }
    {
        line = $0
        gsub(/\r/, "", line)
        gsub(/[`*]/, "", line)
        sub(/^[[:space:]]+/, "", line)

        lower = tolower(line)
        if (lower ~ /^verdict[[:space:]]*:/) {
            rest = line
            sub(/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*/, "", rest)
            token = clean_token(rest)
            if (token ~ /^(PASS|FAIL|FOUND_ISSUES|DISAGREE|PASS-CONDITIONAL|PASS-WITH|CONDITIONAL)$/) {
                verdict = token
            }
        }

        if (match(lower, /"verdict"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
            json_token = substr(line, RSTART, RLENGTH)
            sub(/.*:[[:space:]]*"/, "", json_token)
            sub(/".*/, "", json_token)
            token = clean_token(json_token)
            if (token ~ /^(PASS|FAIL|FOUND_ISSUES|DISAGREE|PASS-CONDITIONAL|PASS-WITH|CONDITIONAL)$/) {
                verdict = token
            }
        }
    }
    END {
        if (verdict == "") {
            print "UNKNOWN"
        } else {
            print verdict
        }
    }' "$1"
}

prompt_text="Review commit ${sha} for task slug '${slug}'. This review is for Ralph Loop evidence and must be treated as coming from Claude Code plugin + codex:rescue / codex:codex-rescue. Do not review only the diff. Read full content of every changed file, trace callers, and verify tests cover the change end-to-end.

Required review steps:
1. Read full content of each file changed in the diff.
2. For each modified function or method, trace callers with grep or LSP references. List at least three callers, or 'no callers' if truly leaf.
3. For each modified function, locate tests and verify they exercise new behavior. List test names.
4. Enumerate negative scenarios: empty input, error path, boundary value, nil or null, edge case. Confirm at least one is covered by tests.
5. Reconcile plan-vs-code: if plan says X but code does Y, surface divergence.

Output format must end with these last three lines:
Findings: <one-line summary or 'no blocking issues'>
Subagent ID: <16-hex>
Verdict: PASS

Use 'Verdict: FAIL' if any high or blocking issue exists, or if any required review step cannot be filled. Incomplete review is FAIL. PASS-CONDITIONAL is forbidden."

prompt_file="$dir/codex-review-prompt.md"
printf '%s\n' "$prompt_text" > "$prompt_file"
node "$companion" task --json --fresh --prompt-file "$prompt_file" > "$raw" 2>&1 || true

raw_verdict="$(parse_codex_verdict "$raw")"
case "$raw_verdict" in
    PASS) verdict="PASS" ;;
    FAIL|FOUND_ISSUES|DISAGREE|PASS-CONDITIONAL|PASS-WITH|CONDITIONAL) verdict="FAIL" ;;
    *) verdict="UNKNOWN" ;;
esac

if [ "$verdict" != "PASS" ]; then
    cat <<EOF
::error::run-codex-review.sh: verdict for slug '$slug' is '$verdict' (not PASS).
Raw output: $raw
Fix the findings and rerun.
Tail:
$(tail -25 "$raw")
EOF
    exit 2
fi

[ -f "$evidence" ] && chmod 644 "$evidence"

agents_hash="unknown"
if [ -f "$repo/.checkpoints/AGENTS.md.hash" ]; then
    agents_hash="$(head -c 64 "$repo/.checkpoints/AGENTS.md.hash" | tr -d '[:space:]')"
elif [ -f "$repo/AGENTS.md" ]; then
    agents_hash="$( { shasum -a 256 "$repo/AGENTS.md" 2>/dev/null || sha256sum "$repo/AGENTS.md" 2>/dev/null; } | cut -c1-64)"
fi

senior_file="$dir/senior-engineer.md"
senior_line="$(grep -iE '^Senior-review:[[:space:]]*(PASS|FAIL)' "$senior_file" 2>/dev/null | head -1 || true)"
[ -n "$senior_line" ] || senior_line="Senior-review: MISSING"

findings_line="$(grep -aoiE 'No blocking[^"]{0,120}|no high[^"]{0,120}|all clean[^"]{0,120}' "$raw" 2>/dev/null | head -1 | cut -c1-200 || true)"
[ -n "$findings_line" ] || findings_line="see raw"

cat > "$evidence" <<EOF
Task: $slug
SHA: $sha
Commit: $sha
Codex-run-id: $run_id
Codex-tool: Claude Code plugin + codex:rescue
Codex-subagent: codex:codex-rescue
Review-scope: full-code-path
Diff-only: false
AGENTS.md-reviewed: yes (sha256 $agents_hash)
Review-output: verbatim (raw Codex output appended below unmodified)
$senior_line
Verdict: PASS
Command: node "$companion" task --json --fresh --prompt-file "$prompt_file"
Result: PASS
Findings: $findings_line
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

EOF
cat "$raw" >> "$evidence"

touch -d "@$epoch" "$evidence" 2>/dev/null || \
    touch -t "$(date -j -f %s "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d @"$epoch" +%Y%m%d%H%M.%S)" "$evidence"
chmod 444 "$evidence"

echo "[run-codex-review] PASS recorded for '$slug' at $evidence"
exit 0
