const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/patch-claude-mem-hook-output.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-hook-output-"));
const root = path.join(tmp, ".claude");

function writeManifest(rel) {
  const file = path.join(root, rel, "hooks", "hooks.json");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(
    file,
    JSON.stringify(
      {
        hooks: {
          SessionStart: [
            {
              matcher: "startup|clear|compact",
              hooks: [
                {
                  type: "command",
                  command: "node worker-service.cjs start; echo '{\"continue\":true,\"suppressOutput\":true}'",
                  timeout: 60,
                },
              ],
            },
          ],
          PostToolUse: [
            {
              matcher: "*",
              hooks: [{ type: "command", command: "node worker-service.cjs hook claude-code observation", timeout: 120 }],
            },
          ],
        },
      },
      null,
      2,
    ) + "\n",
  );
  return file;
}

const cacheManifest = writeManifest("plugins/cache/thedotmack/claude-mem/13.2.0");
const marketplaceManifest = writeManifest("plugins/marketplaces/thedotmack/plugin");

function run() {
  return execFileSync(process.execPath, [SCRIPT, "--root", root], { encoding: "utf8" });
}

const first = run();
assert.match(first, /patched=2/);
assert.match(first, /present=0/);

for (const file of [cacheManifest, marketplaceManifest]) {
  const text = fs.readFileSync(file, "utf8");
  assert.doesNotMatch(text, /suppressOutput/);
  const parsed = JSON.parse(text);
  assert.match(parsed.hooks.SessionStart[0].hooks[0].command, /echo '\{"continue":true\}'/);
  assert.match(parsed.hooks.SessionStart[0].hooks[0].command, /worker-service\.cjs start >\/dev\/null 2>&1/);
}

const second = run();
assert.match(second, /patched=0/);
assert.match(second, /present=2/);

console.log("patch-claude-mem-hook-output.test.js passed");
