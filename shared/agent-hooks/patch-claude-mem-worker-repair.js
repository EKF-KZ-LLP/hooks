#!/usr/bin/env node
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const DEFAULT_CACHE_DIR = "/Users/antonsahovskii/.local/share/agent-hooks";
const DEFAULT_SOURCE_DIR = "/Users/antonsahovskii/.local/share/agent-hooks/claude-mem-source-cache";
const DEFAULT_PROFILE_ROOTS = [
  "/Users/antonsahovskii/.claude/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.claude-personal/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.claude-work/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.claude-ekfgroup/plugins/cache/thedotmack/claude-mem",
  "/Users/antonsahovskii/.codex/plugins/cache/claude-mem-local/claude-mem",
];
const REQUIRED_MARKERS = [
  "invalid_xml_after_retry",
  "Starting invalid XML repair retry",
  "claude-mem-invalid-xml-truncated",
];

function parseArgs(argv) {
  const args = {
    bundle: null,
    cacheDir: DEFAULT_CACHE_DIR,
    sourceDir: DEFAULT_SOURCE_DIR,
    roots: [],
    build: true,
  };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--bundle") {
      args.bundle = argv[++index];
    } else if (arg === "--cache-dir") {
      args.cacheDir = argv[++index];
    } else if (arg === "--source-dir") {
      args.sourceDir = argv[++index];
    } else if (arg === "--root") {
      args.roots.push(argv[++index]);
    } else if (arg === "--no-build") {
      args.build = false;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (args.roots.length === 0) args.roots = discoverDefaultRoots();
  return args;
}

function expandHome(value) {
  return value.replace(/^~/, os.homedir());
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
      if (fs.existsSync(path.join(root, "package.json")) && fs.existsSync(path.join(root, "scripts", "worker-service.cjs"))) {
        roots.push(root);
      }
    }
  }
  return roots.sort();
}

function readPackageVersion(root) {
  const packagePath = path.join(root, "package.json");
  if (!fs.existsSync(packagePath)) return null;
  try {
    const version = JSON.parse(fs.readFileSync(packagePath, "utf8")).version;
    return typeof version === "string" && version ? version : null;
  } catch {
    return null;
  }
}

function bundlePathForVersion(cacheDir, version) {
  return path.join(cacheDir, `claude-mem-worker-service-${version}.repair.cjs`);
}

function assertBundle(bundle) {
  if (!fs.existsSync(bundle)) {
    throw new Error(`Missing patched bundle: ${bundle}`);
  }
  const text = fs.readFileSync(bundle, "utf8");
  for (const marker of REQUIRED_MARKERS) {
    if (!text.includes(marker)) {
      throw new Error(`Patched bundle missing marker: ${marker}`);
    }
  }
}

function run(cmd, args, options = {}) {
  execFileSync(cmd, args, { stdio: "inherit", ...options });
}

function ensureSourceCheckout(version, sourceDir) {
  fs.mkdirSync(sourceDir, { recursive: true });
  const checkout = path.join(sourceDir, version);
  if (fs.existsSync(path.join(checkout, "package.json"))) return checkout;
  const tmp = `${checkout}.tmp-${Date.now()}`;
  run("git", ["clone", "--depth", "1", "--branch", `v${version}`, "https://github.com/thedotmack/claude-mem.git", tmp]);
  fs.renameSync(tmp, checkout);
  return checkout;
}

function replaceOnce(text, before, after, label) {
  if (text.includes(after)) return text;
  if (!text.includes(before)) throw new Error(`Source patch anchor not found: ${label}`);
  return text.replace(before, after);
}

