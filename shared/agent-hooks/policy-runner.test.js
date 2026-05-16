#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const runner = path.join(__dirname, 'policy-runner.js');

function mkRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-'));
  fs.mkdirSync(path.join(dir, '.git'));
  fs.mkdirSync(path.join(dir, '.agent-state'));
  fs.mkdirSync(path.join(dir, 'src'));
  fs.mkdirSync(path.join(dir, 'tests'));
  fs.writeFileSync(path.join(dir, 'WORKPLAN.md'), '# Workplan\n');
  fs.writeFileSync(path.join(dir, 'HANDOFF.md'), '# Handoff\n');
  fs.writeFileSync(path.join(dir, 'src', 'service.ts'), 'export function value() { return 1; }\n');
  fs.writeFileSync(path.join(dir, 'tests', 'service.test.ts'), 'test("value", () => { expect(value()).toBe(1); });\n');
  return dir;
}

function mkGitRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-git-'));
  fs.mkdirSync(path.join(dir, '.agent-state'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'src'));
  fs.mkdirSync(path.join(dir, 'tests'));
  fs.writeFileSync(path.join(dir, 'WORKPLAN.md'), '# Workplan\n');
  fs.writeFileSync(path.join(dir, 'HANDOFF.md'), '# Handoff\n');
  fs.writeFileSync(path.join(dir, 'src', 'service.ts'), 'export function value() { return 1; }\n');
  fs.writeFileSync(path.join(dir, 'tests', 'service.test.ts'), 'test("value", () => { expect(value()).toBe(1); });\n');
  git(dir, ['init', '-q']);
  git(dir, ['config', 'user.email', 'agent-hooks@example.local']);
  git(dir, ['config', 'user.name', 'Agent Hooks Test']);
  git(dir, ['add', '.']);
  git(dir, ['commit', '-q', '-m', 'initial']);
  return dir;
}

function git(repo, args) {
  const res = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
  assert.strictEqual(res.status, 0, `${args.join(' ')}\n${res.stderr}`);
  return res.stdout.trim();
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function baseMarkers(repo) {
  const now = new Date().toISOString();
  const common = { head_sha: 'UNKNOWN', checked_at: now };
  writeJson(path.join(repo, '.agent-state', 'current-step.json'), {
    ...common,
    source_of_truth: 'test fixture',
    success_criteria: 'green fixtures',
    verification_command: 'node policy-runner.test.js',
    risk_level: 'medium',
    plan_vs_code_status: 'checked'
  });
  writeJson(path.join(repo, '.agent-state', 'plan-vs-code.json'), {
    ...common,
    files_inspected: ['src/service.ts'],
    deviation_note: 'NONE'
  });
  writeJson(path.join(repo, '.agent-state', 'tdd-red.json'), {
    ...common,
    test_command: 'npm test -- service',
    test_file: 'tests/service.test.ts',
    expected_failure: 'missing behavior',
    observed_failure_excerpt: 'expected 2 received 1',
    created_before_code_edit: true
  });
  writeJson(path.join(repo, '.agent-state', 'tdd-green.json'), {
    ...common,
    test_command: 'npm test -- service',
    observed_pass_excerpt: '1 passed',
    coverage: { domain: 98, other: 90 }
  });
  writeJson(path.join(repo, '.agent-state', 'verification.json'), {
    ...common,
    tests: '1 passed',
    diagnostics: 'tsc clean',
    inventory: 'no P0/P1'
  });
  writeJson(path.join(repo, '.agent-state', 'serena-evidence.json'), {
    ...common,
    tool: 'mcp__serena__find_declaration',
    evidence: 'symbol context read'
  });
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), new Date(), new Date());
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), new Date(), new Date());
}

function run(args, input, cwd, env = {}) {
  return spawnSync(process.execPath, [runner, ...args], {
    input: JSON.stringify(input),
    cwd,
    env: { ...process.env, AGENT_HOOKS_TEST: '1', ...env },
    encoding: 'utf8'
  });
}

function claudeInput(toolName, toolInput, cwd) {
  return { hook_event_name: 'PreToolUse', tool_name: toolName, tool_input: toolInput, cwd };
}

function codexInput(toolName, toolInput, cwd) {
  return { event: 'pre_tool_use', tool: { name: toolName, input: toolInput }, cwd };
}

const tests = [];
function test(name, fn) { tests.push({ name, fn }); }

