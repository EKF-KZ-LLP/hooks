#!/usr/bin/env node
const fs = require("node:fs");

const DEFAULT_CHAT =
  "/Users/antonsahovskii/.local/share/uv/tools/litellm/lib/python3.13/site-packages/litellm/llms/anthropic/experimental_pass_through/adapters/handler.py";
const DEFAULT_RESPONSES =
  "/Users/antonsahovskii/.local/share/uv/tools/litellm/lib/python3.13/site-packages/litellm/llms/anthropic/experimental_pass_through/responses_adapters/handler.py";

const HELPER = `
def _claude_mem_token_chars() -> float:
    try:
        return max(float(os.getenv("CLAUDE_MEM_TOKEN_CHARS", "3.5")), 1.0)
    except Exception:
        return 3.5


def _claude_mem_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\\n".join(_claude_mem_text(item) for item in value)
    if isinstance(value, dict):
        return "\\n".join(_claude_mem_text(item) for item in value.values())
    return str(value)


def _claude_mem_estimate_tokens(*values: Any) -> int:
    chars = sum(len(_claude_mem_text(value)) for value in values)
    return int(chars / _claude_mem_token_chars()) + 1


def _claude_mem_trim_text(text: str, max_tokens: int) -> str:
    max_chars = max(int(max_tokens * _claude_mem_token_chars()), 256)
    if len(text) <= max_chars:
        return text
    marker = (
        "\\n[claude-mem-truncated reason=context_budget "
        f"original_chars={len(text)} kept_chars={max_chars}]\\n"
    )
    head = max_chars // 2
    tail = max_chars - head
    lines = text.splitlines()
    important = [
        line
        for line in lines
        if any(
            token in line.lower()
            for token in ("error", "warn", "exception", "traceback", "failed", "fatal", "http 4", "http 5")
        )
    ][:120]
    important_text = "\\n".join(important)
    if important_text:
        marker += f"[claude-mem-important-lines]\\n{important_text}\\n[/claude-mem-important-lines]\\n"
    return text[:head] + marker + text[-tail:]


def _claude_mem_trim_value(value: Any, max_tokens: int) -> Any:
    if isinstance(value, str):
        return _claude_mem_trim_text(value, max_tokens)
    if isinstance(value, list):
        return [_claude_mem_trim_value(item, max_tokens) for item in value]
    if isinstance(value, dict):
        return {key: _claude_mem_trim_value(item, max_tokens) for key, item in value.items()}
    return value


def _claude_mem_fit_messages(messages: List[Dict], system: Optional[str]) -> List[Dict]:
    target = int(os.getenv("CLAUDE_MEM_LOCAL_INPUT_TARGET_TOKENS", "56000"))
    max_context_messages = int(os.getenv("CLAUDE_MEM_LOCAL_MAX_CONTEXT_MESSAGES", "16"))
    max_message_tokens = int(os.getenv("CLAUDE_MEM_LOCAL_MAX_MESSAGE_TOKENS", "12000"))
    fitted = []
    for message in messages:
        next_message = dict(message)
        if "content" in next_message:
            next_message["content"] = _claude_mem_trim_value(next_message["content"], max_message_tokens)
        fitted.append(next_message)
    if len(fitted) > max_context_messages:
        keep_recent = max(max_context_messages - 1, 1)
        fitted = [fitted[0], *fitted[-keep_recent:]]
    while len(fitted) > 2 and _claude_mem_estimate_tokens(system, fitted) > target:
        fitted.pop(1)
    if fitted and _claude_mem_estimate_tokens(system, fitted) > target:
        last = dict(fitted[-1])
        last["content"] = _claude_mem_trim_value(last.get("content", ""), max(target // 2, 1024))
        fitted[-1] = last
    return fitted


def _claude_mem_dynamic_max_tokens(max_tokens: int, messages: List[Dict], system: Optional[str]) -> int:
    limit = int(os.getenv("CLAUDE_MEM_LOCAL_CONTEXT_LIMIT", "65536"))
    safety = int(os.getenv("CLAUDE_MEM_LOCAL_SAFETY_TOKENS", "1536"))
    output_min = int(os.getenv("CLAUDE_MEM_LOCAL_OUTPUT_MIN_TOKENS", "160"))
    output_max = int(
        os.getenv(
            "CLAUDE_MEM_LOCAL_OUTPUT_MAX_TOKENS",
            os.getenv("CLAUDE_MEM_GATEWAY_MAX_TOKENS", "512"),
        )
    )
    estimated_input = _claude_mem_estimate_tokens(system, messages)
    available = limit - estimated_input - safety
    if available <= 0:
        return max(1, min(max_tokens, output_min))
    return max(1, min(max_tokens, output_max, max(output_min, available)))
`.trim();