function patchResponseProcessor(sourceRoot) {
  const file = path.join(sourceRoot, "src/services/worker/agents/ResponseProcessor.ts");
  let text = fs.readFileSync(file, "utf8");
  text = replaceOnce(
    text,
    "import { broadcastObservation, broadcastSummary } from './ObservationBroadcaster.js';\n\nexport async function processAgentResponse(",
    "import { broadcastObservation, broadcastSummary } from './ObservationBroadcaster.js';\n\nexport type InvalidXmlRepairCallback = () => Promise<string | null | undefined>;\n\nexport async function processAgentResponse(",
    "response processor repair type",
  );
  text = replaceOnce(
    text,
    "  agentName: string,\n  projectRoot?: string,\n  modelId?: string\n): Promise<void> {",
    "  agentName: string,\n  projectRoot?: string,\n  modelId?: string,\n  repairInvalidXmlResponse?: InvalidXmlRepairCallback\n): Promise<void> {",
    "response processor function signature",
  );
  text = replaceOnce(
    text,
    "  const parsed = parseAgentXml(text, session.contentSessionId);\n\n  if (!parsed.valid) {",
    `  let parsed = parseAgentXml(text, session.contentSessionId);

  if (!parsed.valid) {
    if (repairInvalidXmlResponse) {
      logger.warn('PARSER', \`\${agentName} returned non-XML/empty response — requesting one repair retry\`, {
        sessionId: session.sessionDbId,
      });

      const repairedText = await repairInvalidXmlResponse();
      if (repairedText) {
        session.conversationHistory.push({ role: 'assistant', content: repairedText });
        const repaired = parseAgentXml(repairedText, session.contentSessionId);
        if (repaired.valid) {
          logger.info('PARSER', \`\${agentName} repair retry produced valid XML\`, {
            sessionId: session.sessionDbId,
          });
          parsed = repaired;
        }
      }
    }

    if (parsed.valid) {
      // Continue into normal storage path below.
    } else {
      const marker = repairInvalidXmlResponse ? 'invalid_xml_after_retry' : 'ignoring queued batch';
      logger.warn('PARSER', \`\${agentName} returned non-XML/empty response — \${marker}\`, {
        sessionId: session.sessionDbId,
      });
      // Plain-text skip responses are intentionally ignored. Re-queueing them
      // creates an observer loop where the same low-signal batch is retried
      // until the restart guard fires or the provider quota is exhausted.
      await sessionManager.confirmClaimedMessages(session.sessionDbId);
      session.earliestPendingTimestamp = null;
      return;
    }
  }

  if (!parsed.valid) {`,
    "response processor invalid XML branch",
  );
  fs.writeFileSync(file, text);
}

function patchClaudeProvider(sourceRoot) {
  const file = path.join(sourceRoot, "src/services/worker/ClaudeProvider.ts");
  let text = fs.readFileSync(file, "utf8");
  text = replaceOnce(
    text,
    "export function __resetEffortHintLatchForTesting(): void {\n  effortHintLogged = false;\n}\n\n/**",
    `export function __resetEffortHintLatchForTesting(): void {
  effortHintLogged = false;
}

export function buildInvalidXmlRepairPrompt(originalText: string): string {
  const maxChars = 12000;
  const source = typeof originalText === 'string' ? originalText : String(originalText ?? '');
  const clipped = source.length > maxChars
    ? [
        source.slice(0, Math.floor(maxChars / 2)),
        \`\\n[claude-mem-invalid-xml-truncated original_chars=\${source.length} kept_chars=\${maxChars}]\\n\`,
        source.slice(-Math.ceil(maxChars / 2)),
      ].join('')
    : source;

  return [
    'You are repairing a Claude-Mem observer response that failed XML parsing.',
    'Output only valid XML. No prose, no markdown fences, no explanation.',
    '',
    'Allowed outputs:',
    '- One or more <observation> blocks with child fields: <type>, <title>, <subtitle>, <narrative>, <facts><fact>...</fact></facts>, <concepts><concept>...</concept></concepts>, <files_read><file>...</file></files_read>, <files_modified><file>...</file></files_modified>.',
    '- One <summary> block with child fields: <request>, <investigated>, <learned>, <completed>, <next_steps>, <notes>.',
    '- <skip_summary reason="invalid_xml_repair_no_memory" /> if the original response contains no durable memory worth storing.',
    '',
    'Preserve only facts that are present in the original response. Do not invent details.',
    '',
    '<original_invalid_response>',
    clipped,
    '</original_invalid_response>',
  ].join('\\n');
}

/**`,
    "provider repair prompt function",
  );
  text = replaceOnce(
    text,
    "            'SDK',\n            cwdTracker.lastCwd,\n            modelId\n          );",
    `            'SDK',
            cwdTracker.lastCwd,
            modelId,
            () => this.repairInvalidXmlResponse({
              originalText: textContent,
              session,
              modelId,
              claudePath,
              isolatedEnv,
              disallowedTools,
              cwdTracker,
            })
          );`,
    "provider repair callback argument",
  );
  text = replaceOnce(
    text,
    "  private async *createMessageGenerator(\n    session: ActiveSession,",
    `  private async repairInvalidXmlResponse(args: {
    originalText: string;
    session: ActiveSession;
    modelId: string;
    claudePath: string;
    isolatedEnv: NodeJS.ProcessEnv;
    disallowedTools: string[];
    cwdTracker: { lastCwd: string | undefined };
  }): Promise<string | null> {
    const { originalText, session, modelId, claudePath, isolatedEnv, disallowedTools } = args;
    const prompt = buildInvalidXmlRepairPrompt(originalText);

    logger.warn('SDK', 'Starting invalid XML repair retry', {
      sessionDbId: session.sessionDbId,
      memorySessionId: session.memorySessionId ?? undefined,
      modelId,
    });

    const repairResult = query({
      prompt,
      options: {
        model: modelId,
        cwd: OBSERVER_SESSIONS_DIR,
        ...(session.memorySessionId ? { resume: session.memorySessionId } : {}),
        disallowedTools,
        abortController: session.abortController,
        pathToClaudeCodeExecutable: claudePath,
        spawnClaudeCodeProcess: createSdkSpawnFactory(session.sessionDbId),
        env: isolatedEnv,
        mcpServers: {},
        settingSources: [],
        strictMcpConfig: true,
      }
    });

    let repairedText = '';
    for await (const message of repairResult) {
      if (message.session_id && message.session_id !== session.memorySessionId) {
        session.memorySessionId = message.session_id;
        this.dbManager.getSessionStore().ensureMemorySessionIdRegistered(
          session.sessionDbId,
          message.session_id
        );
      }

      if (message.type === 'assistant') {
        const content = message.message.content;
        repairedText = Array.isArray(content)
          ? content.filter((c: any) => c.type === 'text').map((c: any) => c.text).join('\\n')
          : typeof content === 'string' ? content : '';
      }
    }

    if (repairedText) {
      const truncated = repairedText.length > 100
        ? repairedText.substring(0, 100) + '...'
        : repairedText;
      logger.dataOut('SDK', \`Invalid XML repair retry response received (\${repairedText.length} chars)\`, {
        sessionId: session.sessionDbId,
        promptNumber: session.lastPromptNumber
      }, truncated);
      return repairedText;
    }

    logger.warn('SDK', 'Invalid XML repair retry returned empty response', {
      sessionDbId: session.sessionDbId,
    });
    return null;
  }

  private async *createMessageGenerator(
    session: ActiveSession,`,
    "provider repair method",
  );
  fs.writeFileSync(file, text);
}

