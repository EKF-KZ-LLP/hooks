const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/patch-claude-mem-worker-repair.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-worker-repair-"));
const cacheDir = path.join(tmp, "bundle-cache");
fs.mkdirSync(cacheDir, { recursive: true });
const patched = path.join(cacheDir, "claude-mem-worker-service-13.2.0.repair.cjs");
const root = path.join(tmp, "claude-mem", "13.2.0");
const scripts = path.join(root, "scripts");
fs.mkdirSync(scripts, { recursive: true });

fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ version: "13.2.0" }));
fs.writeFileSync(path.join(scripts, "worker-service.cjs"), "console.log('old');\n");
fs.writeFileSync(
  patched,
  "console.log('invalid_xml_after_retry'); console.log('Starting invalid XML repair retry'); console.log('claude-mem-invalid-xml-truncated');\n",
);

const run = () => execFileSync(process.execPath, [SCRIPT, "--cache-dir", cacheDir, "--root", root, "--no-build"], { encoding: "utf8" });

const first = run();
assert.match(first, /PATCHED/);
assert.match(fs.readFileSync(path.join(scripts, "worker-service.cjs"), "utf8"), /invalid_xml_after_retry/);

const second = run();
assert.match(second, /OK/);

const wrongRoot = path.join(tmp, "claude-mem", "13.1.0");
fs.mkdirSync(path.join(wrongRoot, "scripts"), { recursive: true });
fs.writeFileSync(path.join(wrongRoot, "package.json"), JSON.stringify({ version: "13.1.0" }));
fs.writeFileSync(path.join(wrongRoot, "scripts", "worker-service.cjs"), "console.log('old');\n");
fs.writeFileSync(
  path.join(cacheDir, "claude-mem-worker-service-13.1.0.repair.cjs"),
  "console.log('invalid_xml_after_retry'); console.log('Starting invalid XML repair retry'); console.log('claude-mem-invalid-xml-truncated'); console.log('future-version');\n",
);

const future = execFileSync(process.execPath, [SCRIPT, "--cache-dir", cacheDir, "--root", wrongRoot, "--no-build"], { encoding: "utf8" });
assert.match(future, /PATCHED/);
assert.match(fs.readFileSync(path.join(wrongRoot, "scripts", "worker-service.cjs"), "utf8"), /future-version/);

const missingRoot = path.join(tmp, "claude-mem", "13.0.0");
fs.mkdirSync(path.join(missingRoot, "scripts"), { recursive: true });
fs.writeFileSync(path.join(missingRoot, "package.json"), JSON.stringify({ version: "13.0.0" }));
fs.writeFileSync(path.join(missingRoot, "scripts", "worker-service.cjs"), "console.log('old');\n");
const missing = execFileSync(process.execPath, [SCRIPT, "--cache-dir", cacheDir, "--root", missingRoot, "--no-build"], { encoding: "utf8" });
assert.match(missing, /SKIP missing_bundle version=13.0.0/);

console.log("patch-claude-mem-worker-repair.test.js passed");
