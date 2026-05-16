#!/usr/bin/env bash
# Global hook: block Bash commands that overwrite tracker / evidence /
# active-tracker files OUTSIDE the legitimate path (PreToolUse Edit/Write
# through 03-plan-tracker-edit-guard.sh).
#
# This closes the main remaining cheat vector: an agent can otherwise
# bypass anti-tamper by using a Bash heredoc / redirect / tee / sed -i
# to write a checkbox flip or fake evidence file without ever firing
# the Edit/Write/MultiEdit hook chain.
#
# Patterns blocked:
#   - `>  <tracker-or-evidence-path>` / `>> <path>` (truncate/append)
#   - `tee  <path>` / `tee -a <path>`
#   - `cat  ... > <path>` / `printf ... > <path>` / `echo ... > <path>`
#   - `sed -i ... <path>` (in-place rewrite)
#   - `cp <src> <path>` / `mv <src> <path>` (overwrite)
#   - `chmod 4?? <evidence>` (try to make file unwritable AFTER forging)
#
# Tracker/evidence path patterns (regex):
#   - .claude/active-tracker
#   - .claude/plans/.active-tracker (legacy)
#   - .evidence/.*plan.*\.md (phase0-plan.md, etc.)
#   - .checkpoints/.*evidence\.md
#   - .claude/evidence/.*\.md (sprint-2 review files)
#
# Bypass: pipe through PreToolUse Edit/Write/MultiEdit so the proper
# anti-cheat hook (03) runs. There is no `--ralph-override` for this
# file class - direct Bash writes are NEVER legitimate.
set -euo pipefail

INPUT="$(cat || true)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

[[ -n "$CMD" ]] || exit 0

# Path patterns that must not be written via Bash.
# 2026-05-12 added `\.checkpoints/[^[:space:]]*/skip-reason\.md` -
# skip-reason.md was a cheat vector: agent wrote it directly to fake
# user OVERRIDE-authored SKIPs. Only hook 02 (UserPromptSubmit) is
# allowed to create skip-reason.md.
PROTECTED_RE='(\.claude/active-tracker|\.claude/approval-refs\.allow|\.claude/plans/\.active-tracker|\.claude/\.allow-stop|\.claude/no-plan-mode|\.claude/\.ralph-loop-secret|\.evidence/[^[:space:]]*plan[^[:space:]]*\.(md|markdown)|\.checkpoints/[^[:space:]]*/evidence\.(md|markdown)|\.checkpoints/[^[:space:]]*/skip-reason\.(md|markdown)|\.checkpoints/[^[:space:]]*/\.skip-token|\.claude/evidence/[^[:space:]]*\.(md|markdown)|phase0-plan\.(md|markdown)|[^[:space:]]*-tracker\.(md|markdown)|\bWORKPLAN([_.-][A-Z0-9_.-]*)?\.(md|markdown)\b|\bHANDOFF([_.-][A-Z0-9_.-]*)?\.(md|markdown)\b|\bWORKP[*?][A-Z0-9*?_.-]*\.(md|markdown)\b|\bWORK[*?][A-Z0-9*?_.-]*\.(md|markdown)\b|\bHAND[*?][A-Z0-9*?_.-]*\.(md|markdown)\b|\bHANDO[*?][A-Z0-9*?_.-]*\.(md|markdown)\b|WORK[^[:space:]/A-Za-z]+PLAN\.(md|markdown)|HAND[^[:space:]/A-Za-z]+OFF\.(md|markdown)|WORK["'"'"'][[:space:]]*\+[[:space:]]*["'"'"']PLAN|HAND["'"'"'][[:space:]]*\+[[:space:]]*["'"'"']OFF)'

# Two-phase detection: (1) command references a protected path,
# (2) command contains any write-intent verb. If BOTH true → deny.
# Single regex per verb misses interpreter calls (python/node/perl/awk -i)
# that write the file без shell redirect.

if ! printf '%s' "$CMD" | grep -iqE "$PROTECTED_RE"; then
  exit 0
fi

