const assert = require("node:assert/strict");
const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/patch-gitnexus-python-scope-extractor.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "gitnexus-python-scope-"));
const root = path.join(tmp, "gitnexus");
const parseWorker = path.join(root, "dist/core/ingestion/workers/parse-worker.js");
const bridge = path.join(root, "dist/core/ingestion/scope-extractor-bridge.js");
const extractor = path.join(root, "dist/core/ingestion/scope-extractor.js");
fs.mkdirSync(path.dirname(parseWorker), { recursive: true });
fs.mkdirSync(path.dirname(bridge), { recursive: true });

fs.writeFileSync(
  parseWorker,
  `const parsedFile = "unrelated";
        const parsedFile = extractParsedFile(provider, parseContent, file.path, (message) => {
            if (parentPort)
                parentPort.postMessage({ type: 'warning', message });
            else
                console.warn(message);
        });
`,
);

fs.writeFileSync(
  bridge,
  `function f() {
        const captures = provider.emitScopeCaptures(sourceText, filePath, cachedTree);
        return extractScope(captures, filePath, provider);
}
`,
);
fs.writeFileSync(extractor, "function extract() {}\n");

const run = () => execFileSync(process.execPath, [SCRIPT, "--root", root], { encoding: "utf8" });

const first = run();
assert.match(first, /PATCHED/);
assert.match(first, /patched=2/);
assert.match(fs.readFileSync(parseWorker, "utf8"), /}, tree\);/);
assert.match(fs.readFileSync(bridge, "utf8"), /captures\.length === 0/);

const cleanCheck = spawnSync(process.execPath, [SCRIPT, "--check", "--root", root], { encoding: "utf8" });
assert.equal(cleanCheck.status, 0, cleanCheck.stderr);
assert.match(cleanCheck.stdout, /present=2/);

const second = run();
assert.match(second, /present=2/);

const badRoot = path.join(tmp, "bad");
const badWorker = path.join(badRoot, "dist/core/ingestion/workers/parse-worker.js");
const badBridge = path.join(badRoot, "dist/core/ingestion/scope-extractor-bridge.js");
fs.mkdirSync(path.dirname(badWorker), { recursive: true });
fs.mkdirSync(path.dirname(badBridge), { recursive: true });
fs.writeFileSync(badWorker, "no anchor\n");
fs.writeFileSync(badBridge, "no anchor\n");
const bad = spawnSync(process.execPath, [SCRIPT, "--root", badRoot], { encoding: "utf8" });
assert.equal(bad.status, 1);
assert.match(bad.stderr, /missing_anchor/);

const needsPatchRoot = path.join(tmp, "needs-patch");
const needsWorker = path.join(needsPatchRoot, "dist/core/ingestion/workers/parse-worker.js");
const needsBridge = path.join(needsPatchRoot, "dist/core/ingestion/scope-extractor-bridge.js");
const needsExtractor = path.join(needsPatchRoot, "dist/core/ingestion/scope-extractor.js");
fs.mkdirSync(path.dirname(needsWorker), { recursive: true });
fs.mkdirSync(path.dirname(needsBridge), { recursive: true });
fs.writeFileSync(needsWorker, fs.readFileSync(parseWorker, "utf8").replace(", tree);", ");"));
fs.writeFileSync(needsBridge, `function f() {
        const captures = provider.emitScopeCaptures(sourceText, filePath, cachedTree);
        return extractScope(captures, filePath, provider);
}
`);
fs.writeFileSync(needsExtractor, "function extract() {}\n");
const needs = spawnSync(process.execPath, [SCRIPT, "--check", "--root", needsPatchRoot], { encoding: "utf8" });
assert.equal(needs.status, 1);
assert.match(needs.stdout + needs.stderr, /needs_patch=2/);

const upstreamSafeRoot = path.join(tmp, "upstream-safe");
const safeWorker = path.join(upstreamSafeRoot, "dist/core/ingestion/workers/parse-worker.js");
const safeBridge = path.join(upstreamSafeRoot, "dist/core/ingestion/scope-extractor-bridge.js");
const safeExtractor = path.join(upstreamSafeRoot, "dist/core/ingestion/scope-extractor.js");
fs.mkdirSync(path.dirname(safeWorker), { recursive: true });
fs.mkdirSync(path.dirname(safeBridge), { recursive: true });
fs.writeFileSync(safeWorker, fs.readFileSync(parseWorker, "utf8"));
fs.writeFileSync(safeBridge, `function f() {
        const captures = provider.emitScopeCaptures(sourceText, filePath, cachedTree);
        return extractScope(captures, filePath, provider);
}
`);
fs.writeFileSync(
  safeExtractor,
  `function ensureModuleScope(scopeDrafts, matchCount, filePath) {
  if (scopeDrafts.length === 0 && matchCount === 0) {
    scopeDrafts.push(makeDraft({ kind: 'Module' }));
  }
}
`,
);
const upstreamSafe = spawnSync(process.execPath, [SCRIPT, "--check", "--root", upstreamSafeRoot], { encoding: "utf8" });
assert.equal(upstreamSafe.status, 0, upstreamSafe.stdout + upstreamSafe.stderr);
assert.match(upstreamSafe.stdout, /present=2/);

execFileSync(process.execPath, ["--check", SCRIPT]);
console.log("patch-gitnexus-python-scope-extractor.test.js passed");
