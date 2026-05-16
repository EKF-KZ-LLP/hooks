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
├── .github/workflows/ci.yml         (server CI: syntax + negative enforcement tests)
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
│   ├── record-pre-fix-failing-test.sh (helper: пишет легальный pre-fix FAIL evidence)
│   ├── run-codex-review-infra.sh   (helper: Codex review через Claude Code plugin runtime)
│   └── gitnexus/
│       └── gitnexus-hook.cjs       (PreToolUse Bash/Grep/Glob: подсказка про knowledge graph)
├── shared/
│   └── agent-hooks/                ← в ~/.local/share/agent-hooks/
│       ├── plan-tracker-edit-guard.py
│       ├── 03-plan-tracker-edit-guard.sh
│       ├── policy-runner.js
│       ├── codex-plan-guard.js
│       ├── claude-mem-*.js|*.sh
│       └── *.test.*                (runtime tests for shared hooks/patchers)
├── git-hooks/                      ← optional native Git hooks copied to <repo>/.githooks/
│   ├── pre-commit                  (validator precommit)
│   └── pre-push                    (main/master direct push block + tracker stop gate if active)
├── scripts/
│   └── install-hooks-source.sh     (copy global/shared/per-repo hooks into target repo)
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
    │   ├── 14-pre-commit-evidence-gate.sh
    │   └── 15-post-verification-failure-gate.sh
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
| `guard-no-force-push.sh` | PreToolUse Bash | Блок direct push на main/master, `git --no-verify`, force push на main/master: `--force`/`-f`, `+refspec:main`, `+refspec:refs/heads/main`, `--all`, `--mirror`, `git update-ref refs/heads/main`, `git reset --hard main`, `git branch -d main` | Bypass локальных hooks, прямой push без PR, force-paths включая refspec hacks |
| `guard-no-tracker-overwrite.sh` | PreToolUse Bash | Two-phase: (1) command references защищенный путь (`.claude/active-tracker`, `.evidence/*plan*.md`, `.checkpoints/*/evidence.md`, `.checkpoints/*/attempt-*.md`, `.checkpoints/*/pre-fix-failing-test.md`, `.checkpoints/*/*review*.md`, `.checkpoints/*/skip-reason.md`, `WORKPLAN.md`, `HANDOFF.md`); (2) command содержит write-intent verb. Оба условия дают deny. | Bash heredoc / interpreter writes обходящие Edit/Write hook chain |
| `enforce-iter-cap.sh` | PreToolUse Bash | (1) iter-commits > 3 на feature branch → deny без `--iter-cap-override`. (2) `gh pr merge --admin` (literal, $()-substituted, "quoted"-escaped) → deny без `--ralph-override`. (3) `gh api .../pulls/N/merge` или `gh api --method PUT` к merge-endpoint → deny без `--ralph-override` | Patch-forever loop + --admin server-side bypass + gh api endpoint bypass |
| `block-fatigue-excuses.sh` | PreToolUse Write\|Edit | Keyword guard для excuse phrases (LLM does not fatigue) в commits/reports | Bogus justification вместо real reason |
| `block-user-questions.sh` | PreToolUse Write\|Edit | Keyword guard fabricated "ask user" patterns | Сваливание решений когда есть ADR/план |
| `ralph-loop-enforce.sh` | PreToolUse Edit\|Write\|MultiEdit | Wrapper над `ralph-loop-validate.py`. Блокирует invalid Task Evidence Contract, stale evidence SHA, blocked/failed без Ralph Loop, source edit вне scope, code edit без pre-fix failing test evidence. | Markdown checkbox tamper, stale logs, fake blocked/failed, fake Codex evidence |
| `ralph-loop-validate.py` | helper | Общий валидатор для pretool, stop, precommit, validate-file. | Единый hard enforcement вместо разрозненных подсказок |
| `record-pre-fix-failing-test.sh` | helper | Запускает test command и пишет `.checkpoints/<TASK-ID>/pre-fix-failing-test.md` только если команда реально упала. | Самописный pre-fix evidence без FAIL |
| `run-codex-review-infra.sh` | helper | Запускает Codex через Claude Code Codex plugin companion, пишет evidence с `Claude Code plugin`, `codex:rescue`, `codex:codex-rescue`, `full-code-path`, `Command`, `Result`, `Commit`. | `codex exec` и самописный review evidence больше не проходят strict validator |
| `gitnexus/gitnexus-hook.cjs` | PreToolUse Bash\|Grep\|Glob | На `grep/find/rg/fd`-команды показывает «есть граф знаний - читай GRAPH_REPORT.md» | Brute search vs indexed graph |

## Shared agent hooks (`shared/agent-hooks/`)

Эта папка синхронизируется в `~/.local/share/agent-hooks/`.
В ней лежат shared runners, которые не должны копироваться отдельно в каждый
проект:

