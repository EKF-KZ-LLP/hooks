#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/install-hooks-source.sh --project <repo> [--claude-home <dir>] [--with-git-hooks]

Copies canonical hook source into one project:
  - global hooks -> <claude-home>/hooks
  - shared agent hooks -> ~/.local/share/agent-hooks
  - Ralph Loop per-repo hooks -> <repo>/.claude/hooks
  - optional native git hooks when --with-git-hooks is set

This installer does not create .claude/active-tracker. Repos without tracker keep
Stop gates inactive unless their settings wire 05 explicitly.
EOF
}

project=""
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
with_git_hooks=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      project="${2:-}"
      shift 2
      ;;
    --claude-home)
      claude_home="${2:-}"
      shift 2
      ;;
    --with-git-hooks)
      with_git_hooks=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$project" ] || { usage; exit 2; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
project=$(cd "$project" && pwd -P)

mkdir -p "$claude_home/hooks" "$HOME/.local/share/agent-hooks" "$project/.claude/hooks"

rsync -a "$root/global/" "$claude_home/hooks/"
rsync -a "$root/shared/agent-hooks/" "$HOME/.local/share/agent-hooks/"
rsync -a "$root/per-repo/ralph-loop/" "$project/.claude/hooks/"

find "$claude_home/hooks" "$HOME/.local/share/agent-hooks" "$project/.claude/hooks" -type f -name '*.sh' -exec chmod 0755 {} +
find "$claude_home/hooks" "$HOME/.local/share/agent-hooks" "$project/.claude/hooks" -type f -name '*.py' -exec chmod 0644 {} +
find "$HOME/.local/share/agent-hooks" -type f -name '*.js' -exec chmod 0644 {} +
find "$HOME/.local/share/agent-hooks" -type f -name '*.mjs' -exec chmod 0644 {} +

if [ "$with_git_hooks" = "1" ]; then
  mkdir -p "$project/.githooks"
  rsync -a "$root/git-hooks/" "$project/.githooks/"
  find "$project/.githooks" -type f -exec chmod 0755 {} +
  git -C "$project" config core.hooksPath .githooks
fi

echo "Installed hooks from $root into $project"
