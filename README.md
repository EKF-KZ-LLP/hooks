# Hooks library

Канонический склад hooks для Claude Code Ralph Loop discipline.
Структура: `global/` (живут в `~/.claude/hooks/`), `per-repo/*` (живут в `<repo>/.claude/hooks/`).

Источник правды: `/Users/antonsahovskii/Dev/Hooks/`. Любой другой проект копирует ОТСЮДА, не из активных репо (там могут быть локальные мутации).

---

## Структура

```
/Users/antonsahovskii/Dev/Hooks/
├── README.md
├── SETUP-PROMPT.md                 ← скормить Claude Code в новом проекте
├── global/                         ← в ~/.claude/hooks/ или alt-home
│   ├── launcher.sh                 (диспетчер per-repo hooks)
│   ├── guard-no-secrets.sh         (PreToolUse Write/Edit)
│   ├── guard-no-force-push.sh      (PreToolUse Bash: force / refspec / mirror / update-ref)
│   ├── guard-no-tracker-overwrite.sh (PreToolUse Bash: блок Bash-writes в tracker/evidence)
│   ├── enforce-iter-cap.sh         (PreToolUse Bash: iter > 3 + --admin + gh api merge)
│   ├── block-fatigue-excuses.sh    (PreToolUse Write/Edit: keyword guard)
│   ├── block-user-questions.sh     (PreToolUse Write/Edit: keyword guard)
│   ├── run-codex-review-infra.sh   (helper: Codex review для infra без PR)
│   └── gitnexus/
│       └── gitnexus-hook.cjs       (PreToolUse Bash/Grep/Glob: подсказка про knowledge graph)
└── per-repo/
    ├── ralph-loop/                 ← каноническая Ralph Loop версия (VCM)
    │   ├── 01-session-start-load-context.sh
    │   ├── 02-user-prompt-pending-tasks.sh
    │   ├── 03-plan-tracker-edit-guard.sh
    │   ├── 04-gh-pr-merge-gate.sh
    │   ├── 05-stop-open-tasks-gate.sh
    │   ├── 06-gh-pr-create-title-gate.sh
    │   ├── 07-gh-pr-create-iteration-gate.sh
    │   └── 08-plan-mode-to-tracker.sh
    ├── psa-style-ralph/            ← альтернативная Ralph Loop (PSA, другие имена)
    │   ├── session-start.sh
    │   ├── user-prompt-submit.sh
    │   ├── pre-tool-use.sh
    │   └── stop.sh
    └── optional-guards/            ← дополнительные guard скрипты (тест-/SQL-/grep-discipline)
        ├── assertion-change-guard.sh
        ├── test-data-guard.sh
        ├── test-quality-gate.sh
        ├── destructive-sql-guard.sh
        ├── graphify-hint.sh
        └── validate-issue-close.sh
```

---

## Global hooks — что делает каждый

| Hook | Event | Назначение | Cheat vectors закрытые |
|------|-------|-----------|------------------------|
| `launcher.sh` | вспомогательный | Диспетчер. Принимает имя per-repo hook leaf, ищет в `$(git toplevel)/.claude/hooks/`, no-op если нет → repos без Ralph Loop не блокируются. | Per-repo opt-in вместо global force |
| `guard-no-secrets.sh` | PreToolUse Write\|Edit | Блок hardcoded ключей API/токенов/паролей в файлах | Plaintext secret в коммите |
| `guard-no-force-push.sh` | PreToolUse Bash | Блок force push на main/master: `--force`/`-f`, `+refspec:main`, `+refspec:refs/heads/main`, `--mirror`, `git update-ref refs/heads/main`, `git reset --hard main`, `git branch -d main` | Все известные force-paths включая refspec hacks |
| `guard-no-tracker-overwrite.sh` | PreToolUse Bash | Two-phase: (1) command references защищённый путь (`.claude/active-tracker`, `.evidence/*plan*.md`, `.checkpoints/*/evidence.md`, `phase0-plan.md`, `*-tracker.md`); (2) command содержит write-intent verb (redirect, tee, sed -i, awk -i inplace, perl -pi, python -c write, node -e writeFileSync, truncate, dd of=, cp, mv, install, ln, chmod без `RALPH_LEGIT_CHMOD=1`). Оба → deny | Bash heredoc / interpreter writes обходящие 03-plan-tracker-edit-guard |
| `enforce-iter-cap.sh` | PreToolUse Bash | (1) iter-commits > 3 на feature branch → deny без `--iter-cap-override`. (2) `gh pr merge --admin` (literal, $()-substituted, "quoted"-escaped) → deny без `--ralph-override`. (3) `gh api .../pulls/N/merge` или `gh api --method PUT` к merge-endpoint → deny без `--ralph-override` | Patch-forever loop + --admin server-side bypass + gh api endpoint bypass |
| `block-fatigue-excuses.sh` | PreToolUse Write\|Edit | Keyword guard для excuse phrases (LLM does not fatigue) в commits/reports | Bogus justification вместо real reason |
| `block-user-questions.sh` | PreToolUse Write\|Edit | Keyword guard fabricated "ask user" patterns | Сваливание решений когда есть ADR/план |
| `run-codex-review-infra.sh` | helper | Запускает `codex exec` против infra-файлов с строгим review prompt; пишет evidence ТОЛЬКО на `Verdict: PASS` | Forged evidence без Codex review |
| `gitnexus/gitnexus-hook.cjs` | PreToolUse Bash\|Grep\|Glob | На `grep/find/rg/fd`-команды показывает «есть граф знаний — читай GRAPH_REPORT.md» | Brute search vs indexed graph |

