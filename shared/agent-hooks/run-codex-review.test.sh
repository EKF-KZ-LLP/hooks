#!/usr/bin/env bash
set -euo pipefail

scripts=(
  "/Users/antonsahovskii/.claude/hooks/run-codex-review.sh"
  "/Users/antonsahovskii/.claude-personal/hooks/run-codex-review.sh"
  "/Users/antonsahovskii/.claude-work/hooks/run-codex-review.sh"
  "/Users/antonsahovskii/.claude-ekfgroup/hooks/run-codex-review.sh"
)

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/run-codex-review-test.XXXXXX")"
trap 'chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

make_plugin() {
  local plugin_root="$1"
  mkdir -p "$plugin_root/scripts"
  cat > "$plugin_root/scripts/codex-companion.mjs" <<'JS'
const mode = process.env.FAKE_CODEX_REVIEW_MODE || "pass_plain";
if (mode === "pass_plain") {
  process.stdout.write("Findings: no blocking issues\nSubagent ID: 0123456789abcdef\nVerdict: PASS\n");
} else if (mode === "pass_markdown") {
  process.stdout.write("Findings: no blocking issues\nSubagent ID: 0123456789abcdef\n**Verdict:** PASS\n");
} else if (mode === "echoed_fail_then_pass") {
  process.stdout.write("Allowed output examples:\nVerdict: FAIL\nFindings: no blocking issues\nSubagent ID: 0123456789abcdef\nVerdict: PASS\n");
} else if (mode === "fail_plain") {
  process.stdout.write("Findings: blocking issue\nSubagent ID: 0123456789abcdef\nVerdict: FAIL\n");
} else {
  process.stderr.write(`unknown fake mode: ${mode}\n`);
  process.exit(42);
}
JS
  chmod +x "$plugin_root/scripts/codex-companion.mjs"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email "test@example.invalid"
    git config user.name "Test Runner"
    printf '%s\n' 'content' > tracked.txt
    git add tracked.txt
    git commit -q -m init
  )
}

run_case() {
  local script="$1"
  local mode="$2"
  local expected="$3"
  local case_dir="$tmp_root/$(basename "$(dirname "$(dirname "$script")")")-$mode"
  local repo="$case_dir/repo"
  local plugin="$case_dir/plugin"
  local out="$case_dir/out.txt"

  make_repo "$repo"
  make_plugin "$plugin"

  set +e
  (
    cd "$repo"
    CLAUDE_PLUGIN_ROOT="$plugin" FAKE_CODEX_REVIEW_MODE="$mode" \
      bash "$script" "test-$mode"
  ) >"$out" 2>&1
  local status=$?
  set -e

  if [ "$expected" = "pass" ] && [ "$status" -ne 0 ]; then
    echo "FAIL: expected pass for $script mode=$mode status=$status" >&2
    cat "$out" >&2
    return 1
  fi

  if [ "$expected" = "fail" ] && [ "$status" -eq 0 ]; then
    echo "FAIL: expected fail for $script mode=$mode" >&2
    cat "$out" >&2
    return 1
  fi
}

for script in "${scripts[@]}"; do
  [ -x "$script" ] || { echo "FAIL: missing executable $script" >&2; exit 1; }
  run_case "$script" pass_plain pass
  run_case "$script" pass_markdown pass
  run_case "$script" echoed_fail_then_pass pass
  run_case "$script" fail_plain fail
done

echo "run-codex-review tests passed"
