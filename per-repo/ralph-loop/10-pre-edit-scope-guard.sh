#!/usr/bin/env bash
# Ralph-Loop hook 10 - PreToolUse Edit/Write/MultiEdit (scope drift guard).
# Closes audit gap #2: nothing prevented agent from editing files outside
# the active task's declared `Files:` whitelist.
#
# Looks up active task slug (first [ ] checkbox in tracker matching current
# git branch via slug substring), reads its task-spec.md `Files:` section,
# and refuses Edit/Write to any path NOT in whitelist.
#
# Bypass: file_path inside `.claude/`, `docs/`, `*.md`, `*.txt` always
# allowed (out-of-scope-by-design housekeeping). Override:
# `--ralph-override` in tool input bash command (not applicable here, but
# parity with sibling hooks).
#
# Skips if no task-spec exists (no scope to enforce).

set -euo pipefail

active_pointer="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/active-tracker"
[ -f "$active_pointer" ] || exit 0
tracker=$(<"$active_pointer")
[ -f "$tracker" ] || exit 0

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[ -n "$file_path" ] || exit 0

# Always-allowed housekeeping paths (.claude/, docs/, .md, .txt, scratch).
case "$file_path" in
    */.claude/*|*/docs/*|*.md|*.txt|/tmp/*|/private/tmp/*) exit 0 ;;
esac

repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Resolve active slug: first [ ] checkbox whose evidence path slug is
# a substring of current git branch name.
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ -n "$branch" ] || exit 0
[ "$branch" = "main" ] && exit 0

slug=$(grep -oE 'evidence:\s*\.checkpoints/[^/]+' "$tracker" 2>/dev/null \
    | sed -E 's|evidence:\s*\.checkpoints/||' \
    | while read -r s; do
        if echo "$branch" | grep -qF "$s"; then echo "$s"; break; fi
      done | head -1)

[ -n "$slug" ] || exit 0

spec="$repo/.checkpoints/$slug/task-spec.md"
[ -f "$spec" ] || exit 0

# Extract Files: section (between '## Files' and next '## ').
whitelist=$(awk '/^## Files/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | grep -oE '`[^`]+`|^- [^ ]+|[a-zA-Z0-9_/.-]+\.(go|py|ts|tsx|js|jsx|sh|sql|yml|yaml|toml|json)' \
    | sed -E 's/^- //; s/^`//; s/`$//' \
    | sort -u)

if [ -z "$whitelist" ]; then
    echo "[ralph-loop-10] task-spec '$spec' has empty Files: section, allowing." >&2
    exit 0
fi

# Normalize file_path to a comparable form (strip /tmp/vcm-clean/ prefix).
short_path=$(printf '%s' "$file_path" | sed -E "s|^$repo/||")

# Check if short_path matches any whitelist entry (exact or substring).
matched=0
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if [ "$short_path" = "$entry" ] || echo "$short_path" | grep -qF "$entry"; then
        matched=1
        break
    fi
done <<< "$whitelist"

if [ "$matched" -eq 0 ]; then
    cat >&2 <<EOF
::error::ralph-loop-10: file '$short_path' is OUT OF SCOPE for task '$slug'.

Task spec: $spec
Whitelist (## Files):
$(printf '  - %s\n' $whitelist)

If this edit is genuinely required, append the file to task-spec.md ## Files
section with rationale comment, then retry. Do NOT silently expand scope.
EOF
    exit 2
fi

exit 0
