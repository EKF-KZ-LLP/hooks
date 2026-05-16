# WORKPLAN: hard audit Ralph Loop hooks

## Source Of Truth
- User request dated 2026-05-12: hard audit of universal hooks and enforcement for the 35 critical gates.
- Repository source: `/Users/antonsahovskii/Dev/Hooks`.
- Project docs: `README.md`, `SETUP-PROMPT.md`, `templates/task-spec.md`, `global/*`, `per-repo/ralph-loop/*`.
- No local `AGENTS.md` in this repository. Local git exists on branch `main`; remote `origin` points to `https://github.com/EKF-KZ-LLP/hooks.git`.
- Remote GitHub repository is reachable at `https://github.com/EKF-KZ-LLP/hooks.git`; `main` is pushed. GitHub CodeQL default setup has a successful run on `64f15076f16883080ad7a386aa643fe7333da20f`. Third audit adds server CI for local enforcement tests.

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
- Final validator tightening added Senior/Codex review and stack-check requirements for done tasks.
- Repeat audit started after GitHub repository creation request.
- Current local repository now has `.git`; `origin` was not configured at repeat-audit start.
- Repeat audit must preserve existing uncommitted edits in `global/04-gh-pr-merge-gate.sh` and `per-repo/ralph-loop/04-gh-pr-merge-gate.sh` unless they are proven unsafe and replaced intentionally.
- Repeat audit found HIGH gaps in post-failure hook coverage, HANDOFF attempt deletion, behavior-code pre-fix evidence production, PR HEAD review freshness, destructive local actions and tracker timestamp forgery. All were fixed locally and covered by negative tests.
- Third audit found HIGH gaps in session-start contract validation, post-failure WORKPLAN freshness, repeat failed hypothesis detection before blocked/failed, and missing GitHub CI for negative tests. All were fixed locally before final remote verification.

## Repeat Audit Tasks

- [ ] TASK-007: Repeat 35-gate hard audit against local and GitHub-ready repo
  - type: discovery
  - required: true
  - scope: `global/`, `per-repo/ralph-loop/`, `tests/`, git remote config
  - source_of_truth: user repeat-audit request and current HEAD
  - success_criteria: 35 gates have fresh verdicts and all BLOCKING/HIGH gaps are fixed or explicitly remote-only
  - verification: code audit, git/remote inspection, local hook tests
  - evidence: `HANDOFF.md`, `global/ralph-loop-validate.py`, `tests/negative-ralph-loop-enforcement.sh`
  - result: Fresh audit completed. All local enforceable gates now map to hard blockers; remote live CI/CodeQL/review remains unproven without a real PR but local merge-gate mocks prove fail-closed and stale PR HEAD behavior.
  - commit: cfdcea4
  - status: done

- [ ] TASK-008: Prove remote/PR gate behavior as far as possible
  - type: ci
  - required: true
  - scope: GitHub remote `https://github.com/EKF-KZ-LLP/hooks.git`, PR/merge hook behavior
  - source_of_truth: GitHub remote state and merge gate code
  - success_criteria: remote is configured and inspected; local fail-closed PR/merge tests cover no-PR paths; real PR-only residual risk is stated
  - verification: `git remote`, `git ls-remote`, `gh`/git checks where available
  - evidence: `git ls-remote origin`, `gh pr list`, `gh run list`, `tests/negative-ralph-loop-enforcement.sh`
  - result: Remote `origin` was configured and inspected. GitHub repo is reachable but has no refs, PRs or runs. Added PR HEAD mismatch negative test so old review evidence cannot pass a merge gate.
  - commit: cfdcea4
  - status: done

- [ ] TASK-009: Update tests/docs if repeat audit finds gaps
  - type: test
  - required: true
  - scope: negative tests and docs
  - source_of_truth: repeat-audit gaps
  - success_criteria: new bypasses are blocked by negative tests and docs match behavior
  - verification: syntax checks, negative tests, git diff check
  - evidence: `README.md`, `SETUP-PROMPT.md`, `global/record-pre-fix-failing-test.sh`, `per-repo/ralph-loop/15-post-verification-failure-gate.sh`, `tests/negative-ralph-loop-enforcement.sh`
  - result: Added post-verification failure hook, pre-fix failing-test recorder, stricter PR evidence freshness, HANDOFF anti-deletion checks, destructive-action blocks and 8 new negative tests. Negative harness now reports 22 blocking tests.
  - commit: cfdcea4
  - status: done

## Third Audit Tasks