test('empty input is allowed', () => {
  const repo = mkRepo();
  const res = spawnSync(process.execPath, [runner, 'claude', 'PreToolUse'], {
    input: '',
    cwd: repo,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stderr);
});

test('malformed JSON is allowed with warning', () => {
  const repo = mkRepo();
  const res = spawnSync(process.execPath, [runner, 'claude', 'PreToolUse'], {
    input: '{bad',
    cwd: repo,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stderr);
  assert.match(res.stderr, /malformed hook JSON/i);
});

test('behavior edit without step marker is blocked', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PreToolUse'], claudeInput('Edit', { file_path: path.join(repo, 'src', 'service.ts') }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const output = JSON.parse(res.stdout);
  assert.strictEqual(output.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(output.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /current-step/i);
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /cat > \.agent-state\/current-step\.json/i);
});

test('Codex behavior edit without step marker still exits non-zero', () => {
  const repo = mkRepo();
  const res = run(['codex', 'PreToolUse'], codexInput('Edit', { file_path: path.join(repo, 'src', 'service.ts') }, repo), repo);
  assert.strictEqual(res.status, 2);
  assert.match(res.stderr, /current-step/i);
});

test('behavior edit with all markers is allowed', () => {
  const repo = mkRepo();
  baseMarkers(repo);
  const res = run(['claude', 'PreToolUse'], claudeInput('Edit', { file_path: path.join(repo, 'src', 'service.ts') }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('test-only edit is allowed without TDD red', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PreToolUse'], claudeInput('Edit', { file_path: path.join(repo, 'tests', 'service.test.ts') }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('behavior edit with invalid TDD waiver is blocked', () => {
  const repo = mkRepo();
  baseMarkers(repo);
  fs.unlinkSync(path.join(repo, '.agent-state', 'tdd-red.json'));
  writeJson(path.join(repo, '.agent-state', 'tdd-waiver.json'), {
    head_sha: 'UNKNOWN',
    checked_at: new Date().toISOString(),
    waiver_type: 'merge-conflict-resolution'
  });
  const res = run(['claude', 'PreToolUse'], claudeInput('Edit', { file_path: path.join(repo, 'src', 'service.ts') }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const output = JSON.parse(res.stdout);
  const reason = output.hookSpecificOutput.permissionDecisionReason;
  assert.match(reason, /TDD waiver gate/i);
  assert.match(reason, /verification_command/i);
  assert.match(reason, /cat > \.agent-state\/tdd-waiver\.json/i);
});

test('behavior edit with valid merge-conflict TDD waiver is allowed', () => {
  const repo = mkRepo();
  baseMarkers(repo);
  fs.unlinkSync(path.join(repo, '.agent-state', 'tdd-red.json'));
  writeJson(path.join(repo, '.agent-state', 'tdd-waiver.json'), {
    head_sha: 'UNKNOWN',
    checked_at: new Date().toISOString(),
    waiver_type: 'merge-conflict-resolution',
    reason: 'Resolving existing merge conflict without adding new feature behavior.',
    verification_command: 'npm test -- service && tsc --noEmit',
    risk_acceptance: 'No regression test can be written before conflict markers are removed; full relevant tests run after edit.'
  });
  const res = run(['claude', 'PreToolUse'], claudeInput('Edit', { file_path: path.join(repo, 'src', 'service.ts') }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('secret command is blocked for Codex shape', () => {
  const repo = mkRepo();
  const res = run(['codex', 'PreToolUse'], codexInput('Bash', { command: 'cat .env' }, repo), repo);
  assert.strictEqual(res.status, 2);
  assert.match(res.stderr, /secret/i);
});

test('destructive command is blocked', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PreToolUse'], claudeInput('Bash', { command: 'git reset --hard HEAD~1' }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const output = JSON.parse(res.stdout);
  assert.strictEqual(output.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /destructive/i);
});

test('main branch push is blocked as P0 unsafe git', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PreToolUse'], claudeInput('Bash', { command: 'git push origin main' }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const output = JSON.parse(res.stdout);
  assert.strictEqual(output.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /main|master|unsafe git/i);
});

test('git no-verify is blocked as P0 unsafe git', () => {
  const repo = mkRepo();
  const res = run(['codex', 'PreToolUse'], codexInput('Bash', { command: 'git commit --no-verify -m test' }, repo), repo);
  assert.strictEqual(res.status, 2);
  assert.match(res.stderr, /no-verify|unsafe git/i);
});

test('feature branch push is allowed', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PreToolUse'], claudeInput('Bash', { command: 'git push origin feature/hook-layering' }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  assert.strictEqual(res.stdout.trim(), '');
});

test('grep sed rename is blocked without LSP evidence', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PreToolUse'], claudeInput('Bash', { command: "rg -l oldName src | xargs sed -i '' s/oldName/newName/g" }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const output = JSON.parse(res.stdout);
  assert.strictEqual(output.hookSpecificOutput.permissionDecision, 'deny');
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /LSP|Serena|GitNexus/);
});

test('grep sed rename is allowed with LSP evidence', () => {
  const repo = mkRepo();
  writeJson(path.join(repo, '.agent-state', 'lsp-evidence.json'), {
    checked_at: new Date().toISOString(),
    tool: 'serena rename',
    evidence: 'symbol-safe rename'
  });
  const res = run(['claude', 'PreToolUse'], claudeInput('Bash', { command: "rg -l oldName src | xargs sed -i '' s/oldName/newName/g" }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('Stop after behavior change without verification is blocked', () => {
  const repo = mkRepo();
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['src/service.ts'] }));
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 2);
  assert.match(res.stderr, /verification|tdd-green/i);
});

test('Stop with stale verification head shows actionable remediation', () => {
  const repo = mkGitRepo();
  const head = git(repo, ['rev-parse', 'HEAD']);
  const staleHead = '0'.repeat(40);
  writeJson(path.join(repo, '.agent-state', 'changed-behavior.json'), {
    files: ['src/service.ts'],
    updated_at: new Date().toISOString()
  });
  writeJson(path.join(repo, '.agent-state', 'tdd-green.json'), {
    head_sha: staleHead,
    checked_at: new Date().toISOString(),
    test_command: 'npm test -- service',
    observed_pass_excerpt: '1 passed',
    coverage: { domain: 98, other: 90 }
  });
  writeJson(path.join(repo, '.agent-state', 'verification.json'), {
    head_sha: staleHead,
    checked_at: new Date().toISOString(),
    tests: '1 passed',
    diagnostics: 'tsc clean',
    inventory: 'no P0/P1'
  });
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);

  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);

  assert.strictEqual(res.status, 2);
  assert.match(res.stderr, /Stop gate blocked final completion/i);
  assert.ok(res.stderr.includes(path.join(repo, '.agent-state', 'tdd-green.json')), res.stderr);
  assert.ok(res.stderr.includes(path.join(repo, '.agent-state', 'verification.json')), res.stderr);
  assert.ok(res.stderr.includes(head), res.stderr);
  assert.match(res.stderr, /git rev-parse HEAD/i);
  assert.match(res.stderr, /cat > \.agent-state\/tdd-green\.json/i);
  assert.match(res.stderr, /cat > \.agent-state\/verification\.json/i);
});

test('Stop hook active re-entry is allowed to avoid loops', () => {
  const repo = mkRepo();
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['src/service.ts'] }));
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo, stop_hook_active: true }, repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('Stop with verification evidence is allowed', () => {
  const repo = mkRepo();
  baseMarkers(repo);
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['src/service.ts'] }));
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('Stop with domain-only scope and other<90 is allowed', () => {
  const repo = mkGitRepo();
  baseMarkers(repo);
  const head = git(repo, ['rev-parse', 'HEAD']);
  fs.mkdirSync(path.join(repo, 'internal', 'domain'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'domain', 'user.go'), 'package domain\nfunc IsValid(s string) bool { return s == "admin" }\n');
  for (const name of ['current-step.json', 'plan-vs-code.json', 'tdd-red.json', 'tdd-green.json', 'verification.json', 'serena-evidence.json']) {
    const file = path.join(repo, '.agent-state', name);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    data.head_sha = head;
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  }
  const greenFile = path.join(repo, '.agent-state', 'tdd-green.json');
  const green = JSON.parse(fs.readFileSync(greenFile, 'utf8'));
  green.coverage = { domain: 100, other: 16.6, scope: 'domain-only' };
  fs.writeFileSync(greenFile, JSON.stringify(green, null, 2));
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['internal/domain/user.go'] }));
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('Stop with mixed scope and other<90 is blocked', () => {
  const repo = mkGitRepo();
  baseMarkers(repo);
  const head = git(repo, ['rev-parse', 'HEAD']);
  fs.mkdirSync(path.join(repo, 'internal', 'adapter', 'http'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'adapter', 'http', 'handler.go'), 'package http\nfunc Handle() {}\n');
  fs.mkdirSync(path.join(repo, 'internal', 'domain'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'domain', 'user.go'), 'package domain\nfunc IsValid(s string) bool { return s == "admin" }\n');
  for (const name of ['current-step.json', 'plan-vs-code.json', 'tdd-red.json', 'tdd-green.json', 'verification.json', 'serena-evidence.json']) {
    const file = path.join(repo, '.agent-state', name);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    data.head_sha = head;
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  }
  const greenFile = path.join(repo, '.agent-state', 'tdd-green.json');
  const green = JSON.parse(fs.readFileSync(greenFile, 'utf8'));
  green.coverage = { domain: 100, other: 16.6, scope: 'mixed' };
  fs.writeFileSync(greenFile, JSON.stringify(green, null, 2));
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['internal/adapter/http/handler.go', 'internal/domain/user.go'] }));
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 2, res.stderr);
  assert.match(res.stderr, /coverage/i, res.stderr);
});

