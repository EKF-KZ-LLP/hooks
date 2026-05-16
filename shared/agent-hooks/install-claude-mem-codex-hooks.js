#!/usr/bin/env node
const fs = require("node:fs");

const DEFAULT_HOOKS = "/Users/antonsahovskii/.codex/hooks.json";
const NODE_BIN = "/opt/homebrew/bin/node";
const WRAPPER = "/Users/antonsahovskii/.local/share/agent-hooks/claude-mem-codex-hook.js";

function parseArgs(argv) {
  const args = { hooks: DEFAULT_HOOKS };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--hooks") {
      args.hooks = argv[++index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function loadHooks(file) {
  if (!fs.existsSync(file)) return { hooks: {} };
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!parsed.hooks || typeof parsed.hooks !== "object") parsed.hooks = {};
  return parsed;
}

function command(action) {
  return `${NODE_BIN} ${WRAPPER} ${action}`;
}

function ensureEvent(config, event) {
  if (!Array.isArray(config.hooks[event])) config.hooks[event] = [];
  return config.hooks[event];
}

function hasCommand(config, action) {
  return JSON.stringify(config).includes(`${WRAPPER} ${action}`);
}

function hook(action, timeout, extra = {}) {
  return {
    type: "command",
    command: command(action),
    timeout,
    ...extra,
  };
}

function addSessionStart(config) {
  const event = ensureEvent(config, "SessionStart");
  let changed = false;
  let entry = event.find((item) => item.matcher === "startup|resume");
  if (!entry) {
    entry = { matcher: "startup|resume", hooks: [] };
    event.push(entry);
    changed = true;
  }
  if (!Array.isArray(entry.hooks)) entry.hooks = [];
  if (!hasCommand(config, "start")) {
    entry.hooks.push(hook("start", 20));
    changed = true;
  }
  if (!hasCommand(config, "context")) {
    entry.hooks.push(hook("context", 30, { statusMessage: "Loading claude-mem context" }));
    changed = true;
  }
  return changed;
}

function addSingleHook(config, eventName, action, timeout, matcher) {
  const event = ensureEvent(config, eventName);
  if (hasCommand(config, action)) return false;
  const entry = matcher ? { matcher, hooks: [hook(action, timeout)] } : { hooks: [hook(action, timeout)] };
  event.push(entry);
  return true;
}

function install(config) {
  let changed = false;
  changed = addSessionStart(config) || changed;
  changed = addSingleHook(config, "UserPromptSubmit", "session-init", 30) || changed;
  changed = addSingleHook(config, "PostToolUse", "observation", 45, "Bash|Edit|Write|MultiEdit") || changed;
  changed = addSingleHook(config, "Stop", "summarize", 45) || changed;
  return changed;
}

function main() {
  const args = parseArgs(process.argv);
  const config = loadHooks(args.hooks);
  const changed = install(config);
  if (changed) fs.writeFileSync(args.hooks, `${JSON.stringify(config, null, 2)}\n`);
  console.log(`installed=${changed}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