- [ ] TASK-010: Third hard audit after GitHub push
  - type: discovery
  - required: true
  - scope: `global/`, `per-repo/ralph-loop/`, `tests/`, GitHub runs
  - source_of_truth: user third-round request dated 2026-05-12 and current `origin/main`
  - success_criteria: 35 gates rechecked with current local and GitHub evidence; gaps documented in required format
  - verification: code audit, hook mapping, GitHub run inspection, negative tests
  - evidence: `HANDOFF.md`, `gh run view 25717629767`, `tests/negative-ralph-loop-enforcement.sh`
  - result: CodeQL success on GitHub was verified. Third-round local audit found four HIGH gaps: session start accepted invalid tracker contracts, failed verification did not require WORKPLAN freshness, repeated failed verification could reuse hypothesis until blocked/failed, and GitHub CI did not run negative tests.
  - commit: 91f78ed765c995cb01b79c3e76172532c68c37c2
  - status: done

- [ ] TASK-011: Close third-round BLOCKING/HIGH gaps
  - type: code
  - required: true
  - scope: hook code, docs, workflows, negative tests
  - source_of_truth: gaps found in TASK-010
  - success_criteria: each local fix has a hard block and a negative test where practical
  - verification: syntax checks, negative tests, GitHub CI if added
  - evidence: `per-repo/ralph-loop/01-session-start-load-context.sh`, `global/ralph-loop-validate.py`, `.github/workflows/ci.yml`, `tests/negative-ralph-loop-enforcement.sh`
  - result: SessionStart now validates full Task Evidence Contract and includes AGENTS.md context; post-failure validation now blocks stale WORKPLAN and repeated hypotheses; GitHub CI workflow added; negative tests increased to 27 hard blocks.
  - commit: 91f78ed765c995cb01b79c3e76172532c68c37c2
  - status: done

- [ ] TASK-012: Final third-round report with hook table
  - type: review
  - required: true
  - scope: final audit output
  - source_of_truth: user requested final report format
  - success_criteria: final answer includes hook/check/result/test table and residual risks
  - verification: final local and remote evidence
  - evidence: local checks, GitHub CI run `25717864870`, GitHub CodeQL runs `25717863960` and `25717867141`
  - result: Local checks pass, CI run is success, CodeQL runs are success. Final report can use hook/result/test table.
  - commit: 91f78ed765c995cb01b79c3e76172532c68c37c2
  - status: done

## Codex Review Gate Update

- [ ] TASK-013: Replace GitHub human review gate with Codex review gate
  - type: code
  - required: true
  - scope: `global/04-gh-pr-merge-gate.sh`, `per-repo/ralph-loop/04-gh-pr-merge-gate.sh`, `tests/negative-ralph-loop-enforcement.sh`, docs
  - source_of_truth: user clarification that GitHub human review is useless for a business owner and Codex review is the meaningful gate
  - success_criteria: PR merge no longer blocks on GitHub `reviewDecision` or pending human reviewers, but still blocks without current Codex review evidence from Claude Code plugin + `codex:rescue`
  - verification: local negative/allow tests plus GitHub CI
  - evidence: `global/04-gh-pr-merge-gate.sh`, `per-repo/ralph-loop/04-gh-pr-merge-gate.sh`, `tests/negative-ralph-loop-enforcement.sh`, GitHub CI `25718309366`, GitHub CodeQL `25718309104`
  - result: PR merge gate now treats GitHub human review as informational and requires current Codex review evidence with Claude Code plugin, `codex:rescue`, `codex:codex-rescue`, `AGENTS.md`, `verbatim`, `full-code-path`, `Command`, `Result` and current commit. Negative tests now include "merge without Codex evidence" block and "pending GitHub human review allowed with Codex evidence" allow. Local checks passed, GitHub CI passed, GitHub CodeQL passed.
  - commit: 48aeb27553460d4a3c361614e70fee2c800f80c3
  - status: done

## Optional Guards Audit

- [ ] TASK-014: Audit optional guards and prove stack-specific hard blocks
  - type: test
  - required: true
  - scope: `per-repo/optional-guards/`, `tests/`, `README.md`, `SETUP-PROMPT.md`
  - source_of_truth: user request for optional-guards audit, negative tests and "подключать когда" table
  - success_criteria: every optional guard has a clear applicability rule, hard-block behavior, negative test or documented non-blocking status, and all BLOCKING/HIGH gaps fixed
  - verification: shell syntax, optional negative test harness, main negative harness, GitHub CI/CodeQL
  - evidence: `tests/optional-guards-enforcement.sh`, `tests/negative-ralph-loop-enforcement.sh`, GitHub CI `25721675120`, GitHub CodeQL `25721674661`
  - result: Optional guard audit found HIGH gaps in assertion-change hard blocking, diff fail-open paths, destructive SQL breadth, graphify command matching and missing dedicated negative tests. Fixed local hooks, added optional negative suite with 8 checks, added CI step and updated the "подключать когда" table. Local checks, GitHub CI and GitHub CodeQL passed on commit `ef4b210de56143ac8412def8480d91b525e97067`; final local rerun after tracker updates passed `optional guard tests passed: 8`.
  - commit: ef4b210de56143ac8412def8480d91b525e97067
  - status: done

