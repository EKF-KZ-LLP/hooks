#!/usr/bin/env node
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ACTION_TO_EVENT = {
  context: "SessionStart",
  "session-init": "UserPromptSubmit",
  observation: "PostToolUse",
  summarize: "Stop",
};
const DEFAULT_ALLOWED_OBSERVATION_TOOLS = new Set(["Bash", "Edit", "Write", "MultiEdit"]);
const DEFAULT_MAX_STRING_CHARS = 12000;
const DEFAULT_SUMMARY_MAX_STRING_CHARS = 6000;
const DEFAULT_SUMMARY_LAST_MESSAGE_CHARS = 4000;
const DEFAULT_CHILD_TIMEOUT_MS = 25000;
const DEFAULT_BASH_MIN_INTERVAL_MS = 30000;
const SUMMARY_STRING_FIELDS = new Set([
  "last_user_message",
  "last_assistant_message",
  "assistant_response",
  "tool_response",
  "transcript",
]);
const SUMMARY_CONTRACT = [
  "Return exactly one XML root.",
  "Allowed roots: <summary>...</summary> or <skip_summary reason=\"not_durable\" />.",
  "No prose, no markdown, no ALLOW/DENY text.",
  "Record only durable facts learned, built, fixed, deployed or configured.",
].join(" ");
const HIGH_SIGNAL_BASH_PATTERNS = [
  /\b(go\s+test|go\s+vet|go\s+build)\b/,
  /\b(pytest|pyright|ruff|mypy)\b/,
  /\b(npm|pnpm|yarn|bun)\s+(run\s+)?(test|build|lint|typecheck)\b/,
  /\b(tsc|eslint)\b/,
  /\b(cargo|swift)\s+(test|build)\b/,
  /\bmake\s+(test|build|check|verify)\b/,
  /^git\s+(commit|merge|rebase|cherry-pick|tag|push|pull)\b/,
];
const LOW_SIGNAL_BASH_PATTERNS = [
  /^sleep\s+\d+$/,
  /^date(\s|$)/,
  /^pwd$/,
  /^true$/,
  /^false$/,
  /^sqlite3\s+\/Users\/antonsahovskii\/\.claude-mem\/claude-mem\.db\b/,
  /^tail\s+.+\/Users\/antonsahovskii\/\.claude-mem\/logs\//,
  /^(rg|grep|fd|find)\b/,
  /^git\s+(status|diff|log|show|rev-parse|branch|remote)(\s|$)/,
  /^(ls|wc|head|tail|cat|nl|stat|du|tree)(\s|$)/,
  /^sed\s+-n\b/,
  /^(jq|ps|pgrep)(\s|$)/,
];

function sanitizeCodexOutput(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return {};
  const output = { ...payload };
  delete output.suppressOutput;
  return output;
}

function success(payload = {}) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
  process.exit(0);
}

function readStdinJson() {
  const input = fs.readFileSync(0, "utf8").trim();
  if (!input) return {};
  try {
    return JSON.parse(input);
  } catch {
    return {};
  }
}

function expandHome(value) {
  return value ? value.replace(/^~/, os.homedir()) : value;
}

function candidatePluginRoots() {
  const envRoot = expandHome(process.env.CLAUDE_MEM_CODEX_PLUGIN_ROOT || "");
  const roots = [];
  if (envRoot) roots.push(envRoot);
  roots.push(
    "/Users/antonsahovskii/.codex/plugins/cache/claude-mem-local/claude-mem",
    "/Users/antonsahovskii/.claude/plugins/cache/thedotmack/claude-mem",
    "/Users/antonsahovskii/.claude/plugins/marketplaces/thedotmack/plugin",
  );
  return roots;
}

function normalizePluginRoot(root) {
  if (!root || !fs.existsSync(root)) return null;
  if (fs.existsSync(path.join(root, "scripts", "worker-service.cjs"))) return root;
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(root, entry.name))
      .filter((dir) => fs.existsSync(path.join(dir, "scripts", "worker-service.cjs")))
      .sort((left, right) => right.localeCompare(left, undefined, { numeric: true }));
  } catch {
    entries = [];
  }
  return entries[0] || null;
}

function findPluginRoot() {
  for (const root of candidatePluginRoots()) {
    const normalized = normalizePluginRoot(root);
    if (
      normalized &&
      fs.existsSync(path.join(normalized, "scripts", "bun-runner.js")) &&
      fs.existsSync(path.join(normalized, "scripts", "worker-service.cjs"))
    ) {
      return normalized;
    }
  }
  return null;
}

function truncateString(value, maxChars) {
  if (value.length <= maxChars) return value;
  const headChars = Math.max(1, Math.floor(maxChars * 0.55));
  const tailChars = Math.max(1, Math.floor(maxChars * 0.35));
  const marker = `\n[claude-mem-codex-truncated original_chars=${value.length} kept_chars=${headChars + tailChars}]\n`;
  return `${value.slice(0, headChars)}${marker}${value.slice(-tailChars)}`;
}

function sanitize(value, maxChars, depth = 0) {
  if (typeof value === "string") return truncateString(value, maxChars);
  if (value === null || typeof value !== "object") return value;
  if (depth > 5) return "[claude-mem-codex-depth-truncated]";
  if (Array.isArray(value)) {
    const items = value.slice(0, 25).map((item) => sanitize(item, maxChars, depth + 1));
    if (value.length > items.length) items.push(`[claude-mem-codex-array-truncated original_items=${value.length}]`);
    return items;
  }
  const out = {};
  const entries = Object.entries(value).slice(0, 80);
  for (const [key, item] of entries) out[key] = sanitize(item, maxChars, depth + 1);
  if (Object.keys(value).length > entries.length) out.__claude_mem_codex_object_truncated = Object.keys(value).length;
  return out;
}

