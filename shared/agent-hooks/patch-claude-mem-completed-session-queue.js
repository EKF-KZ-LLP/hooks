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
const MARKER = "SKIP_CLOSED_SESSION";
const ANCHOR = "enqueue(e,r,n){let i=Date.now(),o=this.db.prepare(`";
const OLD_REPLACEMENT = `enqueue(e,r,n){let t=this.db.prepare("SELECT status FROM sdk_sessions WHERE id = ?").get(e);if(t&&(t.status==="completed"||t.status==="failed"))return _.info("QUEUE",\`SKIP_CLOSED_SESSION | sessionDbId=\${e} | status=\${t.status} | type=\${n.type}\`,{sessionId:e}),0;let i=Date.now(),o=this.db.prepare(\``;
const REPLACEMENT = `enqueue(e,r,n){let t=this.db.prepare("SELECT status, memory_session_id FROM sdk_sessions WHERE id = ?").get(e);if(t&&t.status==="failed")return _.info("QUEUE",\`SKIP_CLOSED_SESSION | sessionDbId=\${e} | status=\${t.status} | type=\${n.type}\`,{sessionId:e}),0;if(t&&t.status==="completed"){if(n.type!=="summarize")return _.info("QUEUE",\`SKIP_CLOSED_SESSION | sessionDbId=\${e} | status=\${t.status} | type=\${n.type}\`,{sessionId:e}),0;let a=t.memory_session_id?this.db.prepare("SELECT 1 FROM session_summaries WHERE memory_session_id = ? LIMIT 1").get(t.memory_session_id):null;if(a)return _.info("QUEUE",\`SKIP_CLOSED_SESSION_SUMMARY_EXISTS | sessionDbId=\${e} | status=\${t.status} | type=\${n.type}\`,{sessionId:e}),0}let i=Date.now(),o=this.db.prepare(\``;

function parseArgs(argv) {
  const roots = [];
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--root") {
      roots.push(argv[++index]);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
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
  if (text.includes("SKIP_CLOSED_SESSION_SUMMARY_EXISTS")) return { status: "present", worker };
  if (text.includes(OLD_REPLACEMENT)) {
    fs.writeFileSync(worker, text.replace(OLD_REPLACEMENT, REPLACEMENT));
    return { status: "patched", worker };
  }
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
  console.log(`completed_session_queue_patch patched=${patched} present=${present} missing=${missing} errors=${errors}`);
  if (errors > 0) process.exit(1);
}

main();
