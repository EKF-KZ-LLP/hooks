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
│   ├── ralph-loop-enforce.sh       (PreToolUse Edit/Write/MultiEdit: TEC + Ralph Loop)
│   ├── ralph-loop-validate.py      (общий hard validator)
│   ├── run-codex-review-infra.sh   (helper: Codex review через Claude Code plugin runtime)
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
    │   ├── 08-plan-mode-to-tracker.sh
    │   ├── 09-task-start-rules-recheck.sh
    │   ├── 10-pre-edit-scope-guard.sh
    │   ├── 11-post-edit-tests-required.sh
    │   ├── 12-pre-checkbox-flip-deep-review.sh
    │   ├── 13-pre-stop-deploy-green-gate.sh
    │   └── 14-pre-commit-evidence-gate.sh
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

## Global hooks - что делает каждый

| Hook | Event | Назначение | Cheat vectors закрытые |
|------|-------|-----------|------------------------|
| `launcher.sh` | вспомогательный | Диспетчер. Принимает имя per-repo hook leaf, ищет в `$(git toplevel)/.claude/hooks/`, no-op если нет → repos без Ralph Loop не блокируются. | Per-repo opt-in вместо global force |
| `guard-no-secrets.sh` | PreToolUse Write\|Edit | Блок hardcoded ключей API/токенов/паролей в файлах | Plaintext secret в коммите |
| `guard-no-force-push.sh` | PreToolUse Bash | Блок force push на main/master: `--force`/`-f`, `+refspec:main`, `+refspec:refs/heads/main`, `--mirror`, `git update-ref refs/heads/main`, `git reset --hard main`, `git branch -d main` | Все известные force-paths включая refspec hacks |
| `guard-no-tracker-overwrite.sh` | PreToolUse Bash | Two-phase: (1) command references защищенный путь (`.claude/active-tracker`, `.evidence/*plan*.md`, `.checkpoints/*/evidence.md`, `.checkpoints/*/attempt-*.md`, `.checkpoints/*/pre-fix-failing-test.md`, `.checkpoints/*/*review*.md`, `.checkpoints/*/skip-reason.md`, `WORKPLAN.md`, `HANDOFF.md`); (2) command содержит write-intent verb. Оба условия дают deny. | Bash heredoc / interpreter writes обходящие Edit/Write hook chain |
| `enforce-iter-cap.sh` | PreToolUse Bash | (1) iter-commits > 3 на feature branch → deny без `--iter-cap-override`. (2) `gh pr merge --admin` (literal, $()-substituted, "quoted"-escaped) → deny без `--ralph-override`. (3) `gh api .../pulls/N/merge` или `gh api --method PUT` к merge-endpoint → deny без `--ralph-override` | Patch-forever loop + --admin server-side bypass + gh api endpoint bypass |
| `block-fatigue-excuses.sh` | PreToolUse Write\|Edit | Keyword guard для excuse phrases (LLM does not fatigue) в commits/reports | Bogus justification вместо real reason |
| `block-user-questions.sh` | PreToolUse Write\|Edit | Keyword guard fabricated "ask user" patterns | Сваливание решений когда есть ADR/план |
| `ralph-loop-enforce.sh` | PreToolUse Edit\|Write\|MultiEdit | Wrapper над `ralph-loop-validate.py`. Блокирует invalid Task Evidence Contract, stale evidence SHA, blocked/failed без Ralph Loop, source edit вне scope, code edit без pre-fix failing test evidence. | Markdown checkbox tamper, stale logs, fake blocked/failed, fake Codex evidence |
| `ralph-loop-validate.py` | helper | Общий валидатор для pretool, stop, precommit, validate-file. | Единый hard enforcement вместо разрозненных подсказок |
| `run-codex-review-infra.sh` | helper | Запускает Codex через Claude Code Codex plugin companion, пишет evidence с `Claude Code plugin`, `codex:rescue`, `codex:codex-rescue`, `full-code-path`, `Command`, `Result`, `Commit`. | `codex exec` и самописный review evidence больше не проходят strict validator |
| `gitnexus/gitnexus-hook.cjs` | PreToolUse Bash\|Grep\|Glob | На `grep/find/rg/fd`-команды показывает «есть граф знаний - читай GRAPH_REPORT.md» | Brute search vs indexed graph |

## Per-repo Ralph Loop hooks (`ralph-loop/`)