## Per-repo Ralph Loop hooks (`ralph-loop/`)

| Hook | Event | Назначение |
|------|-------|-----------|
| `01-session-start-load-context.sh` | SessionStart | Читает global rules + project CLAUDE.md + active tracker → пишет `<repo>/.claude/session-context-summary.md` для инжекции UserPromptSubmit |
| `02-user-prompt-pending-tasks.sh` | UserPromptSubmit | Инжектит `[PENDING TASKS: N]` + first open + escape `OVERRIDE: skip task <slug>` |
| `03-plan-tracker-edit-guard.sh` | PreToolUse Edit\|Write | Anti-cheat: разрешает только `[ ]→[x]` flip, total checkbox count не уменьшается, требует evidence.md с `Verdict: PASS` + chmod 0444 + mtime ≥ run-epoch |
| `04-gh-pr-merge-gate.sh` | PreToolUse Bash | `gh pr merge` блок без evidence или Codex APPROVED note |
| `05-stop-open-tasks-gate.sh` | Stop\|SubagentStop | Отказывается завершить сессию пока есть `[ ]`. Escape: `touch <repo>/.claude/.allow-stop` |
| `06-gh-pr-create-title-gate.sh` | PreToolUse Bash | `gh pr create --title` fuzzy-match со slug задачи (SequenceMatcher ratio ≥ 0.8) |
| `07-gh-pr-create-iteration-gate.sh` | PreToolUse Bash | Iter-counter; ≥3 → forced SKIP path (skip-reason.md + `[x] [SKIP]`) |
| `08-plan-mode-to-tracker.sh` | PostToolUse ExitPlanMode | Подхватывает plan-mode plan, регистрирует как `<repo>/.claude/active-tracker`. Refuse если 0 чекбоксов |

## Per-repo PSA-style Ralph Loop (`psa-style-ralph/`)

Альтернативная версия — flatter naming, fewer files. Используй если не хочешь 8 нумерованных скриптов.

| Hook | Event | Назначение |
|------|-------|-----------|
| `session-start.sh` | SessionStart | Инжектит rules + plan + пишет run-epoch baseline в TMPDIR |
| `user-prompt-submit.sh` | UserPromptSubmit | `[PENDING: N]` header + OVERRIDE: skip → `[~]` с audit comment |
| `pre-tool-use.sh` | PreToolUse Edit\|Write\|MultiEdit\|ExitPlanMode | 4-в-одном: flip guard + plan-location guard + evidence anti-tamper + ExitPlanMode auto-capture в `.evidence/plans/exitplanmode-<ts>.md` |
| `stop.sh` | Stop | Блок exit пока `[ ]`. Escape: `WAIVE:` в last commit |

## Optional guards (`optional-guards/`)

Подключай только если применимо к стеку проекта.

| Hook | Event | Где нужен |
|------|-------|-----------|
| `assertion-change-guard.sh` | PostToolUse Edit `*_test.go` | Go тесты: assert изменён без production change → fail |
| `test-data-guard.sh` | PostToolUse Edit `*_test.go` | Go тесты: блок правки fixture без justification |
| `test-quality-gate.sh` | PostToolUse Edit/Write `*_test.{go,py,ts,tsx}` | Multi-lang: trivial assert / empty body / mock-only → fail |
| `destructive-sql-guard.sh` | PreToolUse Bash | Любой репо с PG/CH/MySQL: DROP/TRUNCATE через psql/clickhouse-client → deny |
| `graphify-hint.sh` | PreToolUse Bash | Если есть graphify knowledge graph: hint на GRAPH_REPORT.md |
| `validate-issue-close.sh` | вспомогательный | Pre-flight для `gh issue close <num>` |

---

## Установка в новый проект

См. `SETUP-PROMPT.md` — готовый prompt для Claude Code.