test('Stop rejects domain-only scope claim when non-domain files were changed', () => {
  const repo = mkGitRepo();
  baseMarkers(repo);
  const head = git(repo, ['rev-parse', 'HEAD']);
  fs.mkdirSync(path.join(repo, 'internal', 'adapter', 'http'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'adapter', 'http', 'handler.go'), 'package http\nfunc Handle() {}\n');
  for (const name of ['current-step.json', 'plan-vs-code.json', 'tdd-red.json', 'tdd-green.json', 'verification.json', 'serena-evidence.json']) {
    const file = path.join(repo, '.agent-state', name);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    data.head_sha = head;
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  }
  const greenFile = path.join(repo, '.agent-state', 'tdd-green.json');
  const green = JSON.parse(fs.readFileSync(greenFile, 'utf8'));
  green.coverage = { domain: 100, other: 16.6, scope: 'domain-only' };
  fs.writeFileSync(greenFile, JSON.stringify(green, null, 2));
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['internal/adapter/http/handler.go'] }));
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 2, res.stderr);
  assert.match(res.stderr, /scope|coverage/i, res.stderr);
});

test('Stop with adapter-only scope admits when changed code lives under internal/adapter/', () => {
  const repo = mkGitRepo();
  baseMarkers(repo);
  const head = git(repo, ['rev-parse', 'HEAD']);
  fs.mkdirSync(path.join(repo, 'internal', 'adapter', 'clickhouse'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'adapter', 'clickhouse', 'shipment.go'), 'package clickhouse\nfunc Select() string { return "data_models.dim_partners" }\n');
  fs.mkdirSync(path.join(repo, 'internal', 'ch_migrations'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'ch_migrations', 'runner_test.go'), 'package ch_migrations\n// fixture updated for 000002\n');
  for (const name of ['current-step.json', 'plan-vs-code.json', 'tdd-red.json', 'tdd-green.json', 'verification.json', 'serena-evidence.json']) {
    const file = path.join(repo, '.agent-state', name);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    data.head_sha = head;
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  }
  const greenFile = path.join(repo, '.agent-state', 'tdd-green.json');
  const green = JSON.parse(fs.readFileSync(greenFile, 'utf8'));
  green.coverage = { domain: 100, other: 16.6, scope: 'adapter-only' };
  fs.writeFileSync(greenFile, JSON.stringify(green, null, 2));
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['internal/adapter/clickhouse/shipment.go', 'internal/ch_migrations/runner_test.go'] }));
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 0, res.stderr);
});

