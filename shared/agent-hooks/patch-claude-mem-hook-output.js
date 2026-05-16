#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_ROOTS = [
  "/Users/antonsahovskii/.claude",
  "/Users/antonsahovskii/.claude-personal",
  "/Users/antonsahovskii/.claude-work",
  "/Users/antonsahovskii/.claude-ekfgroup",
];

function parseArgs(argv) {
  const roots = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--root") {
      const value = argv[++i];
      if (!value) throw new Error("--root requires a value");
      roots.push(value);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return roots.length ? roots : DEFAULT_ROOTS;
}

function candidatesForRoot(root) {
  return [
    path.join(root, "plugins", "cache", "thedotmack", "claude-mem"),
    path.join(root, "plugins", "marketplaces", "thedotmack", "plugin", "hooks", "hooks.json"),
  ];
}

function walkManifests(start, out) {
  let stat;
  try {
    stat = fs.statSync(start);
  } catch {
    return;
  }
  if (stat.isFile()) {
    if (path.basename(start) === "hooks.json") out.add(start);
    return;
  }
  let entries;
  try {
    entries = fs.readdirSync(start, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(start, entry.name);
    if (entry.isDirectory()) walkManifests(full, out);
    else if (entry.isFile() && entry.name === "hooks.json") out.add(full);
  }
}

function patchManifest(file) {
  const before = fs.readFileSync(file, "utf8");
  const parsed = JSON.parse(before);
  let after = before.replaceAll(
    `{\\"continue\\":true,\\"suppressOutput\\":true}`,
    `{\\"continue\\":true}`,
  );
  after = after.replace(/(worker-service\.cjs\\" start)(; echo '\{\\"continue\\":true\}')/g, "$1 >/dev/null 2>&1$2");
  let normalized = JSON.parse(after);
  let changed = after !== before;
  for (const entries of Object.values(normalized.hooks || {})) {
    if (!Array.isArray(entries)) continue;
    for (const entry of entries) {
      for (const hook of entry.hooks || []) {
        if (!hook || typeof hook.command !== "string") continue;
        if (hook.command.includes("worker-service.cjs\" start; echo '{\"continue\":true}'")) {
          hook.command = hook.command.replace(
            "worker-service.cjs\" start; echo '{\"continue\":true}'",
            "worker-service.cjs\" start >/dev/null 2>&1; echo '{\"continue\":true}'",
          );
          changed = true;
        }
        if (hook.command.includes("worker-service.cjs start; echo '{\"continue\":true}'")) {
          hook.command = hook.command.replace(
            "worker-service.cjs start; echo '{\"continue\":true}'",
            "worker-service.cjs start >/dev/null 2>&1; echo '{\"continue\":true}'",
          );
          changed = true;
        }
      }
    }
  }
  if (changed) after = JSON.stringify(normalized, null, 2) + "\n";
  if (after !== before) {
    fs.writeFileSync(file, after);
    return "patched";
  }
  if (before.includes(`{\\"continue\\":true}`) && !before.includes("suppressOutput") && before.includes("start >/dev/null 2>&1")) return "present";
  return "unchanged";
}

function main() {
  const roots = parseArgs(process.argv.slice(2));
  const manifests = new Set();
  for (const root of roots) {
    for (const candidate of candidatesForRoot(root)) walkManifests(candidate, manifests);
  }

  let patched = 0;
  let present = 0;
  let unchanged = 0;
  const errors = [];

  for (const file of [...manifests].sort()) {
    try {
      const result = patchManifest(file);
      if (result === "patched") patched++;
      else if (result === "present") present++;
      else unchanged++;
    } catch (error) {
      errors.push(`${file}: ${error.message}`);
    }
  }

  console.log(`OK claude-mem hook output patch: patched=${patched} present=${present} unchanged=${unchanged} errors=${errors.length}`);
  if (errors.length) {
    for (const error of errors) console.error(error);
    process.exitCode = 1;
  }
}

main();
