#!/usr/bin/env bash
# Ralph Loop PreToolUse hook.
# It blocks an Edit that turns a phase0 plan item from unchecked to checked
# until that item's verify command passes.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PLAN_FILE="$PROJECT_DIR/.evidence/phase0-plan.md"
PROJECT_KEY="$(printf '%s' "$PROJECT_DIR" | cksum | awk '{print $1}')"
GUARD_FILE="${TMPDIR:-/tmp}/ralph-loop-generated-${PROJECT_KEY}.guard"
GUARD_CREATED=0

log() {
  printf '%s\n' "$*" >&2
}

cleanup() {
  rm -f "${OLD_TMP:-}" "${NEW_TMP:-}" "${CANDIDATES_TMP:-}"
  if [[ "${GUARD_CREATED:-0}" == "1" ]]; then
    rm -f "$GUARD_FILE"
  fi
}

deny() {
  # Claude Code can read structured hook output; exit 1 is the requested block.
  local reason="$1"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 1
}

is_generated_path() {
  # Generated edits must not recurse while a guarded verify command is running.
  case "$1" in
    *.pb.go|*_gen.go|vendor/*|*/vendor/*|.build/*|*/.build/*) return 0 ;;
    *) return 1 ;;
  esac
}

needs_generated_guard() {
  # Bash cannot know future writes without running the command, so guard commands
  # that name generated paths or common generators/builders.
  case "$1" in
    *".pb.go"*|*"_gen.go"*|*"vendor/"*|*".build/"*|*"go generate"*|*"protoc "*|*"buf generate"*|*"npm run build"*|*"yarn build"*|*"pnpm build"*) return 0 ;;
    *) return 1 ;;
  esac
}

extract_verify() {
  # The closed line is found from old_string/new_string only; the plan is read
  # only to fetch the verify line that belongs to that exact item block.
  local target="$1"
  awk -v target="$target" '
    $0 == target { found=1; next }
    found && /^[[:space:]]*-[[:space:]]+\[[ xX]\]/ { exit }
    found && /^[[:space:]]*-[[:space:]]+verify:[[:space:]]+`/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]+verify:[[:space:]]+`/, "", line)
      sub(/`[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$PLAN_FILE"
}

extract_evidence() {
  # Optional `evidence: <relative path>` field. When present, hook also requires
  # the file to:
  #   1. Exist after verify command finishes.
  #   2. Contain literal 'Verdict: PASS' line.
  #   3. Be chmod 0444 (read-only — anti-tamper).
  #   4. Have mtime >= run-epoch (created or refreshed in this session).
  local target="$1"
  awk -v target="$target" '
    $0 == target { found=1; next }
    found && /^[[:space:]]*-[[:space:]]+\[[ xX]\]/ { exit }
    found && /^[[:space:]]*-[[:space:]]+evidence:[[:space:]]+`/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]+evidence:[[:space:]]+`/, "", line)
      sub(/`[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$PLAN_FILE"
}

check_evidence() {
  local item_line="$1"
  local evidence_rel="$2"
  local abs="$PROJECT_DIR/$evidence_rel"
  # Read run-epoch from file written by SessionStart. env vars don't survive
  # across hook invocations; a file under TMPDIR keyed by project hash does.
  # Without this read the mtime gate is silently disabled (Codex round 4).
  local epoch_file="${TMPDIR:-/tmp}/ralph-run-epoch-${PROJECT_KEY}"
  local run_epoch="0"
  if [[ -f "$epoch_file" ]]; then
    run_epoch="$(cat "$epoch_file" 2>/dev/null || echo 0)"
  fi
  if [[ ! -f "$abs" ]]; then
    deny "evidence file missing: $evidence_rel (declared on $item_line)"
  fi
  if ! grep -qE '^Verdict:[[:space:]]+PASS\b' "$abs"; then
    deny "evidence file $evidence_rel must contain literal 'Verdict: PASS'"
  fi
  local perms
  perms="$(stat -f '%Lp' "$abs" 2>/dev/null || stat -c '%a' "$abs" 2>/dev/null || echo unknown)"
  if [[ "$perms" != "444" ]]; then
    deny "evidence file $evidence_rel must be chmod 0444 (got $perms) — anti-tamper. Run: chmod 444 $evidence_rel"
  fi
  if [[ "$run_epoch" != "0" ]]; then
    local mtime
    mtime="$(stat -f '%m' "$abs" 2>/dev/null || stat -c '%Y' "$abs" 2>/dev/null || echo 0)"
    if [[ "$mtime" -lt "$run_epoch" ]]; then
      deny "evidence file $evidence_rel mtime ($mtime) is older than run-epoch ($run_epoch) — file pre-exists this session, regenerate."
    fi
  fi
}

run_verify() {
  local item_line="$1"
  local verify_cmd="$2"
  local verify_log
  verify_log="$(mktemp "${TMPDIR:-/tmp}/ralph-verify.XXXXXX")"

  if needs_generated_guard "$verify_cmd"; then
    # The guard is visible to concurrent hook invocations during this verify run.
    GUARD_CREATED=1
    printf 'guarded verify: %s\n' "$verify_cmd" >"$GUARD_FILE"
  fi

  log "ralph-loop: verifying checked plan item"
  log "$item_line"
  local status=0
  bash -lc "$verify_cmd" >"$verify_log" 2>&1 || status=$?
  if [[ $status -eq 0 ]]; then
    rm -f "$verify_log"
    return 0
  fi

  local tail_output
  tail_output="$(tail -40 "$verify_log" 2>/dev/null || true)"
  rm -f "$verify_log"
  deny "verify failed with exit ${status}: ${verify_cmd}
${tail_output}"
}

if ! command -v jq >/dev/null 2>&1; then
  log "ralph-loop: jq is required to parse PreToolUse JSON"
  exit 1
fi

INPUT="$(cat || true)"
if ! printf '%s' "$INPUT" | jq -e type >/dev/null 2>&1; then
  log "ralph-loop: invalid PreToolUse JSON"
  exit 1
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

if [[ -f "$GUARD_FILE" ]] && is_generated_path "$FILE_PATH"; then
  exit 0
fi

case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  ExitPlanMode)
    # Plan mode dumps the proposed plan into chat but does NOT persist a file.
    # Capture the plan content to .evidence/plans/exitplanmode-<ts>.md so
    # Ralph Loop has an audit record even if the plan was never accepted.
    #
    # Hard-gate (Codex round 5): EVERY failure path must deny — silent loss
    # would let plan-mode bypass tracking entirely.
    PLAN_TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.plan // empty' 2>/dev/null || true)"
    if [[ -z "$PLAN_TEXT" ]]; then
      # No plan content → nothing to capture, allow (plan-mode exit без plan
      # is a no-op semantically).
      exit 0
    fi
    DUMP_DIR="$PROJECT_DIR/.evidence/plans"
    if ! mkdir -p "$DUMP_DIR" 2>/dev/null; then
      deny "ExitPlanMode capture failed: cannot create $DUMP_DIR. Plan would be lost — fix permission/disk issue and retry."
    fi
    DUMP="$DUMP_DIR/exitplanmode-$(date +%Y%m%d-%H%M%S).md"
    if ! {
      printf '<!-- ralph-loop: ExitPlanMode auto-capture -->\n'
      printf '<!-- captured: %s -->\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\n' "$PLAN_TEXT"
    } >"$DUMP" 2>/dev/null; then
      deny "ExitPlanMode capture failed: write to $DUMP errored. Plan would be lost — fix and retry."
    fi
    if [[ ! -s "$DUMP" ]]; then
      deny "ExitPlanMode capture failed: $DUMP is empty after write. Plan would be lost."
    fi
    # chmod 0444 immediately — agent (or future hook bug) cannot tamper after.
    chmod 0444 "$DUMP" 2>/dev/null || true
    jq -n --arg dump "$DUMP" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:("Plan captured to " + $dump + " (chmod 0444). To track in Ralph Loop, copy items into .evidence/phase0-plan.md as `- [ ] **CODE: title**` blocks with verify: commands.")}}'
    exit 0
    ;;
  *) exit 0 ;;
esac

# --- Evidence anti-tamper: never edit existing evidence.md ---
case "$FILE_PATH" in
  *.evidence/checkpoints/*/evidence.md)
    if [[ -f "$FILE_PATH" ]]; then
      deny "evidence file $FILE_PATH is anti-tamper-protected. Regenerate via verify command + chmod 444 от сборщика, не правь руками."
    fi
    ;;
