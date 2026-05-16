#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const codexPlanGuard = require('./codex-plan-guard.js');

const STATE_DIR = '.agent-state';
const MAX_MARKER_AGE_MS = 4 * 60 * 60 * 1000;
const SOURCE_EXT = new Set([
  '.c', '.cc', '.cpp', '.cs', '.go', '.h', '.hpp', '.java', '.js', '.jsx',
  '.kt', '.php', '.py', '.rb', '.rs', '.scala', '.swift', '.ts', '.tsx'
]);

function main() {
  const [mode, eventOrArg, ...rest] = process.argv.slice(2);
  if (!mode || mode === 'help' || mode === '--help') {
    usage();
    return 0;
  }
  if (mode === 'inventory') return runInventory([eventOrArg, ...rest].filter(Boolean));
  if (mode === 'health') return runHealth([eventOrArg, ...rest].filter(Boolean));
  if (mode === 'test') return runSelfTests();
  if (mode !== 'claude' && mode !== 'codex') {
    warn(`unknown mode '${mode}'`);
    usage();
    return 2;
  }
  const raw = readStdin();
  const parsed = parseHookJson(raw);
  if (!parsed.ok) {
    warn(`malformed hook JSON: ${parsed.error}`);
    return 0;
  }
  return runHook(mode, normalizeEvent(eventOrArg || parsed.value.hook_event_name || parsed.value.event), parsed.value);
}