- `plan-tracker-edit-guard.py` - canonical implementation для hook 03.
- `03-plan-tracker-edit-guard.sh` - runtime wrapper.
- `policy-runner.js`, `codex-plan-guard.js` - Codex/Claude policy helpers.
- `claude-mem-*`, `patch-*` - local Claude-Mem/GitNexus/Codex maintenance hooks.
- `*.test.*` - regression tests for shared runtime.

Per-repo `03-plan-tracker-edit-guard.sh` является тонким wrapper-ом на
`/Users/antonsahovskii/.local/share/agent-hooks/plan-tracker-edit-guard.py`.
Поэтому при установке нового проекта нужно копировать не только `per-repo/`,
но и `shared/agent-hooks/`.

## Native Git hooks (`git-hooks/`)

Эти hooks нужны как защита вне Claude Code:

- `pre-commit` запускает `ralph-loop-validate.py precommit`, если validator есть.
- `pre-push` всегда блокирует direct push из `main/master` и push в
  `refs/heads/main|master`. Ralph Stop gate запускается только если в проекте
  есть `.claude/active-tracker`; проекты без tracker не получают ложный block.

## Layering policy

- P0 always-on: secrets, destructive shell/git/database commands, direct
  main/master push, `git --no-verify`, direct tracker/evidence writes and unsafe
  PR/MR merge.
- P1 opt-in per project: active tracker workflow, Stop gate, test/TDD evidence
  gates and Codex review gate. These are installed only in projects that opt in
  with `.claude/active-tracker` or copied project hooks.
- P2 advisory: reminders, Serena/GitNexus nudges and latency telemetry. These
  must not create hard-stop loops.

## Per-repo Ralph Loop hooks (`ralph-loop/`)

| Hook | Event | Назначение |
|------|-------|-----------|
| `01-session-start-load-context.sh` | SessionStart | Fail-closed без active tracker и checkbox-ов. Читает global rules + project CLAUDE.md + active tracker, пишет `<repo>/.claude/session-context-summary.md`. |
| `02-user-prompt-pending-tasks.sh` | UserPromptSubmit | Инжектит `[PENDING TASKS: N]` + first open + escape `OVERRIDE: skip task <slug>` |
| `03-plan-tracker-edit-guard.sh` | PreToolUse Edit\|Write | Anti-cheat: разрешает `[ ] -> [x]` только с `Verdict: PASS`, `in_progress -> failed` только с открытым checkbox и `Verdict: FAIL`, reopen `done/verified/failed -> planned/in_progress`, не дает писать evidence/skip files напрямую, проверяет contract evidence block. |
| `04-gh-pr-merge-gate.sh` | PreToolUse Bash | `gh pr merge`, `glab mr merge`, direct API merge fail-closed без CI, CodeQL и current-SHA Codex review evidence. GitHub human review только informational, потому что бизнес-заказчик не code reviewer. |
| `05-stop-open-tasks-gate.sh` | Stop\|SubagentStop | Default Stop с open required TASK-ID не блокирует, а дает notice, чтобы не было overnight loop. Hard block включается при `RALPH_STOP_STRICT=1` или явном completion claim в transcript; тогда общий validator блокирует open tasks, blocked/failed без true blocker, stale WORKPLAN/HANDOFF и invalid evidence. |
| `06-gh-pr-create-title-gate.sh` | PreToolUse Bash | `gh pr create --title` fuzzy-match со slug задачи (SequenceMatcher ratio ≥ 0.8) |
| `07-gh-pr-create-iteration-gate.sh` | PreToolUse Bash | Iter-counter; ≥3 → forced SKIP path (skip-reason.md + `[x] [SKIP]`) |
| `08-plan-mode-to-tracker.sh` | PostToolUse ExitPlanMode | Fail-closed если план не найден, не в git repo, без checkbox-ов или без Task Evidence Contract. |
| `09-task-start-rules-recheck.sh` | UserPromptSubmit | `START TASK <slug>` перечитывает rules, AGENTS.md и task spec, а также валидирует active tracker. |
| `10-pre-edit-scope-guard.sh` | PreToolUse Edit\|Write\|MultiEdit | Блокирует source edits вне task spec scope. |
| `11-post-edit-tests-required.sh` | PostToolUse Edit\|Write\|MultiEdit | TDD warning layer; strict pre-fix failing test block живет в `ralph-loop-validate.py`. |
| `12-pre-checkbox-flip-deep-review.sh` | PreToolUse Edit | Проверяет deep-review sections перед checkbox close. |
| `13-pre-stop-deploy-green-gate.sh` | Stop\|SubagentStop | Opt-in deploy green gate. |
| `14-pre-commit-evidence-gate.sh` | PreToolUse Bash | Блокирует `git commit`, если tracker evidence или WORKPLAN/HANDOFF stale. При нескольких `in_progress` выбирает задачу по staged files и `scope`; если scope неоднозначен - блокирует с понятным сообщением. |
| `15-post-verification-failure-gate.sh` | PostToolUse Bash | После failed tests/lint/typecheck/CI/review/Codex требует свежий attempt в `HANDOFF.md` с evidence. |

