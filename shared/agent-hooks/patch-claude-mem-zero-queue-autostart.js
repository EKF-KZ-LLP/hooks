#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_PROFILE_ROOTS = [
  "/Users/antonsahovskii/.claude/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.claude-personal/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.claude-work/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.claude-ekfgroup/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.codex/plugins/cache/claude-mem-local/claude-mem",
];
const MARKER = "ZERO_QUEUE_AUTOSTART_SKIP";
const ANCHOR = "c=await this.sessionManager.getPendingMessageStore().getPendingCount(r.sessionDbId);_.info(\"SESSION\",`Generator auto-starting (${i}) using ${o}`,{sessionId:r.sessionDbId,queueDepth:c,historyLength:r.conversationHistory.length}),r.currentProvider=n,r.lastGeneratorActivity=Date.now();";
const REPLACEMENT = `c=await this.sessionManager.getPendingMessageStore().getPendingCount(r.sessionDbId);if(c===0&&i!=="init")return _.info("SESSION",\`ZERO_QUEUE_AUTOSTART_SKIP | sessionDbId=\${r.sessionDbId} | reason=\${i}\`,{sessionId:r.sessionDbId,queueDepth:c,historyLength:r.conversationHistory.length});_.info("SESSION",\`Generator auto-starting (\${i}) using \${o}\`,{sessionId:r.sessionDbId,queueDepth:c,historyLength:r.conversationHistory.length}),r.currentProvider=n,r.lastGeneratorActivity=Date.now();`;

function parseArgs(argv) {
  const roots = [];
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--root") roots.push(argv[++index]);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return roots.length > 0 ? roots : discoverDefaultRoots();
}

function discoverDefaultRoots() {
  const roots = [];
  for (const profileRoot of DEFAULT_PROFILE_ROOTS) {
    let entries;
    try {
      entries = fs.readdirSync(profileRoot, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const root = path.join(profileRoot, entry.name);
      if (fs.existsSync(path.join(root, "scripts", "worker-service.cjs"))) roots.push(root);
    }
  }
  return roots.sort();
}

function patchWorker(root) {
  const worker = path.join(root, "scripts", "worker-service.cjs");
  if (!fs.existsSync(worker)) return { status: "missing", worker };
  const text = fs.readFileSync(worker, "utf8");
  if (text.includes(MARKER)) return { status: "present", worker };
  if (!text.includes(ANCHOR)) return { status: "missing_anchor", worker };
  fs.writeFileSync(worker, text.replace(ANCHOR, REPLACEMENT));
  return { status: "patched", worker };
}

function main() {
  const roots = parseArgs(process.argv);
  let patched = 0;
  let present = 0;
  let missing = 0;
  let errors = 0;
  for (const root of roots) {
    const result = patchWorker(root);
    if (result.status === "patched") {
      patched += 1;
      console.log(`PATCHED ${result.worker}`);
    } else if (result.status === "present") {
      present += 1;
      console.log(`OK ${result.worker}`);
    } else if (result.status === "missing") {
      missing += 1;
      console.log(`SKIP missing_worker ${result.worker}`);
    } else {
      errors += 1;
      console.error(`ERROR missing_anchor ${result.worker}`);
    }
  }
  console.log(`zero_queue_autostart_patch patched=${patched} present=${present} missing=${missing} errors=${errors}`);
  if (errors > 0) process.exit(1);
}

main();
