# WORKPLAN: hard audit Ralph Loop hooks

## Source Of Truth
- User request dated 2026-05-12: hard audit of universal hooks and enforcement for the 35 critical gates.
- Repository source: `/Users/antonsahovskii/Dev/Hooks`.
- Project docs: `README.md`, `SETUP-PROMPT.md`, `templates/task-spec.md`, `global/*`, `per-repo/ralph-loop/*`.
- No local `AGENTS.md` and no `.git` directory found in this repository. Git/SHA enforcement must be implemented for target repositories where git exists and tested with synthetic fixtures.

## Readiness Criteria
- All BLOCKING/HIGH gaps found in the 35 gates are fixed in hooks or tests.
- Task Evidence Contract is enforced, not only documented.
- Ralph Loop blocked/failed enforcement is implemented as hard blocks.
- Required hooks exist or are mapped to existing files: task-start, pre-edit, post-edit, checkbox-close, blocked/failed, pre-DONE, pre-commit, PR/merge gate.
- Negative tests cover the requested bypasses and pass.
- `WORKPLAN.md` and `HANDOFF.md` are updated after each completed subtask and at final handoff.

## Tasks

- [ ] TASK-001: Audit current hooks against 35 critical gates
  - type: discovery
  - required: true
  - scope: `global/`, `per-repo/ralph-loop/`, `templates/`, docs
  - source_of_truth: user request and current hook code
  - success_criteria: each gate has YES/PARTIAL/NO with bypass and required fix where needed
  - verification: manual code audit plus targeted script reads
  - evidence: `HANDOFF.md`
  - result: Current hooks have partial enforcement for skip tamper, merge gates, stop on open tasks, shallow evidence checks and weak TDD warnings. Blocking gaps remain in full Task Evidence Contract, blocked/failed Ralph Loop proof, strict current-SHA review evidence, Codex via codex:rescue proof, active-plan hard start, pre-commit gate and negative tests.
  - commit: n/a-no-git
  - status: done

- [ ] TASK-002: Implement Task Evidence Contract enforcement
  - type: code
  - required: true
  - scope: Ralph Loop hook library and templates
  - source_of_truth: Task Evidence Contract in user request
  - success_criteria: invalid checkbox metadata/evidence/status/SHA is blocked with non-zero exit
  - verification: negative tests for missing metadata, missing evidence, stale evidence, open required tasks
  - evidence: `global/ralph-loop-validate.py`, `tests/negative-ralph-loop-enforcement.sh`
  - result: Added strict parser for TASK-ID checkbox metadata, closed evidence files, current HEAD SHA, deletion/rename checks, parent/child checks, Codex review provenance markers and checkpoint path restrictions.
  - commit: n/a-no-git
  - status: done

- [ ] TASK-003: Implement Ralph Loop blocked/failed enforcement
  - type: code
  - required: true
  - scope: blocked/failed gate, attempt log contract, retry policy, strategy shift, source search, consultation
  - source_of_truth: Ralph Loop Hook Requirement in user request
  - success_criteria: blocked/failed/DONE cannot pass without valid attempts, true blocker, evidence, source usage and Senior/Codex consultation when stuck
  - verification: negative tests requested by user
  - evidence: `global/ralph-loop-validate.py`, `per-repo/ralph-loop/05-stop-open-tasks-gate.sh`
  - result: Added hard blocked/failed validation for attempt schema, retry budget, duplicate hypotheses, strategy shift, local sources, external docs search, true blocker text and Senior/Codex consultation.
  - commit: n/a-no-git
  - status: done

- [ ] TASK-004: Add or update negative tests
  - type: test
  - required: true
  - scope: test harness for hook bypasses
  - source_of_truth: 12 required negative tests in user request
  - success_criteria: every requested bypass returns non-zero and prints a blocking reason
  - verification: local test command output
  - evidence: `tests/negative-ralph-loop-enforcement.sh`
  - result: 14 negative tests pass and require non-zero blocks for all requested bypasses plus direct skip-reason Bash/Write cheats.
  - commit: n/a-no-git
  - status: done

- [ ] TASK-005: Update docs and setup guidance
  - type: docs
  - required: true
  - scope: `README.md`, `SETUP-PROMPT.md`, `templates/task-spec.md` if needed
  - source_of_truth: implemented hooks and user requested final behavior
  - success_criteria: docs describe enforcement paths without claiming unimplemented blocks
  - verification: compare docs to hook code and tests
  - evidence: `README.md`, `SETUP-PROMPT.md`, `templates/task-evidence-contract.md`
  - result: Docs now describe the Task Evidence Contract, Ralph Loop attempt contract, hook mapping, pre-commit gate and updated setup/smoke expectations.
  - commit: n/a-no-git
  - status: done

- [ ] TASK-006: Run checks and final audit report
  - type: review
  - required: true
  - scope: full changed hook/test/doc set
  - source_of_truth: readiness criteria above
  - success_criteria: checks pass or residual risks are explicit with evidence
  - verification: shellcheck/bash syntax where available, negative tests, final 35-gate table
  - evidence: local command output from syntax checks, negative tests, diff check and style scan
  - result: `python3 -m py_compile`, `bash -n` for all shell hooks, `git diff --check`, forbidden-symbol scan and 14 negative tests all passed locally.
  - commit: n/a-no-git
  - status: done

## Current Notes
- The reported self-authored `skip-reason.md` bypass appears already partly addressed in hook 02/03 and `guard-no-tracker-overwrite.sh`, but it still needs negative test proof.
- Existing enforcement is split between per-repo hooks and `global/ralph-loop-enforce.sh`; audit must decide whether this is wired and sufficient.
- Local git repository initialized; baseline commit is `6bb892e`. Remote CI, CodeQL and PR review gates still require a real PR to verify end to end, while local tests will cover fail-closed and stale-SHA logic.
- Final local checks passed before commit. Remote CI/CodeQL/review was not run because this repository has no remote PR.
- Implementation commit recorded locally as `b99329f`; a final handoff-only commit may follow.