## GitHub CI

`.github/workflows/ci.yml` запускает те же enforcement checks на сервере:

- Python compile для `global/ralph-loop-validate.py`.
- Bash syntax для всех hook/test shell files.
- `git diff --check`.
- Scan на запрещенные символы.
- `tests/negative-ralph-loop-enforcement.sh`.
- `tests/stop-open-tasks-gate.sh`.

CodeQL может быть включен GitHub default setup. Merge hook не считает локальный лог достаточным: для PR merge он сверяет GitHub required checks, CodeQL status, reviewDecision и PR HEAD SHA.

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
- failed verification commands trigger hook 15 and block next progress until `HANDOFF.md` has a fresh attempt entry.
- behavior-changing code edits require `.checkpoints/<TASK-ID>/pre-fix-failing-test.md`, produced by `record-pre-fix-failing-test.sh TASK-001 -- <test command>`.

## Per-repo PSA-style Ralph Loop (`psa-style-ralph/`)

Альтернативная версия - flatter naming, fewer files. Используй если не хочешь 8 нумерованных скриптов.

| Hook | Event | Назначение |
|------|-------|-----------|
| `session-start.sh` | SessionStart | Инжектит rules + plan + пишет run-epoch baseline в TMPDIR |
| `user-prompt-submit.sh` | UserPromptSubmit | `[PENDING: N]` header + OVERRIDE: skip → `[~]` с audit comment |
| `pre-tool-use.sh` | PreToolUse Edit\|Write\|MultiEdit\|ExitPlanMode | 4-в-одном: flip guard + plan-location guard + evidence anti-tamper + ExitPlanMode auto-capture в `.evidence/plans/exitplanmode-<ts>.md` |
| `stop.sh` | Stop | PSA-style вариант: блок exit пока `[ ]`. Escape: `WAIVE:` в last commit |

## Optional guards (`optional-guards/`)

Подключай только если guard подходит стеку проекта. Optional не значит слабый:
если guard подключен, его blocking cases должны давать non-zero exit или
Claude `deny`.

| Hook | Event | Подключать когда | Что блокирует или делает | Проверка |
|------|-------|------------------|--------------------------|----------|
| `assertion-change-guard.sh` | PostToolUse Edit `*_test.go`, `*_test.py`, `*.test.ts`, `*.spec.ts` | Есть unit/integration tests и важен запрет "подкрутить assert под код" | Блокирует assertion-only test change без production/source change в той же git slice | `tests/optional-guards-enforcement.sh`: `assertion-only test change` |
| `test-data-guard.sh` | PostToolUse Edit fixtures/snapshots/golden/testdata | Есть fixtures, snapshots, golden files, testdata | Блокирует fixture + assertion change без production/source change | `tests/optional-guards-enforcement.sh`: `fixture plus assertion without production` |
| `test-quality-gate.sh` | PostToolUse Edit/Write `*_test.go`, `test_*.py`, `*_test.py`, `*.test.ts(x)`, `*.spec.ts(x)` | Есть Go/Python/TS тесты | Блокирует trivial assert, empty body, skip без issue, TS/Python mock-only. Go mock-only пока warning из-за AST ambiguity | `tests/optional-guards-enforcement.sh`: `trivial Python assertion`, `skip without issue ticket` |
| `destructive-sql-guard.sh` | PreToolUse Bash | Есть PG, ClickHouse, MySQL, migration scripts или prod-like DB доступ | Deny для `DROP DATABASE/SCHEMA/TABLE`, `TRUNCATE`, `DELETE FROM`, `ALTER TABLE ... DROP COLUMN` в shell command | `tests/optional-guards-enforcement.sh`: `destructive SQL delete`, `destructive SQL truncate` |
| `graphify-hint.sh` | PreToolUse Bash search commands | В repo есть `graphify-out/graph.json` или `graphify-out/GRAPH_REPORT.md` | Не блокирует. Добавляет `additionalContext`, что перед raw search нужно смотреть graph report | `tests/optional-guards-enforcement.sh`: `graphify additionalContext` |
| `validate-issue-close.sh` | Helper before `gh issue close <num>` | Проект ведет GitHub Issues с Definition of Done checkboxes | Блокирует закрытие issue с незакрытыми DoD checkbox-ами или без `✅` markers в комментариях | `tests/optional-guards-enforcement.sh`: `issue close with unchecked DoD` |

---

## Установка в новый проект

Автоматический путь:

```bash
/Users/antonsahovskii/Dev/Hooks/scripts/install-hooks-source.sh --project /path/to/repo --with-git-hooks
```

Ручной путь: см. `SETUP-PROMPT.md` - готовый prompt для Claude Code.