function usage() {
  console.error('usage: policy-runner claude <event> | codex <event> | inventory | health | test');
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function parseHookJson(raw) {
  if (!raw || !raw.trim()) return { ok: true, value: {} };
  try {
    return { ok: true, value: JSON.parse(raw) };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

function runHook(client, event, input) {
  const ctx = normalizeInput(client, event, input);
  const started = Date.now();
  let code = 0;
  try {
    if (event === 'userpromptsubmit' || event === 'user_prompt_submit') {
      code = injectGoalReminder(ctx);
      return code;
    }
    if (event === 'pretooluse' || event === 'pre_tool_use') {
      code = preToolUse(ctx);
      return code;
    }
    if (event === 'posttooluse' || event === 'post_tool_use') {
      code = postToolUse(ctx);
      return code;
    }
    if (event === 'stop' || event === 'subagentstop' || event === 'subagent_stop') {
      code = stopGate(ctx);
      return code;
    }
    return 0;
  } finally {
    recordHookTelemetry(ctx, code, Date.now() - started);
  }
}

function normalizeEvent(event) {
  return String(event || '').replace(/[^A-Za-z_]/g, '').toLowerCase();
}

function normalizeInput(client, event, input) {
  const tool = input.tool || input.tool_call || {};
  const toolInput = input.tool_input || input.toolInput || tool.input || input.input || {};
  const toolName = input.tool_name || input.toolName || tool.name || input.name || '';
  const cwd = input.cwd || input.project_dir || input.projectDir || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  return {
    client,
    event,
    input,
    toolName: String(toolName || ''),
    toolInput: toolInput && typeof toolInput === 'object' ? toolInput : {},
    cwd,
    repo: findRepo(cwd)
  };
}

function preToolUse(ctx) {
  if (ctx.client === 'codex') {
    const planGuard = codexPlanGuard.preToolUse(ctx);
    if (!planGuard.ok) return block(planGuard.reason);
  }
  if (isBash(ctx.toolName)) {
    const command = getCommand(ctx);
    if (command && isSecretCommand(command)) return preToolBlock(ctx, 'secret guard: command may expose secrets or credential stores');
    if (command && isUnsafeGitCommand(command, ctx.repo)) {
      return preToolBlock(ctx, 'unsafe git guard: direct main/master push and git --no-verify are blocked');
    }
    if (command && isDestructiveCommand(command) && !hasFreshAny(ctx.repo, ['destructive-waiver.json'])) {
      return preToolBlock(ctx, 'destructive guard: dangerous shell/git/database command requires explicit waiver');
    }
    if (command && isMassRenameCommand(command) && !hasFreshAny(ctx.repo, ['lsp-evidence.json', 'serena-evidence.json', 'gitnexus-evidence.json'])) {
      return preToolBlock(ctx, 'LSP/Serena/GitNexus evidence required before grep/sed/perl mass rename');
    }
    return 0;
  }

  if (!isEditTool(ctx.toolName)) return 0;
  const filePath = resolveTargetFile(ctx);
  if (!filePath || !isBehaviorFile(filePath)) return 0;

  const currentStep = validateCurrentStep(ctx.repo);
  if (!currentStep.ok) return preToolBlock(ctx, `current-step gate: ${currentStep.reason}`);
  const planVsCode = validatePlanVsCode(ctx.repo);
  if (!planVsCode.ok) return preToolBlock(ctx, `plan-vs-code gate: ${planVsCode.reason}`);
  const tddRed = validateTddRed(ctx.repo);
  if (!tddRed.ok) {
    const tddWaiver = validateTddWaiver(ctx.repo);
    if (!tddWaiver.ok) {
      return preToolBlock(ctx, `TDD red gate: ${tddRed.reason}. TDD waiver gate: ${tddWaiver.reason}. For merge/conflict/docs/config-only work create .agent-state/tdd-waiver.json with waiver_type, reason, verification_command, risk_acceptance, checked_at, head_sha.`);
    }
  }
  if (serenaRequired(ctx.repo) && !hasFreshAny(ctx.repo, ['serena-evidence.json', 'gitnexus-evidence.json', 'serena-waiver.json'])) {
    return preToolBlock(ctx, 'Serena-first gate: record Serena/GitNexus context evidence before source edit');
  }
  return 0;
}

function postToolUse(ctx) {
  if (ctx.client === 'codex') {
    const planGuard = codexPlanGuard.postToolUse(ctx);
    if (!planGuard.ok) return block(planGuard.reason);
  }
  recordContextEvidence(ctx);
  if (!isEditTool(ctx.toolName)) return 0;
  const filePath = resolveTargetFile(ctx);
  if (!filePath) return 0;
  if (isTestFile(filePath)) {
    const quality = checkTestQuality(filePath);
    if (!quality.ok) return block(`test-quality gate: ${quality.reason}`);
  }
  if (isBehaviorFile(filePath)) recordChangedBehavior(ctx.repo, filePath);
  return 0;
}

function stopGate(ctx) {
  if (ctx.input && ctx.input.stop_hook_active === true) return 0;
  if (ctx.client === 'codex') {
    const planGuard = codexPlanGuard.stopGate(ctx);
    if (!planGuard.ok) return block(planGuard.reason);
  }
  const repo = ctx.repo;
  if (!repo) return 0;
  const changed = readJson(statePath(repo, 'changed-behavior.json'));
  if (!changed.ok) return 0;
  const errors = [];
  const green = validateTddGreen(repo);
  if (!green.ok) {
    errors.push({
      label: 'tdd-green',
      path: statePath(repo, 'tdd-green.json'),
      reason: green.reason,
    });
  }
  const verification = validateVerification(repo);
  if (!verification.ok) {
    errors.push({
      label: 'verification',
      path: statePath(repo, 'verification.json'),
      reason: verification.reason,
    });
  }
  const docs = validateWorkplanHandoff(repo);
  if (!docs.ok) {
    errors.push({
      label: 'workplan-handoff',
      path: `${path.join(repo, 'WORKPLAN.md')} and ${path.join(repo, 'HANDOFF.md')}`,
      reason: docs.reason,
    });
  }
  if (errors.length) return block(formatStopGateBlock(repo, errors));
  return 0;
}

function formatStopGateBlock(repo, errors) {
  const head = currentHead(repo) || 'UNKNOWN';
  const now = new Date().toISOString();
  const tddGreenPath = statePath(repo, 'tdd-green.json');
  const verificationPath = statePath(repo, 'verification.json');
  const why = errors.map(error => `- ${error.label}: ${error.reason} (${error.path})`).join('\n');
  return [
    'Stop gate blocked final completion: behavior changed, but verification evidence is missing or stale.',
    'This is not a completed final state. Continue the session, refresh evidence for the current HEAD, then retry final completion.',
    '',
    `Repo: ${repo}`,
    `Current HEAD: ${head}`,
    '',
    'Why blocked:',
    why,
    '',
    'Next action:',
    '1. Run `git rev-parse HEAD` and verify it matches the marker `head_sha` you write.',
    '2. Re-run the relevant tests and diagnostics for this exact HEAD.',
    `3. Rewrite \`${tddGreenPath}\` and \`${verificationPath}\` with current evidence.`,
    '4. Update WORKPLAN.md and HANDOFF.md if behavior changed.',
    '',
    'Minimum marker examples:',
    'mkdir -p .agent-state',
    'cat > .agent-state/tdd-green.json <<\'JSON\'',
    JSON.stringify({
      test_command: '<exact test command>',
      observed_pass_excerpt: '<short passing output excerpt>',
      coverage: { domain: 98, other: 90 },
      checked_at: now,
      head_sha: head,
    }, null, 2),
    'JSON',
    '',
    'cat > .agent-state/verification.json <<\'JSON\'',
    JSON.stringify({
      tests: '<test output summary>',
      diagnostics: '<typecheck/lint/diagnostics output or N/A with reason>',
      inventory: '<policy-runner inventory/health output or N/A with reason>',
      checked_at: now,
      head_sha: head,
    }, null, 2),
    'JSON',
  ].join('\n');
}

function injectGoalReminder(ctx) {
  const prompt = String(ctx.input.prompt || ctx.input.user_prompt || ctx.input.message || '');
  if (!prompt || prompt.length < 80) return 0;
  const text = 'Goal-driven execution: before edits, write .agent-state/current-step.json with source_of_truth, success_criteria, verification_command, risk_level and plan_vs_code_status.';
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: text
    }
  }) + '\n');
  return 0;
}

function validateCurrentStep(repo) {
  const marker = markerJson(repo, 'current-step.json');
  if (!marker.ok) return marker;
  for (const key of ['source_of_truth', 'success_criteria', 'verification_command', 'risk_level', 'plan_vs_code_status']) {
    if (!truthy(marker.data[key])) return { ok: false, reason: `${key} missing in .agent-state/current-step.json` };
  }
  return validateHeadAndAge(repo, marker, 'current-step.json');
}