## 2026-05-14 Canonical Source Cleanup

- [ ] TASK-015: Bring `/Dev/Hooks` back to canonical runtime parity after global/local hook changes
  - type: safety
  - required: true
  - scope: `global/`, `per-repo/ralph-loop/`, shared agent-hook runtime, install/docs, git-hook templates
  - source_of_truth: user request on 2026-05-14, current runtime in `~/.claude/hooks` and `~/.local/share/agent-hooks`, active project drift found in `prgate`
  - success_criteria: source repo contains the canonical 03 tracker wrapper and shared runtime files, global guard source matches runtime, install path is documented, and copy-to-new-project flow is safe for repos with or without `.claude/active-tracker`
  - verification: shell/Python/JSON syntax checks, existing negative harnesses, live 03 hook simulations, settings parse, and `gitnexus_detect_changes`
  - evidence: `shared/agent-hooks/plan-tracker-edit-guard.test.sh`, `tests/negative-ralph-loop-enforcement.sh`, `tests/optional-guards-enforcement.sh`, syntax checks, `git diff --check`, GitNexus detect changes
  - result: Source repo now includes shared `agent-hooks/`, canonical 03 wrapper, native git-hook templates and install script. Runtime/source `guard-no-tracker-overwrite.sh` are aligned and block `touch WORKPLAN.md`. 04 merge gate no longer uses hang-prone heredocs. Negative suite passes 33/33.
  - commit: pending
  - status: done

## 2026-05-15 Hook Pressure Reduction

- [ ] TASK-016: Reduce overblocking without weakening P0 safety
  - type: safety
  - required: true
  - scope: Claude settings deny lists, `05-stop-open-tasks-gate.sh`, Ralph validator integration, active project copies
  - source_of_truth: user request on 2026-05-15 to remove ssh/infisical-style bans and stop G_OPEN overnight spam loops
  - success_criteria: infrastructure commands are not denied by settings just because they are ssh/infisical/etc; open tracker tasks do not hard-block ordinary Stop; completion claims still block when required tasks are open; strict mode remains available
  - verification: focused 05 regression test, syntax checks, JSON parse, negative suite, live Stop simulations
  - evidence: `tests/stop-open-tasks-gate.sh`, `tests/negative-ralph-loop-enforcement.sh`, `tests/optional-guards-enforcement.sh`, settings JSON parse, 05 SHA256 sync check
  - result: `05-stop-open-tasks-gate.sh` now allows ordinary Stop with open tasks or missing tracker by printing notice and returning `0`, while strict mode and transcript completion claims still block with exit `2`. Removed command-deny entries for `ssh`, `scp`, `rsync`, `security`, `kubectl`, and `infisical` from scanned Claude settings while keeping destructive command and direct secret-file read protection. Synced canonical 05 into `vcm`, `meridian`, `psa`, and backup project copies. Added CI coverage for the focused Stop gate test.
  - commit: pending
  - status: done

## 2026-05-15 P0/P1/P2 Hook Layering Completion

- [ ] TASK-017: Finish P0/P1/P2 gate layering without overblocking
  - type: safety
  - required: true
  - scope: `policy-runner`, Claude/Codex hook settings, active tracker projects, tests, docs
  - source_of_truth: user request on 2026-05-15 to execute the P0/P1/P2 layering plan after the gap matrix
  - success_criteria: P0 main/master push and `--no-verify` are always-on hard blocks; P1 opted-in projects have consistent active tracker, Stop, TDD/pre-fix and Codex review wiring; P2 reminder/Serena/GitNexus/latency stays advisory; existing anti-cheat and soft Stop behavior remain green
  - verification: red tests first for missing P0 behavior, policy-runner tests, Ralph negative tests, optional guards, Stop tests, syntax/JSON checks, project wiring inventory
  - evidence: `policy-runner test`, `tests/negative-ralph-loop-enforcement.sh`, `tests/optional-guards-enforcement.sh`, `tests/stop-open-tasks-gate.sh`, `policy-runner health`, project wiring inventory, SHA256 sync checks
  - result: P0 main/master push and `git --no-verify` are now hard-blocked by `policy-runner` and `guard-no-force-push.sh`; normal feature branch push is allowed. Active-tracker projects `vcm`, `meridian`, `psa`, and backup now have matching 03/04/05/11/14/15 hook copies and settings wiring for active tracker, Stop/SubagentStop, TDD/test-debt, precommit evidence, failed verification and Codex merge gate. P2 reminder/Serena/GitNexus/telemetry remains advisory.
  - commit: pending
  - status: done

## 2026-05-15 Failed-State and G14 Active Task Optimization

