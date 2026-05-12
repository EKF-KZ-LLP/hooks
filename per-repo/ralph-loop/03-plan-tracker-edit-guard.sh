#!/usr/bin/env bash
# Ralph-Loop hook 03 - PreToolUse Edit/Write (anti-cheat).
# Allows tracker edits only when:
#   - operation is a strict `[ ] -> [x]` flip (or `[ ] -> [x] [SKIP]`)
#   - total checkbox count does NOT decrease
#   - the flipped line carries `evidence:` pointing at an existing
#     readonly file containing literal `Verdict: PASS`
#     (skip path requires `.checkpoints/<slug>/skip-reason.md` instead)
#
# Blocks any direct write to `.checkpoints/*/evidence.md` -- evidence
# is produced only by `run-codex-review.sh`.

set -euo pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0
active_pointer="$repo/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[ -n "$file_path" ] || exit 0

# Block direct evidence.md / skip-reason.md writes via Edit/Write tools.
# Agent can only legitimately produce these via:
#   - evidence.md             → run-codex-review.sh
#   - skip-reason.md          → hook 02 from user OVERRIDE prompt
case "$file_path" in
    *.checkpoints/*/evidence.md|*.checkpoints/*/attempt-*.md|*.checkpoints/*/pre-fix-failing-test.md|*.checkpoints/*/*review*.md|*.checkpoints/*/codex-review-raw.txt|*.checkpoints/*/iteration-count)
        echo "::error::ralph-loop-03: direct write to '$file_path' forbidden. Evidence is produced only by run-codex-review.sh." >&2
        exit 2
        ;;
    *.checkpoints/*/skip-reason.md)
        echo "::error::ralph-loop-03: direct write to '$file_path' forbidden. skip-reason.md is produced only by hook 02 when user issues 'OVERRIDE: skip task <slug>' from a prompt. Agent self-SKIP cheat vector closed 2026-05-12." >&2
        exit 2
        ;;
esac

# Only enforce the flip rule on the active tracker.
if [ "$file_path" != "$tracker" ]; then
    exit 0
fi

new_string=$(printf '%s' "$input" | jq -r '.tool_input.new_string // .tool_input.content // ""' 2>/dev/null || true)
old_string=$(printf '%s' "$input" | jq -r '.tool_input.old_string // ""' 2>/dev/null || true)

# Construct simulated post-edit text.
if [ -z "$old_string" ]; then
    # Write tool: full replacement. Compare checkbox counts.
    new_count=$(printf '%s' "$new_string" | grep -cE "^- \[" || true)
    old_count=$(grep -cE "^- \[" "$tracker" 2>/dev/null || echo 0)
    if [ "$new_count" -lt "$old_count" ]; then
        echo "::error::ralph-loop-03: tracker checkbox count must not decrease (was $old_count, would become $new_count). Skips use '[x] [SKIP]', they do not delete the line." >&2
        exit 2
    fi
    # Write of full tracker also blocked unless agent only flipped boxes.
    # Easiest cross-platform check: refuse Write entirely; require Edit.
    echo "::error::ralph-loop-03: full-file Write of tracker forbidden. Use Edit with a single-line flip." >&2
    exit 2
fi

# Edit path: ensure old_string is a `[ ]` line and new_string is `[x]`
# (with same task body).
if ! printf '%s' "$old_string" | grep -qE '^- \[ \] '; then
    echo "::error::ralph-loop-03: tracker Edit must target a '- [ ] ...' line. Got: $(printf '%s' "$old_string" | head -c 120)" >&2
    exit 2
fi
if ! printf '%s' "$new_string" | grep -qE '^- \[x\]( \[SKIP\])? '; then
    echo "::error::ralph-loop-03: tracker Edit may only flip to '- [x] ...' or '- [x] [SKIP] ...'. Got: $(printf '%s' "$new_string" | head -c 120)" >&2
    exit 2
fi

# Body must match minus the box state.
old_body=$(printf '%s' "$old_string" | sed -E 's/^- \[ \] //')
new_body=$(printf '%s' "$new_string" | sed -E 's/^- \[x\]( \[SKIP\])? //')
if [ "$old_body" != "$new_body" ]; then
    echo "::error::ralph-loop-03: tracker Edit must keep task body identical. Old body: $old_body New body: $new_body" >&2
    exit 2
fi

# Extract evidence path from the line. New Task Evidence Contract stores
# evidence in the metadata block below the checkbox, so fall back to the
# simulated post-edit task block when the line has no inline marker.
evidence_rel=$(printf '%s' "$new_string" | grep -oE 'evidence:[[:space:]]*[^ ]+' | sed -E 's/^evidence:[[:space:]]*//' | head -1)
if [ -z "$evidence_rel" ]; then
    task_id=$(printf '%s' "$new_string" | sed -nE 's/^- \[x\]( \[SKIP\])?[[:space:]]+(\*\*)?([A-Z][A-Z0-9]*-[0-9A-Z._-]+):.*/\3/p' | head -1)
    if [ -n "$task_id" ]; then
        post_text=$(python3 - "$tracker" "$old_string" "$new_string" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
print(text.replace(old, new, 1), end="")
PYEOF
)
        evidence_rel=$(printf '%s\n' "$post_text" | awk -v code="$task_id" '
            $0 ~ "^- \\[x\\]( \\[SKIP\\])?[[:space:]]+(\\*\\*)?" code ":" {in_block=1; next}
            in_block && /^- \[[ xX~]\]/ {exit}
            in_block && /^[[:space:]]+-[[:space:]]+evidence:/ {
                sub(/^[[:space:]]+-[[:space:]]+evidence:[[:space:]]*/, "")
                gsub(/`/, "")
                print
                exit
            }
        ')
    fi
fi
if [ -z "$evidence_rel" ]; then
    echo "::error::ralph-loop-03: tracker line missing 'evidence: <path>' marker." >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
evidence_abs="$repo/$evidence_rel"

# SKIP path check. Hardened 2026-05-12 - closes agent self-SKIP cheat
# vector. skip-reason.md must be authored by hook 02 (from user
# OVERRIDE prompt), not by the agent via Write/Bash. Three checks:
#   1. File exists.
#   2. File is chmod 444 (immutable post-hook-02 write).
#   3. File contains literal `Author: user-override-hook02` marker
#      AND `Override-prompt-hash: <64-hex>` line.
# Agent cannot fake any of these without ALSO triggering hooks that
# already block direct evidence/tracker writes (guard-no-tracker-overwrite).
if printf '%s' "$new_string" | grep -q '\[SKIP\]'; then
    skip_dir=$(dirname "$evidence_abs")
    skip_file="$skip_dir/skip-reason.md"
    if [ ! -f "$skip_file" ]; then
        echo "::error::ralph-loop-03: SKIP flip requires '$skip_file'. Only hook 02 (UserPromptSubmit OVERRIDE) can create it. Issue 'OVERRIDE: skip task <slug>' from a user prompt." >&2
        exit 2
    fi
    perms=$(stat -f '%A' "$skip_file" 2>/dev/null || stat -c '%a' "$skip_file" 2>/dev/null || echo "")
    if [ "$perms" != "444" ]; then
        echo "::error::ralph-loop-03: skip-reason '$skip_file' perms='$perms', expected 444 (immutable post-hook-02 write). Agent likely authored this file directly - cheat vector. Delete file and re-issue 'OVERRIDE: skip task <slug>'." >&2
        exit 2
    fi
    if ! grep -qE '^Author: user-override-hook02$' "$skip_file"; then
        echo "::error::ralph-loop-03: skip-reason '$skip_file' missing 'Author: user-override-hook02' marker. Only hook 02 sets this. Delete and re-issue OVERRIDE." >&2
        exit 2
    fi
    if ! grep -qE '^Override-prompt-hash: [0-9a-f]{64}$' "$skip_file"; then
        echo "::error::ralph-loop-03: skip-reason '$skip_file' missing 'Override-prompt-hash: <64-hex>'. Hook 02 records the user prompt sha256 for audit. Delete and re-issue OVERRIDE." >&2
        exit 2
    fi
    exit 0
fi

# Normal closure: evidence file must exist + be chmod 444 + contain Verdict: PASS.
if [ ! -f "$evidence_abs" ]; then
    echo "::error::ralph-loop-03: evidence file '$evidence_abs' missing. Run run-codex-review.sh first." >&2
    exit 2
fi
perms=$(stat -f '%A' "$evidence_abs" 2>/dev/null || stat -c '%a' "$evidence_abs" 2>/dev/null || echo "")
if [ "$perms" != "444" ]; then
    echo "::error::ralph-loop-03: evidence file '$evidence_abs' has perms '$perms', expected '444' (immutable). Re-generate via run-codex-review.sh." >&2
    exit 2
fi
if ! grep -qE '^Verdict:[[:space:]]+PASS([[:space:]]|$)' "$evidence_abs"; then
    echo "::error::ralph-loop-03: evidence file '$evidence_abs' does not contain literal 'Verdict: PASS'. Codex did not approve - keep [ ] and continue work." >&2
    exit 2
fi

exit 0