function validatePlanVsCode(repo) {
  const marker = markerJson(repo, 'plan-vs-code.json');
  if (!marker.ok) return marker;
  if (!Array.isArray(marker.data.files_inspected) || marker.data.files_inspected.length === 0) {
    return { ok: false, reason: 'files_inspected missing in .agent-state/plan-vs-code.json' };
  }
  if (!Object.prototype.hasOwnProperty.call(marker.data, 'deviation_note')) {
    return { ok: false, reason: 'deviation_note missing in .agent-state/plan-vs-code.json' };
  }
  return validateHeadAndAge(repo, marker, 'plan-vs-code.json');
}

function validateTddRed(repo) {
  const marker = markerJson(repo, 'tdd-red.json');
  if (!marker.ok) return marker;
  for (const key of ['test_command', 'test_file', 'expected_failure', 'observed_failure_excerpt']) {
    if (!truthy(marker.data[key])) return { ok: false, reason: `${key} missing in .agent-state/tdd-red.json` };
  }
  if (marker.data.created_before_code_edit !== true) {
    return { ok: false, reason: 'created_before_code_edit must be true in .agent-state/tdd-red.json' };
  }
  return validateHeadAndAge(repo, marker, 'tdd-red.json');
}

function validateTddWaiver(repo) {
  const marker = markerJson(repo, 'tdd-waiver.json');
  if (!marker.ok) return marker;
  const allowedTypes = new Set(['merge-conflict-resolution', 'docs-only', 'config-only', 'dead-code-deletion', 'non-behavior-change']);
  if (!allowedTypes.has(String(marker.data.waiver_type || ''))) {
    return { ok: false, reason: 'waiver_type must be one of merge-conflict-resolution, docs-only, config-only, dead-code-deletion, non-behavior-change' };
  }
  for (const key of ['reason', 'verification_command', 'risk_acceptance']) {
    if (!truthy(marker.data[key])) return { ok: false, reason: `${key} missing in .agent-state/tdd-waiver.json` };
  }
  return validateHeadAndAge(repo, marker, 'tdd-waiver.json');
}

function validateTddGreen(repo) {
  const marker = markerJson(repo, 'tdd-green.json');
  if (!marker.ok) return marker;
  if (!truthy(marker.data.test_command) || !truthy(marker.data.observed_pass_excerpt)) {
    return { ok: false, reason: 'test_command and observed_pass_excerpt required in .agent-state/tdd-green.json' };
  }
  const coverage = marker.data.coverage || {};
  const claimedScope = String(coverage.scope || '').toLowerCase();
  if (Number(coverage.domain || 0) < 98) {
    return { ok: false, reason: 'coverage below target domain>=98' };
  }
  if (claimedScope === 'domain-only') {
    const detectedScope = detectChangedCodeScope(repo);
    if (detectedScope === 'mixed') {
      return { ok: false, reason: 'tdd-green coverage.scope=domain-only inconsistent with detected non-domain code changes; restate scope=mixed and meet other>=90' };
    }
  } else if (claimedScope === 'adapter-only') {
    const layered = detectChangedCodeLayer(repo);
    if (layered === 'non-adapter') {
      return { ok: false, reason: 'tdd-green coverage.scope=adapter-only inconsistent with detected non-adapter code changes (paths outside internal/adapter/ and internal/ch_migrations/); restate scope=mixed and meet other>=90 or scope=domain-only' };
    }
  } else if (Number(coverage.other || 0) < 90) {
    return { ok: false, reason: 'coverage below target domain>=98 other>=90' };
  }
  return validateHeadAndAge(repo, marker, 'tdd-green.json');
}

// detectChangedCodeLayer partitions touched code by adapter vs non-adapter.
// Returns one of:
//   'adapter-only'  - non-domain code touched is strictly under internal/adapter/
//                     or internal/ch_migrations/ or internal/migrations/ (test files
//                     in the same trees count). Domain changes are allowed and ignored.
//   'non-adapter'   - some non-domain prod code lives outside the adapter layer
//                     (e.g. usecase/, cmd/, server/) - scope=adapter-only is dishonest.
//   'no-code-change' - no production code touched at all.
function detectChangedCodeLayer(repo) {
  if (!repo) return 'unknown';
  const collected = new Set();
  const status = spawnSync('git', ['-C', repo, 'status', '--porcelain', '-uall'], { encoding: 'utf8', timeout: 1500 });
  if (status.status === 0) {
    for (const line of String(status.stdout || '').split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const parts = trimmed.split(/\s+/);
      const rel = parts[parts.length - 1];
      if (rel) collected.add(rel);
    }
  }
  const diff = spawnSync('git', ['-C', repo, 'diff', '--name-only', 'HEAD~1..HEAD'], { encoding: 'utf8', timeout: 1500 });
  if (diff.status === 0) {
    for (const line of String(diff.stdout || '').split('\n')) {
      const rel = line.trim();
      if (rel) collected.add(rel);
    }
  }
  if (collected.size === 0) return 'no-code-change';
  const codeExt = /\.(go|py|ts|tsx|js|jsx|java|kt|rs|rb|cs)$/i;
  const domainPattern = /(^|\/)(domain|internal\/domain)(\/|_test\.[^\/]+$|$)/i;
  const adapterPattern = /(^|\/)internal\/adapter\//i;
  const migrationsPattern = /(^|\/)internal\/(ch_migrations|migrations)\//i;
  let sawCode = false;
  let sawNonAdapterProd = false;
  for (const rel of collected) {
    if (rel.startsWith('.agent-state/') || rel.startsWith('.checkpoints/') || rel.startsWith('docs/') ||
        rel.startsWith('.claude/') || rel === 'WORKPLAN.md' || rel === 'HANDOFF.md') {
      continue;
    }
    if (!codeExt.test(rel)) continue;
    sawCode = true;
    if (domainPattern.test(rel)) continue;
    if (adapterPattern.test(rel) || migrationsPattern.test(rel)) continue;
    sawNonAdapterProd = true;
  }
  if (!sawCode) return 'no-code-change';
  return sawNonAdapterProd ? 'non-adapter' : 'adapter-only';
}

