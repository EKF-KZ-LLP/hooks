#!/usr/bin/env bash
# Ralph-Loop universal launcher.
# Resolves the per-repo hook by event name and delegates to it.
# In any repo without a project hook of that name, exits 0 (no-op),
# so other projects are never blocked by another project's tracker.
#
# Usage: launcher.sh <hook-filename>
#   <hook-filename> is the leaf name in <repo>/.claude/hooks/, e.g.
#   `01-session-start-load-context.sh`.
#
# stdin from claude-code is forwarded verbatim to the project hook.

set -euo pipefail

leaf="${1:?launcher requires a hook leaf name}"
shift || true

# Find the repo root from cwd. If we're not in a repo, no-op.
repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$repo" ] || exit 0

hook="$repo/.claude/hooks/$leaf"
[ -x "$hook" ] || exit 0

exec "$hook" "$@"
