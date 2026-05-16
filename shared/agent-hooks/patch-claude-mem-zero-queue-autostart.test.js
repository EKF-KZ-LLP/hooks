const assert = require("node:assert/strict");
const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/patch-claude-mem-zero-queue-autostart.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-zero-queue-autostart-"));
const root = path.join(tmp, "claude-mem", "13.2.0");
const scripts = path.join(root, "scripts");
fs.mkdirSync(scripts, { recursive: true });
const worker = path.join(scripts, "worker-service.cjs");
fs.writeFileSync(
  worker,
  'async startGeneratorWithProvider(r,n,i){let s,o,c;c=await this.sessionManager.getPendingMessageStore().getPendingCount(r.sessionDbId);_.info("SESSION",`Generator auto-starting (${i}) using ${o}`,{sessionId:r.sessionDbId,queueDepth:c,historyLength:r.conversationHistory.length}),r.currentProvider=n,r.lastGeneratorActivity=Date.now();r.generatorPromise=s.startSession(r,this.workerService)}\n',
);

const run = () => execFileSync(process.execPath, [SCRIPT, "--root", root], { encoding: "utf8" });

const first = run();
assert.match(first, /PATCHED/);
let text = fs.readFileSync(worker, "utf8");
assert.match(text, /ZERO_QUEUE_AUTOSTART_SKIP/);
assert.match(text, /c===0&&i!=="init"/);
assert.match(text, /Generator auto-starting/);

const second = run();
assert.match(second, /OK/);
assert.match(second, /present=1/);

const badRoot = path.join(tmp, "bad", "13.2.0");
fs.mkdirSync(path.join(badRoot, "scripts"), { recursive: true });
fs.writeFileSync(path.join(badRoot, "scripts", "worker-service.cjs"), "console.log('no anchor');\n");
const bad = spawnSync(process.execPath, [SCRIPT, "--root", badRoot], { encoding: "utf8" });
assert.equal(bad.status, 1);
assert.match(bad.stderr, /missing_anchor/);

execFileSync(process.execPath, ["--check", SCRIPT]);
console.log("patch-claude-mem-zero-queue-autostart.test.js passed");
