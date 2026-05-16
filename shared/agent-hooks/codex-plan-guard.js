'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const UPDATE_PLAN_MARKER_PREFIX = '.update-plan-seen-';
const REQUIRED_PREFIX = '.update-plan-required-';

function preToolUse(ctx) {
  const plan = activePlan(ctx);
  if (!plan.ok) return allow();
  if (isSubagent(ctx)) return allow();
  if (!sessionId(ctx)) return allow();
  if (hasBypass(ctx)) return allow();
  if (!requiresPlanningBeforeTool(ctx)) return allow();
  const target = targetPath(ctx);
  if (target && isPlanOrStateFile(ctx, plan, target)) return allow();
  if (hasSeenMarker(ctx)) return allow();
  writeRequiredMarker(ctx);
  return deny(blockMessage(ctx, plan));
}

function postToolUse(ctx) {
  if (isUpdatePlanTool(ctx.toolName)) {
    writeSeenMarker(ctx);
    clearRequiredMarker(ctx);
    return allow();
  }
  if (!isEditTool(ctx.toolName)) return allow();
  const plan = activePlan(ctx);
  if (!plan.ok) return allow();
  const target = targetPath(ctx);
  if (target && isPlanOrStateFile(ctx, plan, target)) {
    removeSeenMarker(ctx);
    writeRequiredMarker(ctx);
  }
  return allow();
}

function stopGate(ctx) {
  const plan = activePlan(ctx);
  if (!plan.ok) return allow();
  if (hasBypass(ctx) || hasSeenMarker(ctx) || !hasRequiredMarker(ctx)) return allow();
  return deny(blockMessage(ctx, plan));
}

function activePlan(ctx) {
  const repo = path.resolve(ctx.repo || ctx.cwd || process.cwd());
  const pointer = path.join(repo, '.claude', 'active-tracker');
  if (fs.existsSync(pointer)) {
    const value = readText(pointer).trim();
    if (value && value !== '__unstructured__') {
      const tracker = path.resolve(repo, value);
      if (fs.existsSync(tracker)) return { ok: true, repo, tracker, reason: '.claude/active-tracker' };
    }
  }
  for (const name of ['WORKPLAN.md', 'HANDOFF.md']) {
    const file = path.join(repo, name);
    if (fs.existsSync(file)) return { ok: true, repo, tracker: file, reason: name };
  }
  const currentStep = path.join(repo, '.agent-state', 'current-step.json');
  if (fs.existsSync(currentStep)) return { ok: true, repo, tracker: currentStep, reason: '.agent-state/current-step.json' };
  return { ok: false, repo };
}

function requiresPlanningBeforeTool(ctx) {
  if (isEditTool(ctx.toolName)) return true;
  if (isBash(ctx.toolName)) return isMutatingBash(command(ctx));
  return false;
}

function isPlanOrStateFile(ctx, plan, file) {
  const repo = plan.repo || path.resolve(ctx.repo || ctx.cwd || process.cwd());
  const abs = path.resolve(file);
  const allowed = [
    plan.tracker,
    path.join(repo, '.claude', 'active-tracker'),
    path.join(repo, 'WORKPLAN.md'),
    path.join(repo, 'HANDOFF.md'),
    path.join(repo, '.agent-state', 'current-step.json'),
    path.join(repo, '.agent-state', 'plan-vs-code.json'),
    path.join(repo, '.agent-state', 'tdd-red.json'),
    path.join(repo, '.agent-state', 'tdd-green.json'),
    path.join(repo, '.agent-state', 'tdd-waiver.json'),
    path.join(repo, '.agent-state', 'verification.json'),
  ].map(p => path.resolve(p));
  if (allowed.includes(abs)) return true;
  return isInside(abs, path.join(repo, '.claude', 'plans')) || isInside(abs, path.join(repo, '.agent-state'));
}

function markerDir(ctx) {
  return (ctx.env && ctx.env.CODEX_HOME) || process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
}

function sessionId(ctx) {
  return String(
    (ctx.input && (ctx.input.session_id || ctx.input.sessionId || ctx.input.conversation_id || ctx.input.thread_id)) ||
    ctx.session_id ||
    ''
  ).trim();
}

function seenMarkerPath(ctx) {
  const sid = sessionId(ctx);
  if (!sid) return '';
  return path.join(markerDir(ctx), `${UPDATE_PLAN_MARKER_PREFIX}${safeSessionId(sid)}`);
}

function requiredMarkerPath(ctx) {
  const sid = sessionId(ctx);
  if (!sid) return '';
  return path.join(markerDir(ctx), `${REQUIRED_PREFIX}${safeSessionId(sid)}`);
}