esac

# --- Plan location guard: any new plan-like file MUST live in .evidence/ ---
# Blocks creating .md files matching '*plan*.md' / '*roadmap*.md' / '*tracker*.md'
# outside .evidence/ — forces plan mode artifacts into the canonical bucket
# that this hook (and stop.sh) actually monitor.
case "$FILE_PATH" in
  *plan*.md|*roadmap*.md|*tracker*.md|*PLAN*.md|*ROADMAP*.md|*TRACKER*.md)
    case "$FILE_PATH" in
      *.evidence/*|*WORKPLAN.md|*HANDOFF.md|*docs/superpowers/plans/*|*docs/superpowers/specs/*|*docs/adr/*|*docs/audit/*) ;;
      *)
        # Only Write of NEW file gets blocked. Edit of existing is allowed.
        if [[ "$TOOL_NAME" == "Write" && ! -f "$FILE_PATH" ]]; then
          deny "plan-like file '$FILE_PATH' must live in .evidence/ (or docs/superpowers/{plans,specs}). Otherwise Ralph Loop hooks won't track it."
        fi
        ;;
    esac
    ;;
esac

case "$FILE_PATH" in
  .evidence/phase0-plan.md|*/.evidence/phase0-plan.md) ;;
  *) exit 0 ;;
esac

