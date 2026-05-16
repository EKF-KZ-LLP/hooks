import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const guard = require('../codex-plan-guard.js');

function makeRepo() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-plan-guard-'));
  fs.mkdirSync(path.join(repo, '.claude', 'plans'), { recursive: true });
  fs.mkdirSync(path.join(repo, 'src'), { recursive: true });
  fs.writeFileSync(path.join(repo, '.claude', 'active-tracker'), '.claude/plans/current.md\n');
  fs.writeFileSync(path.join(repo, '.claude', 'plans', 'current.md'), '- [ ] TASK-1: do work\n');
  return repo;
}

function makeCtx(repo, overrides = {}) {
  return {
    client: 'codex',
    event: 'PreToolUse',
    cwd: repo,
    repo,
    toolName: 'Edit',
    toolInput: { file_path: path.join(repo, 'src', 'app.ts') },
    input: { session_id: 'session-1' },
    ...overrides,
  };
}

test('no active plan allows edit', () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-plan-guard-no-plan-'));
  const result = guard.preToolUse(makeCtx(repo));
  assert.equal(result.ok, true);
});

test('active plan blocks risky edit before update_plan', () => {
  const repo = makeRepo();
  const result = guard.preToolUse(makeCtx(repo));
  assert.equal(result.ok, false);
  assert.match(result.reason, /update_plan/);
  assert.match(result.reason, /\.codex\/\.update-plan-seen-session-1/);
});

test('missing session id fails open', () => {
  const repo = makeRepo();
  const result = guard.preToolUse(makeCtx(repo, { input: {} }));
  assert.equal(result.ok, true);
});

test('update_plan marker allows edit', () => {
  const repo = makeRepo();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-plan-home-'));
  const ctx = makeCtx(repo, { input: { session_id: 'session-2' }, env: { CODEX_HOME: home } });
  guard.postToolUse({ ...ctx, toolName: 'update_plan' });
  const result = guard.preToolUse(ctx);
  assert.equal(result.ok, true);
});

test('plan file edit is allowed without marker', () => {
  const repo = makeRepo();
  const plan = path.join(repo, '.claude', 'plans', 'current.md');
  const result = guard.preToolUse(makeCtx(repo, { toolInput: { file_path: plan } }));
  assert.equal(result.ok, true);
});

test('plan edit invalidates marker', () => {
  const repo = makeRepo();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-plan-home-'));
  const plan = path.join(repo, '.claude', 'plans', 'current.md');
  const base = makeCtx(repo, { input: { session_id: 'session-3' }, env: { CODEX_HOME: home } });
  guard.postToolUse({ ...base, toolName: 'functions.update_plan' });
  assert.equal(guard.preToolUse(base).ok, true);
  guard.postToolUse({ ...base, toolName: 'Edit', toolInput: { file_path: plan } });
  const result = guard.preToolUse(base);
  assert.equal(result.ok, false);
});

test('bypass sentinel allows edit', () => {
  const repo = makeRepo();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-plan-home-'));
  fs.writeFileSync(path.join(home, '.update-plan-bypass'), '');
  const result = guard.preToolUse(makeCtx(repo, { env: { CODEX_HOME: home } }));
  assert.equal(result.ok, true);
});

test('mutating bash is blocked, read-only bash is allowed', () => {
  const repo = makeRepo();
  const readOnly = guard.preToolUse(makeCtx(repo, {
    toolName: 'Bash',
    toolInput: { command: 'rg "foo" src' },
  }));
  assert.equal(readOnly.ok, true);

  const mutating = guard.preToolUse(makeCtx(repo, {
    toolName: 'Bash',
    toolInput: { command: 'sed -i "" s/foo/bar/g src/app.ts' },
  }));
  assert.equal(mutating.ok, false);
});
