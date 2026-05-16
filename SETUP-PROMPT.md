# Ralph Loop hooks - setup prompt для Claude Code

Скопируй блок ниже в первое сообщение Claude Code в новом репо.
Claude разложит файлы, прогонит smoke, проведет ревизию существующих
hooks и удалит дубли.

---

```
Задача: установить Ralph Loop hook discipline в этом репо.
Источник правды: /Users/antonsahovskii/Dev/Hooks/

ЭТАП 0 - РЕВИЗИЯ (обязательно перед копированием)
1. Прочитай README.md в /Users/antonsahovskii/Dev/Hooks/ чтобы понять
   что делает каждый hook.
2. Перечисли существующие hooks в:
   - $CLAUDE_CONFIG_DIR/hooks/ (или ~/.claude/hooks/ если переменная не
     задана). Это global home.
   - <repo>/.claude/hooks/ - per-repo.
3. Для каждого существующего файла сравни SHA256 с эталоном в
   /Users/antonsahovskii/Dev/Hooks/{global,per-repo/*}/. Если файл
   совпадает - skip копирование. Если отличается - сохрани backup
   с суффиксом .bak-<timestamp> и перепиши из источника.
4. Удаляй ТОЛЬКО файлы которые:
   - не присутствуют в /Users/antonsahovskii/Dev/Hooks/
   - И не названы в hooks block <claude-home>/settings.json
   Любой удаляемый файл сначала бэкап -> backups/<timestamp>/.
   Никогда не удаляй без user opt-in если файл exec-bit + не пустой
   + содержит "BLOCKED" или "::error::" токены - это активный guard,
   спросить пользователя.

ЭТАП 1 - GLOBAL HOOKS
5. Создай (если нет) $CLAUDE_CONFIG_DIR/hooks/ (fallback ~/.claude/hooks/).
6. Скопируй ВСЕ из /Users/antonsahovskii/Dev/Hooks/global/ включая
   gitnexus/ подпапку. chmod +x на каждый .sh.
7. Скопируй shared runtime:
   /Users/antonsahovskii/Dev/Hooks/shared/agent-hooks/ ->
   ~/.local/share/agent-hooks/
   chmod +x на `*.sh`; `*.py`, `*.js`, `*.mjs` оставь readable.
   Это обязательно: per-repo hook 03 является wrapper-ом на
   ~/.local/share/agent-hooks/plan-tracker-edit-guard.py.
8. Открой $CLAUDE_CONFIG_DIR/settings.json (fallback ~/.claude/settings.json).
   Образец hooks block - /Users/antonsahovskii/.claude/settings.json
   ключ "hooks". Скопируй его 1-в-1. Все пути в командах должны
   указывать на КОНКРЕТНУЮ claude-home абсолютно. ~ внутри settings.json
   не expands в некоторых версиях Claude Code.

ЭТАП 2 - PER-REPO RALPH LOOP (выбери ОДИН вариант)
9a. ВАРИАНТ A (canonical Ralph Loop, 15 файлов): скопируй
    /Users/antonsahovskii/Dev/Hooks/per-repo/ralph-loop/01-*.sh ... 15-*.sh
    в <repo>/.claude/hooks/. chmod +x. Используй если хочешь
    максимальную discipline и готов писать tracker в строгом формате.

9b. ВАРИАНТ B (psa-style, 4 файла): скопируй
    /Users/antonsahovskii/Dev/Hooks/per-repo/psa-style-ralph/*.sh.
    Используй если хочешь меньше файлов и проще naming.

    Совместимости с global launcher.sh нет - psa-style hooks нужно
    подключать напрямую через <repo>/.claude/settings.json hooks block.
    См. /Users/antonsahovskii/Documents/Dev/claude-agents/psa/.claude/settings.json
    как образец.

ЭТАП 3 - OPTIONAL GUARDS (по стеку)
10. Из /Users/antonsahovskii/Dev/Hooks/per-repo/optional-guards/
   подключи ТОЛЬКО применимые:
   - assertion-change-guard.sh: если есть тесты и нужно блокировать
     assertion-only change без production/source change.
   - test-data-guard.sh: если есть fixtures/snapshots/golden/testdata.
   - test-quality-gate.sh: если есть Go/Python/TS тесты и нужно блокировать
     trivial assert, empty body, skip без issue, mock-only где detector надежен.
   - destructive-sql-guard.sh: если есть PG/ClickHouse/MySQL, migration scripts
     или prod-like DB доступ.
   - graphify-hint.sh: если репо имеет graphify-out/. Это hint, не blocker.
   - validate-issue-close.sh: если проект ведет GitHub Issues с DoD checkbox-ами.
   chmod +x. Wire в <repo>/.claude/settings.json hooks block с правильными
   matcher pattern.

ЭТАП 4 - ПЕРВЫЙ TRACKER
11. Если репо не имеет active-tracker, создай заглушку:
    echo "# <project> tracker" > <repo>/.claude/active-tracker.template.md
    echo "" >> <repo>/.claude/active-tracker.template.md
    echo "- [ ] TASK-001: первая задача" >> ...
    echo "  - type: discovery" >> ...
    echo "  - required: true" >> ...
    echo "  - scope: <files or area>" >> ...
    echo "  - source_of_truth: <issue/doc/user request>" >> ...
    echo "  - success_criteria: <observable result>" >> ...
    echo "  - verification: <commands/checks>" >> ...
    echo "  - evidence: pending" >> ...
    echo "  - result: pending" >> ...
    echo "  - commit: pending" >> ...
    echo "  - status: planned" >> ...
    Покажи пользователю и спроси: «использовать как стартер или
    создать через plan-mode + 08-plan-mode-to-tracker.sh?»

ЭТАП 5 - SMOKE TESTS (обязательно перед DONE)
12. Если нужен быстрый install path, вместо ручных шагов 5-10 можно
    использовать:
    `/Users/antonsahovskii/Dev/Hooks/scripts/install-hooks-source.sh --project <repo> --with-git-hooks`
    После этого все равно выполнить smoke tests ниже.
13. Прогон каждого global hook через стандартный JSON input.
    - guard-no-tracker-overwrite:
      `{"tool_input":{"command":"echo X > <repo>/.claude/active-tracker"}}` → exit 2.
    - guard-no-force-push:
      `{"tool_input":{"command":"git push origin +HEAD:main"}}` → exit 2.
      `{"tool_input":{"command":"git push origin main"}}` → exit 2.
      `{"tool_input":{"command":"git commit --no-verify -m bypass"}}` → exit 2.
      `{"tool_input":{"command":"git push origin feature/my-branch"}}` → exit 0.
    - enforce-iter-cap:
      `{"tool_input":{"command":"gh pr merge 1 --admin"}}` → exit 2.
    - guard-no-secrets:
      создай tmp.txt с `AKIA<20chars>` и попробуй Write - должен deny.
    - ralph-loop-enforce:
      попробуй закрыть `[x] TASK-001` без `.checkpoints/TASK-001/evidence.md`
      с `Command/Result/Commit` - должен deny.
      `status: in_progress` -> `status: failed` должен allow только если
      checkbox остается `[ ]`, а evidence содержит `Verdict: FAIL`.
      `status: failed` -> `status: in_progress` должен allow для повторной
      работы.
    - record-pre-fix-failing-test:
      команда, которая проходит, должна дать exit 2; команда, которая падает,
      должна создать `.checkpoints/TASK-001/pre-fix-failing-test.md`.
    - 15-post-verification-failure-gate:
      failed `pytest`/`lint` без свежего attempt в `HANDOFF.md` должен дать exit 2.
    - 14-pre-commit-evidence-gate:
      если несколько `in_progress`, staged files должны выбрать task по `scope`;
      при двух совпадающих scope должен быть exit 2 с ambiguous message.
    - 04-gh-pr-merge-gate:
      GitHub pending human reviewer не должен блокировать при валидном Codex evidence;
      merge без Codex evidence должен дать exit 2.
    - optional guards, если подключены:
      assertion-only test change, fixture + assertion change без production,
      trivial assert, skip без issue и destructive SQL должны блокироваться.
14. Если есть per-repo Ralph Loop: создай <repo>/.claude/active-tracker
    с валидным `TASK-001` contract и `status: in_progress`.
    - обычный Stop должен exit 0 + notice, чтобы не было loop;
    - `RALPH_STOP_STRICT=1` или явный completion claim должен exit 2.
15. Если устанавливаешь из этого repo, запусти:
    `/Users/antonsahovskii/Dev/Hooks/tests/negative-ralph-loop-enforcement.sh`
16. Если подключал optional guards, запусти:
    `/Users/antonsahovskii/Dev/Hooks/tests/optional-guards-enforcement.sh`
17. Для Stop gate обязательно запусти:
    `/Users/antonsahovskii/Dev/Hooks/tests/stop-open-tasks-gate.sh`
18. Если проект хранится на GitHub, добавь или адаптируй server CI по образцу
    `/Users/antonsahovskii/Dev/Hooks/.github/workflows/ci.yml`, чтобы
    negative enforcement tests гонялись не только локально.
19. Если включены native Git hooks, проверь:
    - `git config core.hooksPath` -> `.githooks`
    - `git push origin HEAD:main` должен блокироваться локально.
    - `git push origin main` и `git commit --no-verify` должны блокироваться
      hook layer до выполнения.
    - В проекте без `.claude/active-tracker` `pre-push` не должен падать
      только из-за отсутствующего tracker.

ЭТАП 6 - ОТЧЕТ
20. Выведи структурированный отчет:
    - что было ДО (список существующих hooks + match с эталоном)
    - что стало ПОСЛЕ (новые/обновленные/удаленные с reasons)
    - smoke results (4 + опционально 1 stop test)
    - что осталось manual (e.g. первый tracker через plan-mode)
    - links на key файлы

КРИТЕРИИ ГОТОВНОСТИ:
- Все файлы из `global/` + gitnexus подпапка в claude-home (chmod +x для executable).
- Все файлы из `shared/agent-hooks/` в `~/.local/share/agent-hooks/`.
- 15 (вариант A) или 4 (вариант B) per-repo hooks в <repo>/.claude/hooks/
  (chmod +x).
- 0..6 optional guards подключены по применимости.
- settings.json hooks block с правильными абсолютными путями.
- Все smoke vectors blocked correctly, включая `ralph-loop-enforce`.
- Stop open-task gate работает в двух режимах: default allow+notice, strict/completion block.
- Если есть GitHub repo, server CI гоняет syntax + negative enforcement tests.
- Backup folder backups/<timestamp>/ содержит все что было удалено.
- НЕТ модификации кода вне .claude/ + claude-home.

ХАРД ПРАВИЛА:
- Не выдумывай файлы. Если нет в /Users/antonsahovskii/Dev/Hooks/ -
  не создавай.
- Не меняй существующий hook content "под мой стек". Hooks
  должны быть identical к эталону.
- Smoke fail = STOP. Не правь hook regex без user opt-in.
- Никогда не удаляй secrets/force-push guards. Backup + spare.
```

---

## Что Claude должен НЕ делать

- Писать новые hook скрипты - копировать только из эталона.
- Объединять варианты A и B Ralph Loop - выбрать один.
- Менять regex в guard-no-*.sh "потому что у меня другой формат" - это break protection.
- Удалять active-tracker файл существующего проекта без opt-in.
- Делать chmod 0777 - права 0755 на скрипты максимум.

## Что Claude должен СДЕЛАТЬ обязательно

- Backup перед каждой mutation: `cp -a <file> backups/<ts>/<file>`.
- Verify JSON valid после Edit settings.json: `python3 -c "import json; json.load(open(...))"`.
- chmod +x на все .sh после копирования.
- SHA256 compare для idempotence: `shasum -a 256 src dst | sort | uniq -c` → если 2 одинаковых, skip copy.

## Версионирование

Эталон в `/Users/antonsahovskii/Dev/Hooks/` обновляется вручную.
Когда меняешь hook (e.g. добавил новый cheat vector в `guard-no-tracker-overwrite.sh`),
**сначала** обнови файл в `/Users/antonsahovskii/Dev/Hooks/global/`,
**затем** прогоняй setup prompt по всем активным проектам чтобы
синхронизировать.
