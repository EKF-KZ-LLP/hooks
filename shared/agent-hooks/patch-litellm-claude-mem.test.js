const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = "/Users/antonsahovskii/.local/share/agent-hooks/patch-litellm-claude-mem.js";

function writeFixture(file, kind) {
  const indent = kind === "chat" ? "        " : "    ";
  const requestAnchor =
    kind === "chat"
      ? `${indent}request_data = {\n${indent}    "model": model,\n${indent}}\n`
      : `${indent}# Build a typed AnthropicMessagesRequest for the adapter\n`;

  fs.writeFileSync(
    file,
    [
      "import os",
      "from typing import Any",
      "",
      "SOME_ADAPTER = object()",
      "",
      "def call_gateway(model, max_tokens, messages, system, tool_choice, tools):",
      `${indent}max_tokens = min(`,
      `${indent}    max_tokens, int(os.getenv("CLAUDE_MEM_GATEWAY_MAX_TOKENS", "384"))`,
      `${indent})`,
      "",
      requestAnchor,
    ].join("\n"),
  );
}

function runPatch(chat, responses) {
  return execFileSync(process.execPath, [SCRIPT, "--chat", chat, "--responses", responses], {
    encoding: "utf8",
  });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-mem-patch-"));
const chat = path.join(tmp, "chat_handler.py");
const responses = path.join(tmp, "responses_handler.py");
writeFixture(chat, "chat");
writeFixture(responses, "responses");

const first = runPatch(chat, responses);
assert.match(first, /PATCHED/);

for (const file of [chat, responses]) {
  const text = fs.readFileSync(file, "utf8");
  assert.match(text, /def _claude_mem_fit_messages/);
  assert.match(text, /def _claude_mem_dynamic_max_tokens/);
  assert.match(text, /CLAUDE_MEM_LOCAL_CONTEXT_LIMIT/);
  assert.match(text, /messages = _claude_mem_fit_messages\(messages, system\)/);
  assert.match(text, /max_tokens = _claude_mem_dynamic_max_tokens\(max_tokens, messages, system\)/);
  assert.doesNotMatch(text, /max_tokens = min\(\s*max_tokens, int\(os\.getenv\("CLAUDE_MEM_GATEWAY_MAX_TOKENS", "384"\)\)\s*\)/);
}

const beforeChat = fs.readFileSync(chat, "utf8");
const beforeResponses = fs.readFileSync(responses, "utf8");
const second = runPatch(chat, responses);
assert.match(second, /OK/);
assert.equal(fs.readFileSync(chat, "utf8"), beforeChat);
assert.equal(fs.readFileSync(responses, "utf8"), beforeResponses);

console.log("patch-litellm-claude-mem.test.js passed");