[[ -f "$PLAN_FILE" ]] || deny "plan file not found: $PLAN_FILE"

OLD_TMP="$(mktemp "${TMPDIR:-/tmp}/ralph-old.XXXXXX")"
NEW_TMP="$(mktemp "${TMPDIR:-/tmp}/ralph-new.XXXXXX")"
CANDIDATES_TMP="$(mktemp "${TMPDIR:-/tmp}/ralph-candidates.XXXXXX")"
trap cleanup EXIT

# scan_pair: extract [ ]→[x] candidates from a single (old_text,new_text) pair.
#
# Match key = STABLE item code (e.g. 'C-5', 'B-1') extracted from the bold
# prefix `**<CODE>:`. Matching the FULL line was bypassable: rename text +
# flip checkbox в одном Edit/Write — no match. Item code is invariant
# unless the entire row is removed/renamed (which is renaming completion,
# not bypass — Codex round 3 closure).
#
# Algorithm:
#   1. Pass NEW: collect codes of all `[x]` lines whose item code matches.
#   2. Pass OLD: print [ ] lines whose code is in the checked set.
# Fallback: if a `[x]` line has no extractable code, fall back to full-line
# match (covers ad-hoc lists без item code).
scan_pair() {
  local old_text="$1" new_text="$2"
  printf '%s\n' "$old_text" | tr -d '\r' >"$OLD_TMP"
  printf '%s\n' "$new_text" | tr -d '\r' >"$NEW_TMP"
  awk '
    function code_of(line,    s, code) {
      s = line
      if (match(s, /\*\*[^:*]+:/)) {
        code = substr(s, RSTART+2, RLENGTH-3)
        gsub(/[[:space:]]+$/, "", code)
        gsub(/^[[:space:]]+/, "", code)
        return code
      }
      return ""
    }
    FNR==NR {
      # NEW pass: index lines marked [x].
      if (index($0, "[x]")) {
        c = code_of($0)
        if (c != "") {
          checked_code[c] = 1
        } else {
          key = $0
          gsub(/\[x\]/, "[?]", key)
          checked_full[key] = 1
        }
      }
      next
    }
    /^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+\*\*/ {
      # OLD pass: print [ ] lines whose item code (or full line) was checked
      # in the new content.
      c = code_of($0)
      if (c != "" && checked_code[c]) { print $0; next }
      key = $0
      gsub(/\[ \]/, "[?]", key)
      if (checked_full[key]) { print $0 }
    }
  ' "$NEW_TMP" "$OLD_TMP" >>"$CANDIDATES_TMP"
}

case "$TOOL_NAME" in
  Edit)
    OLD_STRING="$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null || true)"
    NEW_STRING="$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null || true)"
    scan_pair "$OLD_STRING" "$NEW_STRING"
    ;;
  Write)
    # Write replaces the whole file. Compare current on-disk content vs incoming
    # content — anything flipped from [ ] to [x] needs verify.
    NEW_CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)"
    OLD_CONTENT=""
    if [[ -f "$FILE_PATH" ]]; then
      OLD_CONTENT="$(cat "$FILE_PATH")"
    elif [[ -f "$PLAN_FILE" ]]; then
      OLD_CONTENT="$(cat "$PLAN_FILE")"
    fi
    scan_pair "$OLD_CONTENT" "$NEW_CONTENT"
    ;;
  MultiEdit)
    # MultiEdit: tool_input.edits is an array of {old_string,new_string}.
    EDIT_COUNT="$(printf '%s' "$INPUT" | jq -r '.tool_input.edits | length // 0' 2>/dev/null || echo 0)"
    if [[ "${EDIT_COUNT:-0}" =~ ^[0-9]+$ ]] && [[ "$EDIT_COUNT" -gt 0 ]]; then
      for ((i=0; i<EDIT_COUNT; i++)); do
        eo="$(printf '%s' "$INPUT" | jq -r ".tool_input.edits[$i].old_string // empty" 2>/dev/null || true)"
        en="$(printf '%s' "$INPUT" | jq -r ".tool_input.edits[$i].new_string // empty" 2>/dev/null || true)"
        scan_pair "$eo" "$en"
      done
    fi
    ;;
esac

[[ -s "$CANDIDATES_TMP" ]] || exit 0

# Deduplicate identical candidate lines so verify не запускается дважды.
sort -u "$CANDIDATES_TMP" -o "$CANDIDATES_TMP"

while IFS= read -r item_line; do
  [[ -n "$item_line" ]] || continue
  verify_cmd="$(extract_verify "$item_line" || true)"
  [[ -n "$verify_cmd" ]] || deny "verify command not found for plan item: $item_line"
  run_verify "$item_line" "$verify_cmd"
  evidence_rel="$(extract_evidence "$item_line" || true)"
  if [[ -n "$evidence_rel" ]]; then
    check_evidence "$item_line" "$evidence_rel"
  fi
done <"$CANDIDATES_TMP"

exit 0
