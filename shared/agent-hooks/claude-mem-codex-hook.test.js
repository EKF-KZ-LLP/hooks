const assert = require("node:assert/strict");
const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/claude-mem-codex-hook.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-codex-hook-"));
const plugin = path.join(tmp, "plugin");
fs.mkdirSync(path.join(plugin, "scripts"), { recursive: true });
fs.writeFileSync(
  path.join(plugin, "scripts", "bun-runner.js"),
  "let data=''; process.stdin.on('data', c => data += c); process.stdin.on('end', () => { const parsed = JSON.parse(data || '{}'); parsed.suppressOutput = true; process.stdout.write(JSON.stringify(parsed)); });\n",
);
fs.writeFileSync(path.join(plugin, "scripts", "worker-service.cjs"), "");
const stateDir = path.join(tmp, "state");

function run(action, input, extraEnv = {}) {
  return spawnSync(process.execPath, [SCRIPT, action], {
    input: JSON.stringify(input),
    encoding: "utf8",
    env: {
      ...process.env,
      CLAUDE_MEM_CODEX_PLUGIN_ROOT: plugin,
      CLAUDE_MEM_CODEX_MAX_STRING_CHARS: "80",
      CLAUDE_MEM_CODEX_STATE_DIR: stateDir,
      CLAUDE_MEM_CODEX_BASH_MIN_INTERVAL_MS: "60000",
      ...extraEnv,
    },
  });
}

let skipped = run("observation", {
  session_id: "s1",
  cwd: tmp,
  hook_event_name: "PostToolUse",
  tool_name: "Read",
  tool_response: "large",
});
assert.equal(skipped.status, 0);
assert.deepEqual(JSON.parse(skipped.stdout), {});

let observed = run("observation", {
  session_id: "s1",
  cwd: tmp,
  tool_name: "Bash",
  tool_input: { command: "echo first" },
  tool_response: "a".repeat(200),
});
assert.equal(observed.status, 0);
const forwarded = JSON.parse(observed.stdout);
assert.equal(forwarded.hook_event_name, "PostToolUse");
assert.equal(forwarded.tool_name, "Bash");
assert.equal(forwarded.suppressOutput, undefined);
assert.ok(forwarded.tool_response.includes("[claude-mem-codex-truncated"));
assert.ok(forwarded.tool_response.length < 180);

let init = run("session-init", {
  session_id: "s2",
  cwd: tmp,
  prompt: "remember this",
});
assert.equal(init.status, 0);
assert.equal(JSON.parse(init.stdout).hook_event_name, "UserPromptSubmit");

let throttled = run("observation", {
  session_id: "s1",
  cwd: tmp,
  tool_name: "Bash",
  tool_input: { command: "echo second" },
  tool_response: "second",
});
assert.equal(throttled.status, 0);
assert.deepEqual(JSON.parse(throttled.stdout), {});

let lowSignal = run("observation", {
  session_id: "other-session",
  cwd: tmp,
  tool_name: "Bash",
  tool_input: { command: "sqlite3 /Users/antonsahovskii/.claude-mem/claude-mem.db 'select count(*) from pending_messages;'" },
  tool_response: "0",
});
assert.equal(lowSignal.status, 0);
assert.deepEqual(JSON.parse(lowSignal.stdout), {});

const readOnlyCommands = [
  "rg -n \"policy\" /Users/antonsahovskii/.local/share/agent-hooks",
  "git status --short",
  "ls -la /Users/antonsahovskii/.claude",
  "jq '.hooks' /Users/antonsahovskii/.codex/hooks.json",
  "ps -axo pid,ppid,command",
  "sed -n '1,120p' /Users/antonsahovskii/.claude/settings.json",
];
for (const [index, command] of readOnlyCommands.entries()) {
  const result = run("observation", {
    session_id: `read-only-${index}`,
    cwd: tmp,
    tool_name: "Bash",
    tool_input: { command },
    tool_response: "scan output",
  });
  assert.equal(result.status, 0, command);
  assert.deepEqual(JSON.parse(result.stdout), {}, command);
}

const importantCommands = [
  "go test ./...",
  "pytest -q",
  "npm run build",
  "git commit -m hook-fix",
];
for (const [index, command] of importantCommands.entries()) {
  const result = run("observation", {
    session_id: `important-${index}`,
    cwd: tmp,
    tool_name: "Bash",
    tool_input: { command },
    tool_response: "important output",
  });
  assert.equal(result.status, 0, command);
  const payload = JSON.parse(result.stdout);
  assert.equal(payload.tool_name, "Bash", command);
  assert.equal(payload.tool_input.command, command);
}

let summary = run(
  "summarize",
  {
    session_id: "codex-summary",
    cwd: tmp,
    last_user_message: "u".repeat(400),
    last_assistant_message: "a".repeat(400),
    tool_response: "r".repeat(400),
  },
  {
    CLAUDE_MEM_CODEX_SUMMARY_MAX_STRING_CHARS: "140",
    CLAUDE_MEM_CODEX_SUMMARY_LAST_MESSAGE_CHARS: "90",
  },
);
assert.equal(summary.status, 0);
const summaryPayload = JSON.parse(summary.stdout);
assert.equal(summaryPayload.hook_event_name, "Stop");
assert.match(summaryPayload.claude_mem_summary_contract, /<summary>/);
assert.ok(summaryPayload.last_assistant_message.includes("[claude-mem-codex-truncated"));
assert.ok(summaryPayload.last_assistant_message.length < 180);
assert.ok(summaryPayload.tool_response.length < 240);

execFileSync(process.execPath, ["--check", SCRIPT]);
console.log("claude-mem-codex-hook.test.js passed");
