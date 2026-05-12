#!/usr/bin/env bash
# UserPromptSubmit hook: injects communication rules into Claude context
# on every user message. Closes the gap where Claude drifts away from
# Russian + no-yo + short-hyphen rules across long sessions.
#
# Rules injected (subset of ~/.claude/CLAUDE.md "Глобальные правила работы"):
#   * Speak Russian unless user asks otherwise.
#   * Never use the Russian letter "yo".
#   * Use short hyphen "-", never the long em-dash.
#   * Avoid AI cliches and bureaucratic prose.
#
# Why a hook and not memory: SessionStart loads rules once, then they
# decay из контекста после compact / long thread. UserPromptSubmit fires
# every turn so the reminder is always at the top of the model's view.
#
# Exits 0 always; output goes to stdout where Claude Code reads it.

set -euo pipefail

cat <<'EOF'
COMMUNICATION RULES (injected by ~/.claude/hooks/inject-comm-rules.sh):
1. Russian language in chat. Code, commit messages, branch names - English.
2. No Russian letter "yo" anywhere (file content, comments, chat).
3. Short hyphen "-" only. Never em-dash.
4. No AI cliches ("Великолепно!", "С удовольствием помогу", etc).
5. No bureaucratic prose. Speak as engineer reporting to non-technical owner.
6. Final reports follow CLAUDE.md "Финальный отчет" structure: 6 sections, plain text.
EOF