test('Stop with adapter-only scope rejects when non-adapter prod code also changed', () => {
  const repo = mkGitRepo();
  baseMarkers(repo);
  const head = git(repo, ['rev-parse', 'HEAD']);
  fs.mkdirSync(path.join(repo, 'internal', 'adapter', 'clickhouse'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'adapter', 'clickhouse', 'shipment.go'), 'package clickhouse\nfunc Select() string { return "x" }\n');
  fs.mkdirSync(path.join(repo, 'internal', 'usecase', 'snapshot'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'internal', 'usecase', 'snapshot', 'refresher.go'), 'package snapshot\nfunc Refresh() {}\n');
  for (const name of ['current-step.json', 'plan-vs-code.json', 'tdd-red.json', 'tdd-green.json', 'verification.json', 'serena-evidence.json']) {
    const file = path.join(repo, '.agent-state', name);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    data.head_sha = head;
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  }
  const greenFile = path.join(repo, '.agent-state', 'tdd-green.json');
  const green = JSON.parse(fs.readFileSync(greenFile, 'utf8'));
  green.coverage = { domain: 100, other: 16.6, scope: 'adapter-only' };
  fs.writeFileSync(greenFile, JSON.stringify(green, null, 2));
  fs.writeFileSync(path.join(repo, '.agent-state', 'changed-behavior.json'), JSON.stringify({ files: ['internal/adapter/clickhouse/shipment.go', 'internal/usecase/snapshot/refresher.go'] }));
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(path.join(repo, 'WORKPLAN.md'), later, later);
  fs.utimesSync(path.join(repo, 'HANDOFF.md'), later, later);
  const res = run(['claude', 'Stop'], { hook_event_name: 'Stop', cwd: repo }, repo);
  assert.strictEqual(res.status, 2, res.stderr);
  assert.match(res.stderr, /adapter-only|scope|coverage/i, res.stderr);
});