function parseArgs(argv) {
  const out = { chat: DEFAULT_CHAT, responses: DEFAULT_RESPONSES };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--chat") {
      out.chat = argv[++index];
    } else if (arg === "--responses") {
      out.responses = argv[++index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return out;
}

function ensureImportOs(text) {
  if (/^import os$/m.test(text)) return [text, false];
  if (text.includes("from typing import")) {
    return [text.replace("from typing import", "import os\nfrom typing import"), true];
  }
  return [`import os\n${text}`, true];
}

function ensureHelper(text) {
  if (text.includes("def _claude_mem_dynamic_max_tokens")) return [text, false];
  const anchors = [
    "\nclass LiteLLMMessagesToCompletionTransformationHandler:",
    "\ndef _build_responses_kwargs(",
    "\ndef call_gateway(",
  ];
  for (const anchor of anchors) {
    if (text.includes(anchor)) {
      return [text.replace(anchor, `\n\n${HELPER}\n${anchor}`), true];
    }
  }
  const adapterMatch = text.match(/(_ADAPTER\s*=\s*[^\n]+\n)/);
  if (adapterMatch) {
    return [text.replace(adapterMatch[1], `${adapterMatch[1]}\n${HELPER}\n\n`), true];
  }
  return [`${HELPER}\n\n${text}`, true];
}

function replaceStaticCap(text) {
  const staticCap =
    /^([ \t]*)max_tokens = min\(\n\1[ \t]*max_tokens, int\(os\.getenv\("CLAUDE_MEM_GATEWAY_MAX_TOKENS", "[0-9]+"\)\)\n\1\)/m;
  const match = text.match(staticCap);
  if (!match) return [text, false];
  const indent = match[1];
  const dynamic = [
    `${indent}messages = _claude_mem_fit_messages(messages, system)`,
    `${indent}max_tokens = _claude_mem_dynamic_max_tokens(max_tokens, messages, system)`,
  ].join("\n");
  return [text.replace(staticCap, dynamic), true];
}

function ensureDynamicCall(text) {
  if (text.includes("max_tokens = _claude_mem_dynamic_max_tokens(max_tokens, messages, system)")) {
    return [text, false];
  }
  const anchors = [
    /(^[ \t]*)request_data = \{\n\1[ \t]*"model": model,/m,
    /(^[ \t]*)# Build a typed AnthropicMessagesRequest for the adapter/m,
  ];
  for (const anchor of anchors) {
    const match = text.match(anchor);
    if (match) {
      const indent = match[1];
      const dynamic = [
        `${indent}messages = _claude_mem_fit_messages(messages, system)`,
        `${indent}max_tokens = _claude_mem_dynamic_max_tokens(max_tokens, messages, system)`,
        "",
        match[0],
      ].join("\n");
      return [text.replace(anchor, dynamic), true];
    }
  }
  return [text, false];
}

function ensureToolStrip(text) {
  if (text.includes("CLAUDE_MEM_STRIP_TOOLS")) return [text, false];
  const dynamic = "max_tokens = _claude_mem_dynamic_max_tokens(max_tokens, messages, system)";
  const index = text.indexOf(dynamic);
  if (index === -1) return [text, false];
  const lineStart = text.lastIndexOf("\n", index) + 1;
  const indent = text.slice(lineStart, index);
  const insertion = [
    dynamic,
    `${indent}if os.getenv("CLAUDE_MEM_STRIP_TOOLS", "true").lower() in ("1", "true", "yes"):`,
    `${indent}    tool_choice = None`,
    `${indent}    tools = None`,
  ].join("\n");
  return [text.replace(dynamic, insertion), true];
}

function patchFile(file) {
  if (!file || !fs.existsSync(file)) {
    console.log(`MISSING ${file}`);
    return false;
  }
  let text = fs.readFileSync(file, "utf8");
  const original = text;
  for (const transform of [ensureImportOs, ensureHelper, replaceStaticCap, ensureDynamicCall, ensureToolStrip]) {
    [text] = transform(text);
  }
  if (text !== original) {
    fs.writeFileSync(file, text);
    console.log(`PATCHED ${file}`);
    return true;
  }
  console.log(`OK ${file}`);
  return false;
}

function main() {
  const args = parseArgs(process.argv);
  patchFile(args.chat);
  patchFile(args.responses);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
