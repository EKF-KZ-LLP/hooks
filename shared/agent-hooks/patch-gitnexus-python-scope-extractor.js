#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_ROOT = "/opt/homebrew/lib/node_modules/gitnexus";

const PARSE_WORKER_REL = "dist/core/ingestion/workers/parse-worker.js";
const BRIDGE_REL = "dist/core/ingestion/scope-extractor-bridge.js";
const EXTRACTOR_REL = "dist/core/ingestion/scope-extractor.js";

const PARSE_ANCHOR = `        const parsedFile = extractParsedFile(provider, parseContent, file.path, (message) => {
            if (parentPort)
                parentPort.postMessage({ type: 'warning', message });
            else
                console.warn(message);
        });`;

const PARSE_REPLACEMENT = `        const parsedFile = extractParsedFile(provider, parseContent, file.path, (message) => {
            if (parentPort)
                parentPort.postMessage({ type: 'warning', message });
            else
                console.warn(message);
        }, tree);`;

const BRIDGE_ANCHOR = `        const captures = provider.emitScopeCaptures(sourceText, filePath, cachedTree);
        return extractScope(captures, filePath, provider);`;

const BRIDGE_REPLACEMENT = `        const captures = provider.emitScopeCaptures(sourceText, filePath, cachedTree);
        if (captures.length === 0)
            return undefined;
        return extractScope(captures, filePath, provider);`;

function parseArgs(argv) {
  const roots = [];
  let check = false;
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--root") {
      roots.push(argv[++index]);
    } else if (arg === "--check") {
      check = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return { check, roots: roots.length > 0 ? roots : [DEFAULT_ROOT] };
}

function patchFile(file, anchor, replacement, presentNeedle, options = {}) {
  if (!fs.existsSync(file)) return { status: "missing", file };
  const text = fs.readFileSync(file, "utf8");
  if (text.includes(presentNeedle)) return { status: "present", file };
  if (!text.includes(anchor)) return { status: "missing_anchor", file };
  if (options.check) return { status: "needs_patch", file };
  fs.writeFileSync(file, text.replace(anchor, replacement));
  return { status: "patched", file };
}

function extractorHandlesEmptyCaptures(root) {
  const file = path.join(root, EXTRACTOR_REL);
  if (!fs.existsSync(file)) return false;
  const text = fs.readFileSync(file, "utf8");
  return text.includes("scopeDrafts.length === 0") &&
    text.includes("matchCount === 0") &&
    text.includes("kind: 'Module'");
}

function patchBridge(root, options = {}) {
  const bridge = path.join(root, BRIDGE_REL);
  if (extractorHandlesEmptyCaptures(root)) {
    return { status: "present", file: bridge };
  }
  return patchFile(
    bridge,
    BRIDGE_ANCHOR,
    BRIDGE_REPLACEMENT,
    "captures.length === 0",
    options,
  );
}

function patchRoot(root, options = {}) {
  return [
    patchFile(
      path.join(root, PARSE_WORKER_REL),
      PARSE_ANCHOR,
      PARSE_REPLACEMENT,
      "        }, tree);",
      options,
    ),
    patchBridge(root, options),
  ];
}

function main() {
  let patched = 0;
  let present = 0;
  let needsPatch = 0;
  let missing = 0;
  let errors = 0;
  const options = parseArgs(process.argv);

  for (const root of options.roots) {
    for (const result of patchRoot(root, options)) {
      if (result.status === "patched") {
        patched += 1;
        console.log(`PATCHED ${result.file}`);
      } else if (result.status === "present") {
        present += 1;
        console.log(`OK ${result.file}`);
      } else if (result.status === "needs_patch") {
        needsPatch += 1;
        console.log(`NEEDS_PATCH ${result.file}`);
      } else if (result.status === "missing") {
        missing += 1;
        console.log(`SKIP missing ${result.file}`);
      } else {
        errors += 1;
        console.error(`ERROR missing_anchor ${result.file}`);
      }
    }
  }

  console.log(`gitnexus_python_scope_patch patched=${patched} present=${present} needs_patch=${needsPatch} missing=${missing} errors=${errors}`);
  if (errors > 0 || needsPatch > 0) process.exit(1);
}

main();