# Phase 2: write-intent verbs. Anything that mutates files.
# Codex round 16 additions: git overwrite/delete subcommands, rsync,
# unzip -o (overwrite), tar with -O / --overwrite, scp inbound.
WRITE_INTENT_RE='(>>?|>\|)[[:space:]]*|'\
'\btee\b|'\
'\bsed[[:space:]]+-i\b|'\
'\bawk[[:space:]]+-i[[:space:]]+inplace\b|'\
'\bperl[[:space:]]+-p?i\b|'\
'\bperl[[:space:]]+-i\b|'\
'\b(python|pypy)[0-9.]*[[:space:]]+[^|]*-c[[:space:]]+["'\'']?[^|]*('\''w'\''|"w"|writeFileSync|\.write\(|os\.rename|os\.remove|os\.unlink|shutil\.copy|shutil\.move|shutil\.rmtree|Path\([^)]*\)\.write|Path\([^)]*\)\.unlink|open\([^,)]+,[[:space:]]*["'\'']wb?[+]?["'\''])|'\
'\b(node|nodejs)[[:space:]]+[^|]*(-e|--eval|-p|--print)[[:space:]]+["'\'']?[^|]*(writeFileSync|appendFileSync|copyFileSync|renameSync|unlinkSync|rmSync)|'\
'\b(deno|bun|ts-node|tsx)[[:space:]]+[^|]*(run|eval|--allow-write|--eval|-e)\b|'\
'\bruby[[:space:]]+[^|]*(-e|--eval)[[:space:]]+["'\'']?[^|]*(File\.(delete|unlink|rename|write|open)|FileUtils\.(rm|cp|mv)|IO\.write|\.write\b)|'\
'\bperl[[:space:]]+[^|]*-e[[:space:]]+["'\'']?[^|]*(unlink|rename|open[[:space:]]*[A-Z]?[[:space:]]*[,(][^,]*[[:space:]]*["'\'']?>|truncate)|'\
'\bphp[[:space:]]+[^|]*(-r|-f)[[:space:]]+["'\'']?[^|]*(unlink|rename|file_put_contents|fopen[^,]*,[[:space:]]*["'\'']w)|'\
'\b(lua|luajit)[[:space:]]+[^|]*(-e)[[:space:]]+["'\'']?[^|]*(os\.remove|os\.rename|io\.open[^,]*,[[:space:]]*["'\'']w)|'\
'\b(gawk|awk|nawk|mawk)[[:space:]]+[^|]*("|\x27)[^|"\x27]*(>|>>|print[^|]*>)|'\
'\btruncate\b|'\
'\bdd[[:space:]]+[^|;&]*\bof=|'\
'\b(cp|mv|install|ln)[[:space:]]+[^|;&]*[[:space:]]|'\
'\bchmod[[:space:]]+[047]{3,4}\b|'\
'\bchown\b|'\
'\bgit[[:space:]]+(checkout|restore|rm|mv|apply|reset[[:space:]]+--hard|stash[[:space:]]+(pop|apply)|clean[[:space:]]+-f[dx]*|am|filter-branch|filter-repo|replace)\b|'\
'\bgit-(filter-branch|filter-repo|checkout|restore|rm|mv|apply|reset|stash|clean|am|replace)\b|'\
'\brsync\b|'\
'\btouch\b|'\
'\bunzip[[:space:]]+[^|;&]*-o\b|'\
'\btar[[:space:]]+[^|;&]*(--overwrite|-x[^[:space:]]*f|--extract)|'\
'\bscp\b|'\
'\brm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^[:space:]|;&]+|'\
'\bfind[[:space:]]+[^|;&]*-delete\b|'\
'\bxargs[[:space:]]+[^|;&]*\b(rm|cp|mv)\b|'\
'\bmkfifo\b|'\
'\bmknod\b|'\
'\b(vim|vi|ex|nvim|view)[[:space:]]+[^|;&]*-(es|s)\b|'\
'\b(vim|vi|nvim|emacs|nano|ed)[[:space:]]+[^|;&]+|'\
'\bemacs[[:space:]]+[^|;&]*--batch\b|'\
'\bsponge\b'

if printf '%s' "$CMD" | grep -qE "$WRITE_INTENT_RE"; then
  # Special-case chmod: run-codex-review.sh sets RALPH_LEGIT_CHMOD=1
  # for the one legitimate write path. Without that marker, any chmod
  # on protected path is forgery prep.
  if printf '%s' "$CMD" | grep -iqE 'chmod[[:space:]]+[047]{3,4}[[:space:]]+[^|;&]*'"$PROTECTED_RE" \
     && [[ "${RALPH_LEGIT_CHMOD:-}" == "1" ]]; then
    exit 0
  fi
  echo "::error::guard-no-tracker-overwrite: Bash command references a tracker/evidence file AND uses a write-intent verb (redirect, tee, sed -i, awk -i inplace, perl -pi, python/node write, truncate, dd, cp, mv, install, ln, chmod, chown). Use Edit/Write tool so anti-cheat hook chain runs. Protected files: tracker/active-tracker, evidence.md (chmod 0444), phase0-plan.md, *-tracker.md. The only legitimate evidence producer is ~/.claude/hooks/run-codex-review.sh which sets RALPH_LEGIT_CHMOD=1." >&2
  exit 2
fi

exit 0