test('PostToolUse rejects trivial assertions in tests', () => {
  const repo = mkRepo();
  fs.writeFileSync(path.join(repo, 'tests', 'service.test.ts'), 'test("bad", () => { expect(true).toBe(true); });\n');
  const res = run(['claude', 'PostToolUse'], claudeInput('Edit', { file_path: path.join(repo, 'tests', 'service.test.ts') }, repo), repo);
  assert.strictEqual(res.status, 2);
  assert.match(res.stderr, /trivial assertion/i);
});

test('PostToolUse records Serena evidence automatically', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PostToolUse'], {
    hook_event_name: 'PostToolUse',
    tool_name: 'mcp__serena__find_symbol',
    tool_input: { name_path: 'Service' },
    cwd: repo,
  }, repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const evidence = JSON.parse(fs.readFileSync(path.join(repo, '.agent-state', 'serena-evidence.json'), 'utf8'));
  assert.equal(evidence.tool, 'mcp__serena__find_symbol');
  assert.match(evidence.evidence, /Service/);
});

test('PostToolUse records GitNexus evidence automatically', () => {
  const repo = mkRepo();
  const res = run(['claude', 'PostToolUse'], claudeInput('Bash', {
    command: 'gitnexus impact --repo . --symbol Service',
  }, repo), repo);
  assert.strictEqual(res.status, 0, res.stderr);
  const evidence = JSON.parse(fs.readFileSync(path.join(repo, '.agent-state', 'gitnexus-evidence.json'), 'utf8'));
  assert.equal(evidence.tool, 'Bash');
  assert.match(evidence.evidence, /gitnexus impact/);
});

test('health reports hook telemetry p95', () => {
  const repo = mkRepo();
  const telemetry = path.join(repo, '.agent-state', 'telemetry.jsonl');
  const env = { ...process.env, AGENT_HOOKS_TEST: '1', AGENT_HOOKS_TELEMETRY_FILE: telemetry };
  const pre = spawnSync(process.execPath, [runner, 'claude', 'PreToolUse'], {
    input: JSON.stringify(claudeInput('Bash', { command: 'true' }, repo)),
    cwd: repo,
    env,
    encoding: 'utf8',
  });
  assert.equal(pre.status, 0, pre.stderr);
  const health = spawnSync(process.execPath, [runner, 'health'], {
    cwd: repo,
    env,
    encoding: 'utf8',
  });
  assert.equal(health.status, 0, health.stderr);
  const payload = JSON.parse(health.stdout);
  assert.ok(payload.hook_telemetry.total >= 1);
  assert.ok(payload.hook_telemetry.p95_ms >= 0);
  assert.ok(payload.hook_telemetry.by_event.pretooluse.count >= 1);
});

test('inventory reports project Serena duplicate', () => {
  const repo = mkRepo();
  fs.mkdirSync(path.join(repo, '.claude'), { recursive: true });
  writeJson(path.join(repo, '.claude', 'settings.json'), { enabledPlugins: { 'serena@claude-plugins-official': true } });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', repo, '--fail-on-risk=P0,P1'], {
    cwd: repo,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 2);
  assert.match(res.stdout + res.stderr, /project-scope Serena/i);
});

test('inventory allows user-scope Claude-Mem but rejects hardcoded secrets', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-home-'));
  const userClaude = path.join(root, '.claude');
  fs.mkdirSync(userClaude, { recursive: true });
  writeJson(path.join(userClaude, 'settings.json'), {
    enabledPlugins: { 'claude-mem@thedotmack': true },
    mcpServers: {
      github: { headers: { Authorization: 'Bearer gho_012345678901234567890123456789012345' } }
    }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', root, '--fail-on-risk=P0,P1'], {
    cwd: root,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 2);
  assert.doesNotMatch(res.stdout + res.stderr, /project-scope Claude-Mem/i);
  assert.match(res.stdout + res.stderr, /secret-like value/i);
});

