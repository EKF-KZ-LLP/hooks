# Task Evidence Contract template

```md
- [ ] TASK-001: <task title>
  - type: discovery | code | test | review | docs | ci | adr | safety | other
  - required: true | false
  - scope: <files, modules, docs, or area>
  - source_of_truth: <issue, user request, PRD, ADR, design, failing test>
  - success_criteria: <observable outcome>
  - verification: <commands, checks, review, CI>
  - evidence: pending
  - result: pending
  - commit: pending
  - status: planned
```

For a closed task:

```md
- [x] TASK-001: <task title>
  - type: code
  - required: true
  - scope: src/app.py tests/test_app.py
  - source_of_truth: BUG-123
  - success_criteria: regression test fails before fix and passes after fix
  - verification: pytest tests/test_app.py
  - evidence: .checkpoints/TASK-001/evidence.md
  - result: passed
  - commit: <current HEAD SHA>
  - status: done
```

Evidence file requirements:
- path under `.checkpoints/<TASK-ID>/`;
- non-empty file;
- `Command:`;
- `Result:`;
- `Commit:` or `SHA:` matching current HEAD unless marked `pre-fix` or `pre-review`;
- review evidence includes `full-code-path` and `Diff-only: false`;
- Codex evidence includes `Claude Code plugin`, `codex:rescue`, `codex:codex-rescue`.
