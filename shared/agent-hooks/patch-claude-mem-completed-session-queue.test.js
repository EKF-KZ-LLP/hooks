const assert = require("node:assert/strict");
const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/patch-claude-mem-completed-session-queue.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-completed-session-queue-"));
const root = path.join(tmp, "claude-mem", "13.2.0");
const scripts = path.join(root, "scripts");
fs.mkdirSync(scripts, { recursive: true });
const worker = path.join(scripts, "worker-service.cjs");
fs.writeFileSync(
  worker,
  "var BP=class{enqueue(e,r,n){let i=Date.now(),o=this.db.prepare(`INSERT OR IGNORE INTO pending_messages`).run(e,r,n.type,i);return o.changes>0?o.lastInsertRowid:0}}\n",
);

const run = () => execFileSync(process.execPath, [SCRIPT, "--root", root], { encoding: "utf8" });

const first = run();
assert.match(first, /PATCHED/);
assert.match(first, /patched=1/);
assert.match(fs.readFileSync(worker, "utf8"), /SKIP_CLOSED_SESSION/);
assert.match(fs.readFileSync(worker, "utf8"), /SELECT status, memory_session_id FROM sdk_sessions WHERE id = \?/);
assert.match(fs.readFileSync(worker, "utf8"), /n\.type!=="summarize"/);
assert.match(fs.readFileSync(worker, "utf8"), /session_summaries/);
assert.match(fs.readFileSync(worker, "utf8"), /SKIP_CLOSED_SESSION_SUMMARY_EXISTS/);

const second = run();
assert.match(second, /OK/);
assert.match(second, /present=1/);

const badRoot = path.join(tmp, "bad", "13.2.0");
fs.mkdirSync(path.join(badRoot, "scripts"), { recursive: true });
fs.writeFileSync(path.join(badRoot, "scripts", "worker-service.cjs"), "console.log('no queue anchor');\n");
const bad = spawnSync(process.execPath, [SCRIPT, "--root", badRoot], { encoding: "utf8" });
assert.equal(bad.status, 1);
assert.match(bad.stderr, /missing_anchor/);

execFileSync(process.execPath, ["--check", SCRIPT]);
console.log("patch-claude-mem-completed-session-queue.test.js passed");