| Hook | Event | Назначение |
|------|-------|-----------|
| `01-session-start-load-context.sh` | SessionStart | Fail-closed без active tracker и checkbox-ов. Читает global rules + project CLAUDE.md + active tracker, пишет `<repo>/.claude/session-context-summary.md`. |
| `02-user-prompt-pending-tasks.sh` | UserPromptSubmit | Инжектит `[PENDING TASKS: N]` + first open + escape `OVERRIDE: skip task <slug>` |
| `03-plan-tracker-edit-guard.sh` | PreToolUse Edit\|Write | Anti-cheat: разрешает только `[ ] -> [x]` flip, не дает писать evidence/skip files напрямую, проверяет contract evidence block. |
| `04-gh-pr-merge-gate.sh` | PreToolUse Bash | `gh pr merge`, `glab mr merge`, direct API merge fail-closed без CI, approval, current-SHA review evidence и Codex/Senior verdict. |
| `05-stop-open-tasks-gate.sh` | Stop\|SubagentStop | Вызывает общий validator: DONE blocked при open required TASK-ID, blocked/failed без true blocker, stale WORKPLAN/HANDOFF, invalid evidence. |
| `06-gh-pr-create-title-gate.sh` | PreToolUse Bash | `gh pr create --title` fuzzy-match со slug задачи (SequenceMatcher ratio ≥ 0.8) |
| `07-gh-pr-create-iteration-gate.sh` | PreToolUse Bash | Iter-counter; ≥3 → forced SKIP path (skip-reason.md + `[x] [SKIP]`) |
| `08-plan-mode-to-tracker.sh` | PostToolUse ExitPlanMode | Fail-closed если план не найден, не в git repo, без checkbox-ов или без Task Evidence Contract. |
| `09-task-start-rules-recheck.sh` | UserPromptSubmit | `START TASK <slug>` перечитывает rules, AGENTS.md и task spec, а также валидирует active tracker. |
| `10-pre-edit-scope-guard.sh` | PreToolUse Edit\|Write\|MultiEdit | Блокирует source edits вне task spec scope. |
| `11-post-edit-tests-required.sh` | PostToolUse Edit\|Write\|MultiEdit | TDD warning layer; strict pre-fix failing test block живет в `ralph-loop-validate.py`. |
| `12-pre-checkbox-flip-deep-review.sh` | PreToolUse Edit | Проверяет deep-review sections перед checkbox close. |
| `13-pre-stop-deploy-green-gate.sh` | Stop\|SubagentStop | Opt-in deploy green gate. |
| `14-pre-commit-evidence-gate.sh` | PreToolUse Bash | Блокирует `git commit`, если tracker evidence или WORKPLAN/HANDOFF stale. |

## Task Evidence Contract

Каждый checkbox в active plan должен иметь такой вид:

```md
- [ ] TASK-001: <task title>
  - type: discovery | code | test | review | docs | ci | adr | safety | other
  - required: true | false
  - scope:
  - source_of_truth:
  - success_criteria:
  - verification:
  - evidence:
  - result:
  - commit:
  - status: planned | in_progress | verified | blocked | failed | done | waived
```

Hard rules:
- `TASK-ID` уникален.
- Свободные checkbox-ы без metadata блокируются.
- `[x]` валиден только при `status: done` или `status: waived`.
- Evidence должен жить под `.checkpoints/<TASK-ID>/`, существовать, быть непустым и иметь `Command`, `Result`, `Commit`.
- Для git repo evidence SHA должен совпадать с текущим `HEAD`, кроме явно помеченного `pre-fix` или `pre-review` evidence.
- Review evidence должен быть `full-code-path`, не `diff-only`.
- Codex evidence валиден только с маркерами `Claude Code plugin`, `codex:rescue`, `codex:codex-rescue`.
- `waived` требует `reason`, `risk`, `owner`, `tracker`.

## Ralph Loop Hook Requirement

Blocked/failed/DONE проходит только если hook-и видят machine-readable attempt log в `HANDOFF.md`:

```md
- attempt: <number>
  task_id: TASK-001
  trigger: test_failed | ci_failed | review_failed | codex_failed | blocked_requested | done_blocked | other
  hypothesis:
  action:
  command_or_artifact:
  result:
  next_decision: retry | strategy_shift | consult_senior | consult_codex | search_docs | ask_user | blocked
  evidence:
  commit:
  timestamp:
```

Hard rules:
- docs/adr/config tasks need at least 2 meaningful attempts before blocked/failed.
- normal code/test/review tasks need at least 3 attempts.
- duplicate hypothesis blocks.
- second failure requires strategy shift.
- blocked/failed requires repo/docs/tests/git/logs usage in attempt history.
- external/tooling/library/API blockers require internet/Context7/official docs search evidence.
- stuck tasks require Senior Engineer or Codex via `codex:rescue`.
- generic blockers like "тесты падают", "не получилось", "ошибка" are blocked.

## Per-repo PSA-style Ralph Loop (`psa-style-ralph/`)

Альтернативная версия - flatter naming, fewer files. Используй если не хочешь 8 нумерованных скриптов.

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
| `assertion-change-guard.sh` | PostToolUse Edit `*_test.go` | Go тесты: assert изменен без production change → fail |
| `test-data-guard.sh` | PostToolUse Edit `*_test.go` | Go тесты: блок правки fixture без justification |
| `test-quality-gate.sh` | PostToolUse Edit/Write `*_test.{go,py,ts,tsx}` | Multi-lang: trivial assert / empty body / mock-only → fail |
| `destructive-sql-guard.sh` | PreToolUse Bash | Любой репо с PG/CH/MySQL: DROP/TRUNCATE через psql/clickhouse-client → deny |
| `graphify-hint.sh` | PreToolUse Bash | Если есть graphify knowledge graph: hint на GRAPH_REPORT.md |
| `validate-issue-close.sh` | вспомогательный | Pre-flight для `gh issue close <num>` |

---

## Установка в новый проект

См. `SETUP-PROMPT.md` - готовый prompt для Claude Code.
