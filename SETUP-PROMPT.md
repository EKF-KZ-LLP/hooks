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
7. Открой $CLAUDE_CONFIG_DIR/settings.json (fallback ~/.claude/settings.json).
   Образец hooks block - /Users/antonsahovskii/.claude/settings.json
   ключ "hooks". Скопируй его 1-в-1. Все пути в командах должны
   указывать на КОНКРЕТНУЮ claude-home абсолютно. ~ внутри settings.json
   не expands в некоторых версиях Claude Code.

ЭТАП 2 - PER-REPO RALPH LOOP (выбери ОДИН вариант)
8a. ВАРИАНТ A (canonical Ralph Loop, 14 файлов): скопируй
    /Users/antonsahovskii/Dev/Hooks/per-repo/ralph-loop/01-*.sh ... 14-*.sh
    в <repo>/.claude/hooks/. chmod +x. Используй если хочешь
    максимальную discipline и готов писать tracker в строгом формате.

8b. ВАРИАНТ B (psa-style, 4 файла): скопируй
    /Users/antonsahovskii/Dev/Hooks/per-repo/psa-style-ralph/*.sh.
    Используй если хочешь меньше файлов и проще naming.

    Совместимости с global launcher.sh нет - psa-style hooks нужно
    подключать напрямую через <repo>/.claude/settings.json hooks block.
    См. /Users/antonsahovskii/Documents/Dev/claude-agents/psa/.claude/settings.json
    как образец.

ЭТАП 3 - OPTIONAL GUARDS (по стеку)
9. Из /Users/antonsahovskii/Dev/Hooks/per-repo/optional-guards/
   подключи ТОЛЬКО применимые:
   - assertion-change-guard.sh + test-data-guard.sh + test-quality-gate.sh:
     если репо имеет Go/Python/TS тесты.
   - destructive-sql-guard.sh: если репо имеет PG/CH/MySQL/psql.
   - graphify-hint.sh: если репо имеет graphify-out/.
   - validate-issue-close.sh: всегда полезно для проектов с GitHub Issues.
   chmod +x. Wire в <repo>/.claude/settings.json hooks block с правильными
   matcher pattern.

ЭТАП 4 - ПЕРВЫЙ TRACKER
10. Если репо не имеет active-tracker, создай заглушку:
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
11. Прогон каждого global hook через стандартный JSON input.
    - guard-no-tracker-overwrite:
      `{"tool_input":{"command":"echo X > <repo>/.claude/active-tracker"}}` → exit 2.
    - guard-no-force-push:
      `{"tool_input":{"command":"git push origin +HEAD:main"}}` → exit 2.
    - enforce-iter-cap:
      `{"tool_input":{"command":"gh pr merge 1 --admin"}}` → exit 2.
    - guard-no-secrets:
      создай tmp.txt с `AKIA<20chars>` и попробуй Write - должен deny.
    - ralph-loop-enforce:
      попробуй закрыть `[x] TASK-001` без `.checkpoints/TASK-001/evidence.md`
      с `Command/Result/Commit` - должен deny.
12. Если есть per-repo Ralph Loop: создай <repo>/.claude/active-tracker
    с валидным `TASK-001` contract и `status: in_progress` - Stop должен exit 2.
13. Если устанавливаешь из этого repo, запусти:
    `/Users/antonsahovskii/Dev/Hooks/tests/negative-ralph-loop-enforcement.sh`

ЭТАП 6 - ОТЧЕТ
14. Выведи структурированный отчет:
    - что было ДО (список существующих hooks + match с эталоном)
    - что стало ПОСЛЕ (новые/обновленные/удаленные с reasons)
    - smoke results (4 + опционально 1 stop test)
    - что осталось manual (e.g. первый tracker через plan-mode)
    - links на key файлы

КРИТЕРИИ ГОТОВНОСТИ:
- Все файлы из `global/` + gitnexus подпапка в claude-home (chmod +x для executable).
- 14 (вариант A) или 4 (вариант B) per-repo hooks в <repo>/.claude/hooks/
  (chmod +x).
- 0..6 optional guards подключены по применимости.
- settings.json hooks block с правильными абсолютными путями.
- Все smoke vectors blocked correctly, включая `ralph-loop-enforce` и Stop open-task gate.
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