function detectChangedCodeScope(repo) {
  if (!repo) return 'unknown';
  const collected = new Set();
  const status = spawnSync('git', ['-C', repo, 'status', '--porcelain', '-uall'], { encoding: 'utf8', timeout: 1500 });
  if (status.status === 0) {
    for (const line of String(status.stdout || '').split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const parts = trimmed.split(/\s+/);
      const rel = parts[parts.length - 1];
      if (rel) collected.add(rel);
    }
  }
  const diff = spawnSync('git', ['-C', repo, 'diff', '--name-only', 'HEAD~1..HEAD'], { encoding: 'utf8', timeout: 1500 });
  if (diff.status === 0) {
    for (const line of String(diff.stdout || '').split('\n')) {
      const rel = line.trim();
      if (rel) collected.add(rel);
    }
  }
  if (collected.size === 0) return 'no-code-change';
  const codeExt = /\.(go|py|ts|tsx|js|jsx|java|kt|rs|rb|cs)$/i;
  const domainPattern = /(^|\/)(domain|internal\/domain)(\/|_test\.[^\/]+$|$)/i;
  let sawCode = false;
  let sawNonDomain = false;
  for (const rel of collected) {
    if (rel.startsWith('.agent-state/') || rel.startsWith('.checkpoints/') || rel.startsWith('docs/') ||
        rel.startsWith('.claude/') || rel === 'WORKPLAN.md' || rel === 'HANDOFF.md') {
      continue;
    }
    if (!codeExt.test(rel)) continue;
    sawCode = true;
    if (!domainPattern.test(rel)) {
      sawNonDomain = true;
    }
  }
  if (!sawCode) return 'no-code-change';
  return sawNonDomain ? 'mixed' : 'domain-only';
}

function validateVerification(repo) {
  const marker = markerJson(repo, 'verification.json');
  if (!marker.ok) return marker;
  for (const key of ['tests', 'diagnostics', 'inventory']) {
    if (!truthy(marker.data[key])) return { ok: false, reason: `${key} missing in .agent-state/verification.json` };
  }
  return validateHeadAndAge(repo, marker, 'verification.json');
}

function validateWorkplanHandoff(repo) {
  const changedPath = statePath(repo, 'changed-behavior.json');
  const changedMtime = safeMtimeMs(changedPath);
  for (const name of ['WORKPLAN.md', 'HANDOFF.md']) {
    const file = path.join(repo, name);
    if (!fs.existsSync(file)) return { ok: false, reason: `${name} missing` };
    if (changedMtime && safeMtimeMs(file) < changedMtime) return { ok: false, reason: `${name} older than behavior-change marker` };
  }
  return { ok: true };
}

function markerJson(repo, name) {
  if (!repo) return { ok: false, reason: 'repo not found' };
  const file = statePath(repo, name);
  const data = readJson(file);
  if (!data.ok) return { ok: false, reason: `${name} missing or invalid JSON` };
  return { ok: true, path: file, data: data.data };
}

function validateHeadAndAge(repo, marker, name) {
  const current = currentHead(repo);
  if (current && marker.data.head_sha && marker.data.head_sha !== 'UNKNOWN' && marker.data.head_sha !== current) {
    return { ok: false, reason: `${name} head_sha '${marker.data.head_sha}' != current '${current}'` };
  }
  const age = Date.now() - safeMtimeMs(marker.path);
  if (Number.isFinite(age) && age > MAX_MARKER_AGE_MS) return { ok: false, reason: `${name} older than 4h` };
  return { ok: true };
}

function checkTestQuality(filePath) {
  if (!fs.existsSync(filePath)) return { ok: true };
  const text = fs.readFileSync(filePath, 'utf8');
  const ext = path.extname(filePath);
  if (/expect\((true|false|[0-9]+|"[^"]*"|'[^']*')\)\.to(Be|Equal|StrictEqual)\(\1\)/.test(text)) {
    return { ok: false, reason: 'trivial assertion detected' };
  }
  if (/assert\s+True\b|assert\s+1\s*==\s*1/.test(text)) return { ok: false, reason: 'trivial assertion detected' };
  if (/func\s+Test[A-Za-z0-9_]+\([^)]*\)\s*\{\s*\}/.test(text)) return { ok: false, reason: 'empty test body detected' };
  if (/(it|test)\(['"][^'"]+['"]\s*,\s*(async\s*)?\([^)]*\)\s*=>\s*\{\s*\}\)/.test(text)) {
    return { ok: false, reason: 'empty test body detected' };
  }
  if (/def\s+test_[A-Za-z0-9_]+\([^)]*\):\s*(pass|\.\.\.)/.test(text)) return { ok: false, reason: 'empty test body detected' };
  if (/(it|describe|test)\.skip|xit\(|xdescribe\(|t\.Skip|pytest\.mark\.skip|pytest\.skip/.test(text) && !/#\d+/.test(text)) {
    return { ok: false, reason: 'skip without ticket detected' };
  }
  if ((ext === '.ts' || ext === '.tsx' || ext === '.js' || ext === '.jsx') &&
      /toHaveBeenCalled/.test(text) && !/(render\(|renderHook\(|await\s+[a-zA-Z_]|new\s+[A-Z])/.test(text)) {
    return { ok: false, reason: 'mock-only test detected' };
  }
  return { ok: true };
}

function recordChangedBehavior(repo, filePath) {
  if (!repo) return;
  const file = statePath(repo, 'changed-behavior.json');
  const prior = readJson(file);
  const files = new Set(Array.isArray(prior.data && prior.data.files) ? prior.data.files : []);
  files.add(path.relative(repo, filePath));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ files: [...files], updated_at: new Date().toISOString() }, null, 2) + '\n');
}