test('inventory rejects broad global permissions', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-global-perms-'));
  const userClaude = path.join(root, '.claude');
  fs.mkdirSync(userClaude, { recursive: true });
  writeJson(path.join(userClaude, 'settings.json'), {
    permissions: {
      allow: [
        'Read(/tmp/**)',
        'Bash(ssh *)',
        'Bash(security find-generic-password *)'
      ]
    }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', root, '--fail-on-risk=P0,P1'], {
    cwd: root,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 2);
  assert.match(res.stdout + res.stderr, /broad permission/i);
});

test('inventory does not treat task-start hook names as OpenAI keys', () => {
  const repo = mkRepo();
  fs.mkdirSync(path.join(repo, '.claude'), { recursive: true });
  writeJson(path.join(repo, '.claude', 'settings.json'), {
    hooks: {
      UserPromptSubmit: [
        { hooks: [{ type: 'command', command: 'bash .claude/hooks/09-task-start-rules-recheck.sh', timeout: 10 }] }
      ]
    }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', repo, '--fail-on-risk=P0,P1'], {
    cwd: repo,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stdout + res.stderr);
});

test('inventory ignores inactive Claude project backup directories', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-profile-'));
  writeJson(path.join(root, 'projects.bak-1778025648', 'old-project', 'settings.json'), {
    hooks: {
      PostToolUse: [
        { hooks: [{ type: 'command', command: 'bash old-hook.sh', timeout: 5000 }] }
      ]
    }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', root, '--fail-on-risk=P0,P1'], {
    cwd: root,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stdout + res.stderr);
});

test('inventory ignores Trash and archive profile directories', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-trash-'));
  writeJson(path.join(root, '.Trash', 'old-project', 'settings.json'), {
    hooks: {
      PostToolUse: [
        { hooks: [{ type: 'command', command: 'bash old-hook.sh', timeout: 600 }] }
      ]
    }
  });
  writeJson(path.join(root, '.claude-ekf.archive-20260514T103440', 'settings.json'), {
    hooks: {
      PreToolUse: [
        { hooks: [{ type: 'command', command: 'serena-hooks remind --client=claude-code' }] }
      ]
    }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', root, '--fail-on-risk=P0,P1'], {
    cwd: root,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stdout + res.stderr);
});

test('inventory ignores non-Claude settings and archive trees', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-non-claude-'));
  fs.mkdirSync(path.join(root, 'pkg', '.vscode'), { recursive: true });
  fs.writeFileSync(path.join(root, 'pkg', '.vscode', 'settings.json'), '{ invalid json');
  writeJson(path.join(root, '_Archive', 'old-repo', '.claude', 'settings.local.json'), {
    permissions: { allow: ['Read(**)'] }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', root, '--fail-on-risk=P0,P1'], {
    cwd: root,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stdout + res.stderr);
});

test('inventory ignores plugin marketplace settings', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-plugin-settings-'));
  writeJson(path.join(root, '.claude', 'plugins', 'marketplaces', 'vendor', '.claude', 'settings.json'), {
    permissions: { allow: ['Read(/tmp/**)', 'Bash(ssh *)'] }
  });
  writeJson(path.join(root, '.codex', '.tmp', 'marketplaces', 'plugin', '.claude', 'settings.json'), {
    permissions: { allow: ['Read(/tmp/**)'] }
  });
  const res = spawnSync(process.execPath, [runner, 'inventory', '--root', root, '--fail-on-risk=P0,P1'], {
    cwd: root,
    env: { ...process.env, AGENT_HOOKS_TEST: '1' },
    encoding: 'utf8'
  });
  assert.strictEqual(res.status, 0, res.stdout + res.stderr);
});

let failed = 0;
for (const t of tests) {
  try {
    t.fn();
    console.log(`ok - ${t.name}`);
  } catch (err) {
    failed++;
    console.error(`not ok - ${t.name}`);
    console.error(err && err.stack ? err.stack : String(err));
  }
}
if (failed) {
  console.error(`${failed}/${tests.length} tests failed`);
  process.exit(1);
}
console.log(`${tests.length} tests passed`);