- [ ] TASK-018: Fix failed/open task handling and G14 active-task selection
  - type: safety
  - required: true
  - scope: shared 03 tracker guard, Ralph validator precommit, tests, runtime/project hook sync
  - source_of_truth: user request on 2026-05-15 and PHASE-K-002 Codex FAIL scenario
  - success_criteria: `failed`/`blocked` are explicit open states, not closed states; G03 allows honest in_progress -> failed/blocked only with evidence and open checkbox; G14 chooses the staged-files matching task or blocks ambiguous state, not first in_progress; Codex FAIL cannot be used as review bypass; all active tracker projects receive synced canonical hooks
  - verification: red tests before patch, canonical/runtime tests, negative suite, optional suite, stop suite, syntax/JSON checks, live precommit simulations
  - evidence: `plan-tracker-edit-guard.test.sh`, `tests/negative-ralph-loop-enforcement.sh`, optional/stop/policy suites, live runtime precommit smoke, syntax/JSON/hash checks
  - result: G03 now supports honest open-state `planned|in_progress -> failed` only with open checkbox and immutable `Verdict: FAIL` evidence, plus `failed -> planned|in_progress` reopen. `failed` is not a closed state and cannot bypass Codex PASS. G14 precommit now selects the active task whose `scope` matches all staged governed files; it blocks ambiguous multi-task matches instead of silently using the first `in_progress`.
  - commit: pending
  - status: done

## 2026-05-15 Stop Gate Feedback Cleanup

- [ ] TASK-019: Make policy-runner Stop blocks actionable without weakening the gate
  - type: safety
  - required: true
  - scope: shared/runtime `policy-runner`, policy tests, canonical sync
  - source_of_truth: user report on 2026-05-15 that stale `.agent-state/tdd-green.json` or `.agent-state/verification.json` can make Claude Code look like it simply stops with no clear next action
  - success_criteria: Stop gate still exits non-zero for stale/missing behavior evidence, but stderr includes exact marker paths, current `HEAD`, reason per marker, minimum JSON examples and next commands to rerun/update evidence
  - verification: red regression test for stale `head_sha`, `policy-runner test`, `node --check`, canonical/runtime SHA sync and focused Stop simulation
  - evidence: `shared/agent-hooks/policy-runner.test.js`, `shared/agent-hooks/policy-runner.js`, runtime copies under `~/.local/share/agent-hooks`
  - result: `policy-runner` Stop gate now still returns exit `2` for missing/stale behavior evidence, but stderr starts with `Stop gate blocked final completion`, lists repo/current `HEAD`, exact failing marker paths, per-marker reasons and copyable minimum `.agent-state/tdd-green.json` plus `.agent-state/verification.json` examples. Added stale `head_sha` regression test.
  - commit: pending
  - status: done

## 2026-05-16 PSA Pre-Push and Runtime Parity Cleanup

- [ ] TASK-020: Fix merge-commit evidence self-reference and restore policy-runner source/runtime parity
  - type: safety
  - required: true
  - scope: `global/ralph-loop-validate.py`, runtime `~/.claude/hooks/ralph-loop-validate.py`, `tests/negative-ralph-loop-enforcement.sh`, `shared/agent-hooks/policy-runner.js`, `shared/agent-hooks/policy-runner.test.js`
  - source_of_truth: PSA PR #179 pre-push failure on merge commit `913912b4f1a4eed4159a16f62862cde49f41bbbf` and source/runtime drift found during final Hooks audit
  - success_criteria: pre-push evidence validation accepts a merge commit when evidence names the verified first parent; normal stale-evidence blocks remain intact; canonical `shared/agent-hooks/policy-runner*` matches live runtime; source and runtime policy-runner suites both report the same test count
  - verification: red regression for merge first-parent evidence, Ralph negative suite, Python compile, shell syntax, Node syntax, policy-runner source/runtime tests, full shared agent-hook JS tests, GitNexus detect changes, `git diff --check`, runtime/source `cmp`
  - evidence: `tests/negative-ralph-loop-enforcement.sh`, `global/ralph-loop-validate.py`, `shared/agent-hooks/policy-runner.test.js`
  - result: Merge HEAD now accepts first-parent evidence, which avoids an impossible "write current merge SHA into evidence before push" loop. Non-merge metadata-only evidence commits can also reference their first parent, but code commits cannot inherit stale first-parent evidence. Closed task evidence no longer goes stale just because a later commit touches files outside that task's declared scope; same-scope changes still block. Runtime and source `ralph-loop-validate.py` match. Source `policy-runner` was behind runtime by five coverage-scope tests, so canonical source was synced from runtime and rerun. Source/runtime `policy-runner` suites now both report 36 tests, JS hook tests pass, GitNexus detect changes reports critical expected impact on hook enforcement paths, and whitespace/syntax checks are clean.
  - commit: pending
  - status: done