function recordContextEvidence(ctx) {
  if (!ctx.repo) return;
  const tool = ctx.toolName || '';
  const command = getCommand(ctx);
  if (/^mcp__serena__/i.test(tool)) {
    writeEvidence(ctx.repo, 'serena-evidence.json', {
      tool,
      evidence: summarizeEvidence(ctx.toolInput) || tool,
    });
  }
  if (/^mcp__gitnexus__/i.test(tool) || /^\s*gitnexus\b/i.test(command)) {
    writeEvidence(ctx.repo, 'gitnexus-evidence.json', {
      tool: tool || 'Bash',
      evidence: command || summarizeEvidence(ctx.toolInput) || tool,
    });
  }
}

function writeEvidence(repo, name, data) {
  const file = statePath(repo, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const current = currentHead(repo) || 'UNKNOWN';
  fs.writeFileSync(file, JSON.stringify({
    ...data,
    checked_at: new Date().toISOString(),
    head_sha: current,
  }, null, 2) + '\n');
}

function summarizeEvidence(input) {
  try {
    const text = JSON.stringify(input || {});
    return text.length > 500 ? `${text.slice(0, 500)}...` : text;
  } catch {
    return '';
  }
}

function runInventory(args) {
  const root = argValue(args, '--root') || process.cwd();
  const failSpec = argValue(args, '--fail-on-risk') || '';
  const failRisks = new Set(failSpec.split(',').map(s => s.trim()).filter(Boolean));
  const findings = scanInventory(path.resolve(root));
  for (const finding of findings) {
    const line = `${finding.risk} ${finding.kind}: ${finding.path}`;
    if (finding.detail) console.log(`${line} - ${finding.detail}`);
    else console.log(line);
  }
  if (findings.some(f => failRisks.has(f.risk))) return 2;
  return 0;
}

function scanInventory(root) {
  const findings = [];
  for (const file of walk(root, isSettingsFile, 8)) {
    const parsed = readJson(file);
    if (!parsed.ok) {
      findings.push({ risk: 'P1', kind: 'invalid JSON settings', path: file });
      continue;
    }
    const settings = parsed.data;
    scanSecretLikeSettings(file, settings, findings);
    const enabled = settings.enabledPlugins || settings.plugins || {};
    const userScope = isUserScopeSettings(file, root);
    if (!userScope && (enabled['serena@claude-plugins-official'] === true || enabled['serena@claude-plugins-official']?.enabled === true)) {
      findings.push({ risk: 'P1', kind: 'project-scope Serena plugin duplicate', path: file, detail: 'Serena must stay user/global scope' });
    }
    if (!userScope && (enabled['claude-mem@thedotmack'] === true || enabled['claude-mem@thedotmack']?.enabled === true)) {
      findings.push({ risk: 'P1', kind: 'project-scope Claude-Mem plugin duplicate', path: file, detail: 'Claude-Mem must stay user/global scope' });
    }
    if (settings.permissions && settings.permissions.defaultMode === 'bypassPermissions') {
      findings.push({ risk: 'P0', kind: 'bypassPermissions enabled', path: file });
    }
    scanPermissions(file, settings, findings);
    scanHookTimeouts(file, settings, findings);
  }
  return findings;
}

function scanSecretLikeSettings(file, settings, findings) {
  const text = JSON.stringify(settings);
  if (/sk-[A-Za-z0-9_-]{32,}|xox[baprs]-|gh[pousr]_[A-Za-z0-9_]{20,}|TELEGRAM_BOT_TOKEN|bot[0-9]{6,}:/i.test(text)) {
    findings.push({ risk: 'P0', kind: 'secret-like value in settings', path: file });
  }
}

function scanPermissions(file, settings, findings) {
  const allow = Array.isArray(settings.permissions?.allow) ? settings.permissions.allow : [];
  const text = JSON.stringify(allow);
  if (/Read\([^)]*\/\*\*\)|Read\([^)]*\*\*\)|\.ssh|security find-generic-password|keychain|Bash\(ssh\s|Bash\(scp\s|Bash\(rsync\s|Bash\(kubectl\s|Bash\(infisical\s|Bash\(security\s|Bash\(rm\s+-f\s|Bash\(rm\s+-rf\s/i.test(text)) {
    findings.push({ risk: 'P1', kind: 'broad permission', path: file });
  }
}

function scanHookTimeouts(file, settings, findings) {
  if (!settings.hooks || typeof settings.hooks !== 'object') return;
  for (const entries of Object.values(settings.hooks)) {
    if (!Array.isArray(entries)) continue;
    for (const entry of entries) {
      for (const hook of entry.hooks || []) {
        if (!hook || hook.type !== 'command') continue;
        if (hook.timeout === undefined) findings.push({ risk: 'P1', kind: 'hook without timeout', path: file, detail: hook.command || '' });
        const timeout = Number(hook.timeout);
        if (timeout >= 120) findings.push({ risk: 'P1', kind: 'long hook timeout', path: file, detail: `${timeout}s ${hook.command || ''}` });
      }
    }
  }
}

function runHealth() {
  const db = path.join(os.homedir(), '.claude-mem', 'claude-mem.db');
  const status = { checked_at: new Date().toISOString(), claude_mem_db: fs.existsSync(db) ? 'present' : 'missing' };
  const curl = spawnSync('curl', ['-fsS', 'http://127.0.0.1:37701/health'], { encoding: 'utf8', timeout: 3000 });
  status.claude_mem_health = curl.status === 0 ? safeParse(curl.stdout) || curl.stdout.trim() : 'unavailable';
  status.hook_telemetry = readHookTelemetry();
  console.log(JSON.stringify(status, null, 2));
  return 0;
}

function telemetryFile() {
  return process.env.AGENT_HOOKS_TELEMETRY_FILE ||
    path.join(os.homedir(), '.local', 'state', 'agent-hooks', 'policy-runner-telemetry.jsonl');
}

function recordHookTelemetry(ctx, statusCode, durationMs) {
  const file = telemetryFile();
  const entry = {
    ts: new Date().toISOString(),
    client: ctx.client,
    event: normalizeEvent(ctx.event),
    tool: ctx.toolName || '',
    status: statusCode,
    duration_ms: durationMs,
  };
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(file, JSON.stringify(entry) + '\n');
  } catch {
    // Telemetry must never block the hook.
  }
}

function readHookTelemetry() {
  const file = telemetryFile();
  let lines = [];
  try {
    lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/).filter(Boolean).slice(-500);
  } catch {
    return { total: 0, p95_ms: 0, by_event: {} };
  }
  const entries = lines.map(line => safeParse(line)).filter(Boolean);
  const durations = entries.map(entry => Number(entry.duration_ms || 0)).filter(Number.isFinite).sort((a, b) => a - b);
  const byEvent = {};
  for (const entry of entries) {
    const event = normalizeEvent(entry.event);
    if (!byEvent[event]) byEvent[event] = { count: 0, p95_ms: 0, slow: 0 };
    byEvent[event].count += 1;
  }
  for (const event of Object.keys(byEvent)) {
    const eventDurations = entries
      .filter(entry => normalizeEvent(entry.event) === event)
      .map(entry => Number(entry.duration_ms || 0))
      .filter(Number.isFinite)
      .sort((a, b) => a - b);
    const p95 = percentile(eventDurations, 95);
    byEvent[event].p95_ms = p95;
    byEvent[event].slow = eventDurations.filter(value => value > hookBudgetMs(event)).length;
  }
  return {
    total: entries.length,
    p95_ms: percentile(durations, 95),
    by_event: byEvent,
  };
}

function percentile(values, pct) {
  if (!values.length) return 0;
  const index = Math.min(values.length - 1, Math.ceil((pct / 100) * values.length) - 1);
  return values[index];
}

function hookBudgetMs(event) {
  if (event === 'pretooluse' || event === 'posttooluse') return 5000;
  if (event === 'userpromptsubmit' || event === 'sessionstart' || event === 'stop') return 20000;
  return 10000;
}

function runSelfTests() {
  const testFile = path.join(__dirname, 'policy-runner.test.js');
  const res = spawnSync(process.execPath, [testFile], { stdio: 'inherit' });
  return res.status || 0;
}

function argValue(args, key) {
  const eq = args.find(a => a.startsWith(`${key}=`));
  if (eq) return eq.slice(key.length + 1);
  const idx = args.indexOf(key);
  return idx >= 0 ? args[idx + 1] : '';
}

function findRepo(start) {
  let dir = path.resolve(start || process.cwd());
  if (fs.existsSync(dir) && fs.statSync(dir).isFile()) dir = path.dirname(dir);
  for (;;) {
    if (fs.existsSync(path.join(dir, '.git')) || fs.existsSync(path.join(dir, 'WORKPLAN.md')) || fs.existsSync(path.join(dir, 'HANDOFF.md'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return path.resolve(start || process.cwd());
    dir = parent;
  }
}

function statePath(repo, name) {
  return path.join(repo, STATE_DIR, name);
}

function readJson(file) {
  try {
    return { ok: true, data: JSON.parse(fs.readFileSync(file, 'utf8')) };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

function safeParse(text) {
  try { return JSON.parse(text); } catch { return null; }
}

function currentHead(repo) {
  const res = spawnSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8', timeout: 1500 });
  return res.status === 0 ? res.stdout.trim() : '';
}

function safeMtimeMs(file) {
  try { return fs.statSync(file).mtimeMs; } catch { return 0; }
}

function truthy(value) {
  return value !== undefined && value !== null && String(value).trim() !== '';
}

function isBash(name) {
  return /^bash$/i.test(name || '');
}

function isEditTool(name) {
  return /^(edit|write|multiedit)$/i.test(name || '');
}

function getCommand(ctx) {
  return String(ctx.toolInput.command || ctx.input.command || '');
}

function resolveTargetFile(ctx) {
  const raw = ctx.toolInput.file_path || ctx.toolInput.path || ctx.toolInput.notebook_path || '';
  if (!raw) return '';
  return path.resolve(ctx.repo || ctx.cwd, String(raw));
}

function isTestFile(file) {
  const base = path.basename(file);
  return /(^test_.*\.py$|_test\.py$|_test\.go$|\.test\.[jt]sx?$|\.spec\.[jt]sx?$)/.test(base) || /\/(test|tests)\//.test(file);
}

function isBehaviorFile(file) {
  if (isTestFile(file)) return false;
  const norm = file.split(path.sep).join('/');
  if (/\/(docs|doc|config|configs|scripts|\.claude|\.agent-state)\//.test(norm)) return false;
  return SOURCE_EXT.has(path.extname(file));
}

function isSecretCommand(command) {
  return /\b(cat|less|more|tail|head|grep|rg|awk|sed)\b.*(\.env|id_rsa|id_ed25519|\.pem|\.p12|\.ssh|keychain|token|secret|password)/i.test(command) ||
    /security\s+find-generic-password|ssh-add\s+-l|printenv\s+.*(TOKEN|SECRET|PASSWORD|KEY)/i.test(command);
}

function isDestructiveCommand(command) {
  return /git\s+reset\s+--hard|git\s+checkout\s+--|git\s+clean\s+-[fd]|git\s+push\s+.*--force|rm\s+-rf\s+(\/|\$HOME|~|\*)|drop\s+database|truncate\s+table/i.test(command);
}

function isUnsafeGitCommand(command, repo) {
  if (/\bgit\s+(commit|merge|rebase|push)\b[^\n;&|]*--no-verify\b/i.test(command)) return true;
  return gitPushTargetsMain(command, repo);
}

function gitPushTargetsMain(command, repo) {
  for (const segment of String(command || '').split(/[;&|]+/)) {
    const tokens = shellWords(segment);
    for (let i = 0; i < tokens.length - 1; i += 1) {
      if (tokens[i] !== 'git' || tokens[i + 1] !== 'push') continue;
      const args = tokens.slice(i + 2);
      if (args.some(arg => arg === '--mirror' || arg === '--all')) return true;
      const explicitRefs = args.filter(arg => arg && !arg.startsWith('-'));
      if (explicitRefs.some(isMainPushRef)) return true;
      if (explicitRefs.length <= 1 && isCurrentMainBranch(repo)) return true;
    }
  }
  return false;
}

function shellWords(text) {
  const words = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let match;
  while ((match = re.exec(String(text || ''))) !== null) {
    words.push(String(match[1] ?? match[2] ?? match[3] ?? '').toLowerCase());
  }
  return words;
}

function isMainPushRef(arg) {
  const ref = String(arg || '').toLowerCase();
  if (ref === 'main' || ref === 'master' || ref === 'refs/heads/main' || ref === 'refs/heads/master') return true;
  const dst = ref.includes(':') ? ref.split(':').pop() : '';
  return dst === 'main' || dst === 'master' || dst === 'refs/heads/main' || dst === 'refs/heads/master';
}

function isCurrentMainBranch(repo) {
  if (!repo) return false;
  const res = spawnSync('git', ['-C', repo, 'rev-parse', '--abbrev-ref', 'HEAD'], { encoding: 'utf8', timeout: 1500 });
  if (res.status !== 0) return false;
  return /^(main|master)$/.test(res.stdout.trim());
}

function isMassRenameCommand(command) {
  return /(rg|grep|find|fd).*(xargs|while read|parallel).*(sed|perl|python|node)|sed\s+-i|perl\s+-pi/i.test(command) &&
    /(s\/[^/]+\/[^/]+\/|replace\(|rename|mv\s)/i.test(command);
}

function hasFreshAny(repo, names) {
  if (!repo) return false;
  return names.some(name => {
    const file = statePath(repo, name);
    if (!fs.existsSync(file)) return false;
    return Date.now() - safeMtimeMs(file) <= MAX_MARKER_AGE_MS;
  });
}

function serenaRequired(repo) {
  if (!repo) return false;
  if (fs.existsSync(path.join(repo, '.agent-state', 'serena-not-required.json'))) return false;
  const codexCfg = path.join(os.homedir(), '.codex', 'config.toml');
  if (fs.existsSync(codexCfg) && /mcp_servers\.serena|serena/.test(fs.readFileSync(codexCfg, 'utf8'))) return true;
  return fs.existsSync(path.join(os.homedir(), '.claude', 'settings.json'));
}

function isSettingsFile(file) {
  return /(^|\/)\.claude(?:-[^/]+)?\/settings(\.local)?\.json$/.test(file);
}

function isUserScopeSettings(file, root) {
  const dir = path.dirname(path.resolve(file));
  const rootDir = path.resolve(root || process.cwd());
  const base = path.basename(dir);
  if (!/^\.claude($|-)/.test(base)) return false;
  if (path.dirname(dir) === rootDir && looksLikeRepo(rootDir)) return false;
  return dir === rootDir || path.dirname(dir) === rootDir || dir === path.join(os.homedir(), base);
}

function looksLikeRepo(dir) {
  return fs.existsSync(path.join(dir, '.git')) ||
    fs.existsSync(path.join(dir, 'WORKPLAN.md')) ||
    fs.existsSync(path.join(dir, 'HANDOFF.md'));
}

function walk(root, predicate, maxDepth) {
  const out = [];
  const skip = new Set(['.git', 'node_modules', 'dist', 'build', '.venv', 'venv', '.cache', '.Trash', 'shell-snapshots', 'sessions', 'file-history', 'backups', 'claude.old']);
  const skipPattern = /^(projects|settings|claude|hooks)\.bak-\d+$|^_?backup[s]?(?:[-_.]\d+)?$|^_?archive[s]?$|\.archive-\d/i;
  function rec(dir, depth) {
    if (depth > maxDepth) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (skip.has(entry.name) || skipPattern.test(entry.name) || entry.name.includes('worktrees') || entry.name.startsWith('_backup') || entry.name === '_archive') continue;
        if (full.includes(`${path.sep}plugins${path.sep}`) || full.includes(`${path.sep}.codex${path.sep}.tmp${path.sep}`)) continue;
        rec(full, depth + 1);
      } else if (predicate(full)) {
        out.push(full);
      }
    }
  }
  rec(root, 0);
  return out;
}

function block(message) {
  console.error(`BLOCKED: ${message}`);
  return 2;
}

function preToolBlock(ctx, message) {
  const reason = `${message}\n\n${remediationFor(ctx, message)}`.trim();
  if (ctx.client === 'claude') {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason
      }
    }) + '\n');
    return 0;
  }
  return block(reason);
}

function remediationFor(ctx, message) {
  const head = currentHead(ctx.repo) || 'UNKNOWN';
  const now = new Date().toISOString();
  if (/current-step gate/i.test(message)) {
    return `Remediation: inspect the real source of truth, then create the step contract before editing:\nmkdir -p .agent-state\ncat > .agent-state/current-step.json <<'JSON'\n${JSON.stringify({
      source_of_truth: '<request, issue, plan, and code inspected>',
      success_criteria: '<observable done criteria>',
      verification_command: '<exact command to run before final>',
      risk_level: '<low|medium|high>',
      plan_vs_code_status: '<checked|needs-update>',
      checked_at: now,
      head_sha: head
    }, null, 2)}\nJSON`;
  }
  if (/plan-vs-code gate/i.test(message)) {
    return `Remediation: compare the plan with current code, then record the alignment check:\nmkdir -p .agent-state\ncat > .agent-state/plan-vs-code.json <<'JSON'\n${JSON.stringify({
      files_inspected: ['<relative/source/file>'],
      deviation_note: 'NONE',
      checked_at: now,
      head_sha: head
    }, null, 2)}\nJSON`;
  }
  if (/TDD red gate|TDD waiver gate/i.test(message)) {
    return `Remediation for behavior work: write or update a real failing test, run it, then record red evidence:\nmkdir -p .agent-state\ncat > .agent-state/tdd-red.json <<'JSON'\n${JSON.stringify({
      test_command: '<test command that currently fails>',
      test_file: '<test file path>',
      expected_failure: '<behavior missing before implementation>',
      observed_failure_excerpt: '<actual failing output excerpt>',
      created_before_code_edit: true,
      checked_at: now,
      head_sha: head
    }, null, 2)}\nJSON\n\nFor non-behavior work only, record an explicit waiver instead:\ncat > .agent-state/tdd-waiver.json <<'JSON'\n${JSON.stringify({
      waiver_type: 'merge-conflict-resolution',
      reason: '<why this edit is not behavior-changing>',
      verification_command: '<exact verification after edit>',
      risk_acceptance: '<why waiver is acceptable>',
      checked_at: now,
      head_sha: head
    }, null, 2)}\nJSON`;
  }
  if (/Serena-first gate/i.test(message)) {
    return `Remediation: use Serena or GitNexus for symbol/context inspection, then record evidence:\nmkdir -p .agent-state\ncat > .agent-state/serena-evidence.json <<'JSON'\n${JSON.stringify({
      tool: '<mcp__serena__... or gitnexus>',
      evidence: '<symbols/files/impact inspected>',
      checked_at: now,
      head_sha: head
    }, null, 2)}\nJSON`;
  }
  if (/LSP\/Serena\/GitNexus evidence/i.test(message)) {
    return `Remediation: perform the rename/refactor through LSP, Serena, or GitNexus-backed tooling, then record evidence in .agent-state/lsp-evidence.json, .agent-state/serena-evidence.json, or .agent-state/gitnexus-evidence.json.`;
  }
  if (/destructive guard/i.test(message)) {
    return `Remediation: avoid the destructive command, or create .agent-state/destructive-waiver.json with checked_at, head_sha, command, reason, backup_or_rollback, and explicit_user_approval.`;
  }
  if (/secret guard/i.test(message)) {
    return 'Remediation: do not print secrets. Query only metadata or use the approved secret manager/MCP path.';
  }
  return 'Remediation: satisfy the missing evidence marker, then retry the tool call.';
}

function warn(message) {
  console.error(`WARN: ${message}`);
}

const code = main();
process.exit(code);