function buildBundle(version, args) {
  const bundle = bundlePathForVersion(args.cacheDir, version);
  if (fs.existsSync(bundle)) {
    assertBundle(bundle);
    return bundle;
  }
  if (!args.build) return null;

  const sourceRoot = ensureSourceCheckout(version, args.sourceDir);
  patchResponseProcessor(sourceRoot);
  patchClaudeProvider(sourceRoot);
  run("bun", ["install"], { cwd: sourceRoot });
  run(process.execPath, ["scripts/build-hooks.js"], { cwd: sourceRoot });

  const built = path.join(sourceRoot, "plugin/scripts/worker-service.cjs");
  assertBundle(built);
  fs.mkdirSync(args.cacheDir, { recursive: true });
  fs.copyFileSync(built, bundle);
  assertBundle(bundle);
  return bundle;
}

function backupTarget(target) {
  if (!fs.existsSync(target)) return;
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "");
  const backup = `${target}.bak-worker-repair-${stamp}`;
  fs.copyFileSync(target, backup);
}

function patchRoot(root, args) {
  if (!root || !fs.existsSync(root)) {
    console.log(`SKIP missing_root=${root}`);
    return;
  }

  const version = readPackageVersion(root);
  if (!version) {
    console.log(`SKIP version=unknown root=${root}`);
    return;
  }

  const target = path.join(root, "scripts", "worker-service.cjs");
  if (!fs.existsSync(target)) {
    console.log(`SKIP missing_worker=${target}`);
    return;
  }

  const currentText = fs.readFileSync(target, "utf8");
  if (REQUIRED_MARKERS.every((marker) => currentText.includes(marker))) {
    console.log(`OK ${target}`);
    return;
  }

  const bundle = args.bundle ? args.bundle : buildBundle(version, args);
  if (!bundle) {
    console.log(`SKIP missing_bundle version=${version} root=${root}`);
    return;
  }
  assertBundle(bundle);
  const patchedText = fs.readFileSync(bundle, "utf8");
  if (currentText === patchedText) {
    console.log(`OK ${target}`);
    return;
  }

  backupTarget(target);
  fs.copyFileSync(bundle, target);
  console.log(`PATCHED ${target}`);
}

function main() {
  const args = parseArgs(process.argv);
  args.cacheDir = expandHome(args.cacheDir);
  args.sourceDir = expandHome(args.sourceDir);
  if (args.bundle) {
    args.bundle = expandHome(args.bundle);
    assertBundle(args.bundle);
  }
  for (const root of args.roots) {
    patchRoot(expandHome(root), args);
  }
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