function hasSeenMarker(ctx) {
  const marker = seenMarkerPath(ctx);
  return marker ? fs.existsSync(marker) : false;
}

function hasRequiredMarker(ctx) {
  const marker = requiredMarkerPath(ctx);
  return marker ? fs.existsSync(marker) : false;
}

function writeSeenMarker(ctx) {
  const marker = seenMarkerPath(ctx);
  if (!marker) return;
  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.writeFileSync(marker, new Date().toISOString() + '\n');
}

function removeSeenMarker(ctx) {
  const marker = seenMarkerPath(ctx);
  if (!marker) return;
  try { fs.rmSync(marker); } catch {}
}

function writeRequiredMarker(ctx) {
  const marker = requiredMarkerPath(ctx);
  if (!marker) return;
  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.writeFileSync(marker, new Date().toISOString() + '\n');
}

function clearRequiredMarker(ctx) {
  const marker = requiredMarkerPath(ctx);
  if (!marker) return;
  try { fs.rmSync(marker); } catch {}
}

function hasBypass(ctx) {
  return fs.existsSync(path.join(markerDir(ctx), '.update-plan-bypass'));
}

function targetPath(ctx) {
  const raw = ctx.toolInput && (ctx.toolInput.file_path || ctx.toolInput.path || ctx.toolInput.notebook_path);
  if (!raw) return '';
  return path.resolve(ctx.repo || ctx.cwd || process.cwd(), String(raw));
}

function command(ctx) {
  return String((ctx.toolInput && ctx.toolInput.command) || (ctx.input && ctx.input.command) || '');
}

function isEditTool(name) {
  return /^(edit|write|multiedit)$/i.test(String(name || ''));
}

function isBash(name) {
  return /^bash$/i.test(String(name || ''));
}

function isUpdatePlanTool(name) {
  return /(^|\.)(update_plan)$/i.test(String(name || '')) || /^UpdatePlan$/i.test(String(name || ''));
}

function isSubagent(ctx) {
  const value = ctx.input && (ctx.input.parent_tool_use_id || ctx.input.parentToolUseId);
  return Boolean(value && value !== 'null');
}

function isMutatingBash(cmd) {
  return /\b(apply_patch|touch|mkdir|rm|mv|cp|chmod|chown|install_name_tool)\b/i.test(cmd) ||
    /\b(sed|perl)\s+(-i|-pi)\b/i.test(cmd) ||
    /\b(cat|tee)\b[^|;]*>\s*[^&]/i.test(cmd) ||
    /\b(npm|pnpm|yarn|bun)\s+(install|add|remove|update)\b/i.test(cmd) ||
    /\b(go\s+mod\s+tidy|cargo\s+add|pip\s+install)\b/i.test(cmd) ||
    /\b(git\s+(add|commit|merge|rebase|cherry-pick|checkout|clean|reset))\b/i.test(cmd);
}

function blockMessage(ctx, plan) {
  const sid = sessionId(ctx) || '<missing-session-id>';
  const relPlan = relative(plan.repo, plan.tracker);
  const marker = seenMarkerPath(ctx) || path.join(markerDir(ctx), `${UPDATE_PLAN_MARKER_PREFIX}${sid}`);
  return [
    'Codex update_plan gate: active plan exists but this session has no update_plan marker.',
    '',
    `Plan: ${relPlan}`,
    '',
    'Required: call update_plan before risky writes. Use one item per discrete step, with status pending|in_progress|completed.',
    '',
    'Allowed without update_plan: WORKPLAN.md, HANDOFF.md, .agent-state/*, .claude/active-tracker and .claude/plans/*.',
    '',
    `Marker after update_plan: ${marker}`,
    `Bypass, rarely: touch ${path.join(markerDir(ctx), '.update-plan-bypass')} and remove it after the exceptional task.`,
  ].join('\n');
}

function safeSessionId(value) {
  return String(value).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 180);
}

function isInside(file, dir) {
  const rel = path.relative(path.resolve(dir), path.resolve(file));
  return rel && !rel.startsWith('..') && !path.isAbsolute(rel);
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch { return ''; }
}

function relative(repo, file) {
  const rel = path.relative(repo, file);
  return rel && !rel.startsWith('..') ? rel : file;
}

function allow() {
  return { ok: true };
}

function deny(reason) {
  return { ok: false, reason };
}

module.exports = {
  preToolUse,
  postToolUse,
  stopGate,
  activePlan,
  isUpdatePlanTool,
  isMutatingBash,
};
