const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/install-claude-mem-codex-hooks.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-codex-hooks-"));
const hooksPath = path.join(tmp, "hooks.json");
fs.writeFileSync(hooksPath, JSON.stringify({
  hooks: {
    Stop: [
      {
        hooks: [
          {
            type: "command",
            command: "/Users/antonsahovskii/.local/bin/policy-runner codex Stop",
            timeout: 5,
          },
        ],
      },
    ],
  },
}, null, 2));

function run() {
  return execFileSync(process.execPath, [SCRIPT, "--hooks", hooksPath], { encoding: "utf8" });
}

const first = run();
assert.match(first, /installed=true/);

const parsed = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
const allCommands = JSON.stringify(parsed);
assert.match(allCommands, /claude-mem-codex-hook\.js start/);
assert.match(allCommands, /claude-mem-codex-hook\.js context/);
assert.match(allCommands, /claude-mem-codex-hook\.js session-init/);
assert.match(allCommands, /claude-mem-codex-hook\.js observation/);
assert.match(allCommands, /claude-mem-codex-hook\.js summarize/);
assert.match(allCommands, /policy-runner codex Stop/);

const post = parsed.hooks.PostToolUse;
assert.equal(post.length, 1);
assert.equal(post[0].matcher, "Bash|Edit|Write|MultiEdit");
assert.equal(post[0].hooks[0].timeout, 45);

const second = run();
assert.match(second, /installed=false/);
const once = JSON.stringify(JSON.parse(fs.readFileSync(hooksPath, "utf8"))).match(/claude-mem-codex-hook\.js observation/g) ?? [];
assert.equal(once.length, 1);

console.log("install-claude-mem-codex-hooks.test.js passed");
