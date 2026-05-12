#!/usr/bin/env bash
# Global hook: block force push and destructive git commands

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Explicit approval token for destructive local operations. This is not
# accepted for force-push to main/master; those stay hard blocked below.
has_approval=0
if echo "$COMMAND" | grep -qE -- '--destructive-approved|RALPH_DESTRUCTIVE_APPROVED=1'; then
    has_approval=1
fi

# Block broad local destructive operations unless the user/operator made
# approval explicit in the command.
if [ "$has_approval" -ne 1 ] && echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])rm[[:space:]]+-[A-Za-z]*r[fA-Za-z]*[[:space:]]+(\.|/|\*|\$PWD|\$\{PWD\}|[^|;&]*(/|^)(global|per-repo|templates|tests|src|app|lib|packages|services)(/|[[:space:]]|$))'; then
    echo "BLOCKED: destructive rm requires explicit approval marker --destructive-approved." >&2
    exit 2
fi
if [ "$has_approval" -ne 1 ] && echo "$COMMAND" | grep -qE 'git[[:space:]]+(clean[[:space:]]+-f[dx]*|reset[[:space:]]+--hard|checkout[[:space:]]+--[[:space:]]+\.|restore[[:space:]].*--source|filter-branch|filter-repo)'; then
    echo "BLOCKED: destructive git command requires explicit approval marker --destructive-approved." >&2
    exit 2
fi
if [ "$has_approval" -ne 1 ] && echo "$COMMAND" | grep -qiE '\b(psql|mysql|clickhouse-client)\b[^|;&]*\b(drop[[:space:]]+(table|database|schema)|truncate[[:space:]]+table|delete[[:space:]]+from[[:space:]]+[A-Za-z0-9_."]+[[:space:]]*($|;))'; then
    echo "BLOCKED: destructive database command requires explicit approval marker --destructive-approved." >&2
    exit 2
fi

# Allow --force-with-lease (safe: rejects if remote changed)
if echo "$COMMAND" | grep -qE 'git\s+push.*--force-with-lease'; then
    exit 0
fi

# Block force push to main/master only (not feature/test branches)
if echo "$COMMAND" | grep -qE 'git\s+push.*--force|git\s+push.*-f\b'; then
    if echo "$COMMAND" | grep -qE '\s(main|master)\b'; then
        echo "BLOCKED: Force push to main/master is not allowed." >&2
        exit 2
    fi
fi

# Block refspec force push to main/master (`git push origin +HEAD:main`,
# `+local:remote`, `+HEAD:refs/heads/main`). Plus-prefixed refspec is
# functionally identical to `git push --force`. Closes a cheat vector
# the --force/-f rule missed.
if echo "$COMMAND" | grep -qE 'git\s+push[^|;&]*\+[A-Za-z0-9/._@~^-]+:(refs/heads/)?(main|master)\b'; then
    echo "BLOCKED: Refspec force push to main/master (\`+<src>:main\` or \`+<src>:refs/heads/main\` is force). Use --force-with-lease against a feature branch." >&2
    exit 2
fi

# Block --mirror push to main/master remote (mirrors entire ref-space
# including main, which is implicit force).
if echo "$COMMAND" | grep -qE 'git\s+push\s+--mirror\b'; then
    echo "BLOCKED: 'git push --mirror' rewrites all remote refs including main/master. Not allowed." >&2
    exit 2
fi

# Block update-ref / push that uses raw ref path on main.
if echo "$COMMAND" | grep -qE 'git\s+update-ref\s+(-d\s+)?refs/heads/(main|master)\b'; then
    echo "BLOCKED: 'git update-ref' on main/master ref directly. Not allowed." >&2
    exit 2
fi

# Block destructive reset on main
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard.*(main|master)\b'; then
    echo "BLOCKED: Hard reset on main/master. This destroys history." >&2
    exit 2
fi

# Block branch deletion of main
if echo "$COMMAND" | grep -qE 'git\s+branch\s+-[dD]\s+(main|master)'; then
    echo "BLOCKED: Cannot delete main/master branch." >&2
    exit 2
fi

exit 0