function addSummaryContract(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return input;
  const maxChars = Number.parseInt(process.env.CLAUDE_MEM_CODEX_SUMMARY_LAST_MESSAGE_CHARS || "", 10)
    || DEFAULT_SUMMARY_LAST_MESSAGE_CHARS;
  for (const field of SUMMARY_STRING_FIELDS) {
    if (typeof input[field] === "string") input[field] = truncateString(input[field], maxChars);
  }
  input.claude_mem_summary_contract = SUMMARY_CONTRACT;
  return input;
}

function allowedObservationTool(raw) {
  const configured = (process.env.CLAUDE_MEM_CODEX_OBSERVE_TOOLS || "")
    .split(",")
    .map((tool) => tool.trim())
    .filter(Boolean);
  const allowed = configured.length > 0 ? new Set(configured) : DEFAULT_ALLOWED_OBSERVATION_TOOLS;
  return allowed.has(raw.tool_name);
}

function bashCommand(raw) {
  const input = raw.tool_input;
  if (!input || typeof input !== "object" || Array.isArray(input)) return "";
  const command = input.command;
  return typeof command === "string" ? command : "";
}

function isLowSignalBash(raw) {
  if (raw.tool_name !== "Bash") return false;
  const command = bashCommand(raw).trim();
  if (!command) return true;
  if (HIGH_SIGNAL_BASH_PATTERNS.some((pattern) => pattern.test(command))) return false;
  return LOW_SIGNAL_BASH_PATTERNS.some((pattern) => pattern.test(command));
}

function stateDir() {
  return process.env.CLAUDE_MEM_CODEX_STATE_DIR || "/Users/antonsahovskii/.claude-mem/codex-hook-state";
}

function shouldThrottleBash(raw) {
  if (raw.tool_name !== "Bash") return false;
  const intervalMs = Number.parseInt(process.env.CLAUDE_MEM_CODEX_BASH_MIN_INTERVAL_MS || "", 10) || DEFAULT_BASH_MIN_INTERVAL_MS;
  if (intervalMs <= 0) return false;
  const sessionId = typeof raw.session_id === "string" ? raw.session_id : "unknown";
  const cwd = typeof raw.cwd === "string" ? raw.cwd : process.cwd();
  const project = path.basename(cwd) || "unknown";
  const dir = stateDir();
  fs.mkdirSync(dir, { recursive: true });
  const safe = `${project}-${sessionId}`.replace(/[^a-zA-Z0-9_.-]/g, "_");
  const file = path.join(dir, `${safe}.json`);
  const now = Date.now();
  let previous = 0;
  try {
    previous = JSON.parse(fs.readFileSync(file, "utf8")).lastObservedAt || 0;
  } catch {
    previous = 0;
  }
  if (now - previous < intervalMs) return true;
  fs.writeFileSync(file, JSON.stringify({ lastObservedAt: now }) + "\n");
  return false;
}

function buildInput(action) {
  const raw = readStdinJson();
  if (action === "observation" && !allowedObservationTool(raw)) {
    return null;
  }
  if (action === "observation" && isLowSignalBash(raw)) {
    return null;
  }
  if (action === "observation" && shouldThrottleBash(raw)) {
    return null;
  }
  const maxChars = action === "summarize"
    ? (Number.parseInt(process.env.CLAUDE_MEM_CODEX_SUMMARY_MAX_STRING_CHARS || "", 10) || DEFAULT_SUMMARY_MAX_STRING_CHARS)
    : (Number.parseInt(process.env.CLAUDE_MEM_CODEX_MAX_STRING_CHARS || "", 10) || DEFAULT_MAX_STRING_CHARS);
  const sanitized = sanitize(raw, maxChars);
  if (ACTION_TO_EVENT[action] && !sanitized.hook_event_name) {
    sanitized.hook_event_name = ACTION_TO_EVENT[action];
  }
  if (action === "summarize") addSummaryContract(sanitized);
  return sanitized;
}

function runPlugin(action, input) {
  const pluginRoot = findPluginRoot();
  if (!pluginRoot) success();

  const args = action === "start"
    ? [path.join(pluginRoot, "scripts", "bun-runner.js"), path.join(pluginRoot, "scripts", "worker-service.cjs"), "start"]
    : [
        path.join(pluginRoot, "scripts", "bun-runner.js"),
        path.join(pluginRoot, "scripts", "worker-service.cjs"),
        "hook",
        "codex",
        action,
      ];

  const result = spawnSync(process.execPath, args, {
    input: action === "start" ? undefined : JSON.stringify(input),
    encoding: "utf8",
    env: { ...process.env, CLAUDE_MEM_CODEX_HOOK: "1" },
    timeout: Number.parseInt(process.env.CLAUDE_MEM_CODEX_HOOK_TIMEOUT_MS || "", 10) || DEFAULT_CHILD_TIMEOUT_MS,
  });

  if (result.status === 0 && result.stdout.trim()) {
    try {
      const parsed = JSON.parse(result.stdout.trim());
      process.stdout.write(`${JSON.stringify(sanitizeCodexOutput(parsed))}\n`);
    } catch {
      process.stdout.write("{}\n");
    }
    process.exit(0);
  }
  success();
}

function main() {
  const action = process.argv[2];
  if (!action || (action !== "start" && !ACTION_TO_EVENT[action])) {
    throw new Error("Usage: claude-mem-codex-hook.js start|context|session-init|observation|summarize");
  }
  if (action === "start") {
    runPlugin(action, {});
    return;
  }
  const input = buildInput(action);
  if (!input) success();
  runPlugin(action, input);
}

try {
  main();
} catch {
  success();
}
