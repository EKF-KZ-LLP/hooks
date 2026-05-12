#!/usr/bin/env bash
# Ralph Loop Enforcement — multi-gate hook (PreToolUse Edit|Write|MultiEdit).
#
# Closes gates from the 35-gate hard audit. See docstring at end of file
# for full mapping.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
ATTEMPT_RE='^[[:space:]]*-?[[:space:]]*attempt:[[:space:]]+[0-9]+'

deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  fi
  echo "::error::$reason" >&2
  exit 2
}

[[ -t 0 ]] && exit 0
INPUT="$(cat || true)"
[[ -n "$INPUT" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
NEW="$(printf '%s' "$INPUT" | jq -r '
  [
    (.tool_input.content // empty),
    (.tool_input.new_string // empty),
    ((.tool_input.edits // []) | map(.new_string // empty) | join("\n"))
  ] | join("\n")
' 2>/dev/null || true)"
OLD="$(printf '%s' "$INPUT" | jq -r '
  [
    (.tool_input.old_string // empty),
    ((.tool_input.edits // []) | map(.old_string // empty) | join("\n"))
  ] | join("\n")
' 2>/dev/null || true)"

# Codex round 14: for Write tool the OLD baseline must come from disk —
# tool_input has no old_string, so Write can supply [x] checkboxes без
# anything in OLD and comm -12 produces empty intersection (= zero TEC
# checks). Read the on-disk file as OLD when tool_name=Write.
if [[ "$TOOL" == "Write" && -n "$FILE" && -f "$FILE" ]]; then
  OLD="$(cat "$FILE" 2>/dev/null || true)"
fi

is_tracker=0
case "$FILE" in
  *active-tracker|*active-tracker.md|*.evidence/*plan*.md|*phase0-plan*|*-tracker.md|*plan*.md|*WORKPLAN.md|*HANDOFF.md)
    case "$FILE" in
      */node_modules/*|*/docs/*|*/.git/*) ;;
      *) is_tracker=1 ;;
    esac
    ;;
esac

# ============================================================
# Task Evidence Contract on [ ]→[x] (gates 2-7, 14)
# ============================================================
if [[ "$is_tracker" == "1" ]]; then
  new_codes=$(printf '%s\n' "$NEW" | grep -oE '\[x\][[:space:]]+\*\*[A-Z]+-?[0-9A-Z._-]+:' | sed -E 's/.*\*\*([A-Z]+-?[0-9A-Z._-]+):.*/\1/' | sort -u || true)
  old_codes=$(printf '%s\n' "$OLD" | grep -oE '\[[[:space:]]\][[:space:]]+\*\*[A-Z]+-?[0-9A-Z._-]+:' | sed -E 's/.*\*\*([A-Z]+-?[0-9A-Z._-]+):.*/\1/' | sort -u || true)
  flipped=$(comm -12 <(printf '%s\n' "$new_codes") <(printf '%s\n' "$old_codes") | grep -v '^$' || true)

  if [[ -n "$flipped" ]]; then
    while IFS= read -r code; do
      [[ -n "$code" ]] || continue
      block="$(printf '%s\n' "$NEW" | awk -v code="$code" '
        BEGIN { in_block=0 }
        $0 ~ "\\[x\\][[:space:]]+\\*\\*" code ":" { in_block=1; print; next }
        in_block && /^[[:space:]]*-[[:space:]]+\[[ xX~]\]/ { exit }
        in_block { print }
      ')"
      [[ -n "$block" ]] || continue

      evidence_path=$(printf '%s' "$block" | grep -oE 'evidence:[[:space:]]*`[^`]+`' | head -1 | sed -E 's/.*`([^`]+)`.*/\1/')
      status=$(printf '%s' "$block" | grep -oE 'status:[[:space:]]*[a-z]+' | head -1 | awk '{print $2}')
      [[ -z "$status" ]] && status="done"

      case "$status" in
        waived)
          if ! printf '%s' "$block" | grep -qE 'risk:[[:space:]]+'; then
            deny "TASK $code: status=waived requires 'risk:' field with rationale."
          fi
          continue
          ;;
        done|verified) ;;
        *)
          deny "TASK $code: closed [x] but status=$status (allowed: done|verified|waived)."
          ;;
      esac

      if [[ -z "$evidence_path" ]]; then
        deny "TASK $code: [ ]->[x] without 'evidence:' field. TEC requires evidence path."
      fi
      abs="$PROJECT_DIR/$evidence_path"
      if [[ ! -f "$abs" ]]; then deny "TASK $code: evidence file '$evidence_path' missing."; fi
      if [[ ! -s "$abs" ]]; then deny "TASK $code: evidence file '$evidence_path' empty."; fi
      if ! grep -qE '^Verdict:[[:space:]]+(PASS|APPROVED)\b' "$abs"; then
        deny "TASK $code: evidence '$evidence_path' missing literal 'Verdict: PASS'."
      fi
      missing=()
      grep -qE '^(Command|Verify command|Verify|Test command|How verified):' "$abs" 2>/dev/null || missing+=("command/verify")
      grep -qE '^(Result|Outcome|Logs|Output):' "$abs" 2>/dev/null || missing+=("result/output")
      grep -qE '^(Commit|SHA|Fix commit):' "$abs" 2>/dev/null || missing+=("commit/SHA")
      if (( ${#missing[@]} > 0 )); then
        deny "TASK $code: evidence '$evidence_path' missing sections: ${missing[*]}."
      fi
      commit_in_evidence=$(grep -oE '[0-9a-f]{40}' "$abs" | head -1)
      if [[ -n "$commit_in_evidence" ]]; then
        head_sha=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)
        if [[ -n "$head_sha" ]] && ! git -C "$PROJECT_DIR" merge-base --is-ancestor "$commit_in_evidence" "$head_sha" 2>/dev/null; then
          deny "TASK $code: evidence commit $commit_in_evidence not an ancestor of HEAD ($head_sha) - review stale, re-run."
        fi
      fi
    done <<< "$flipped"
  fi

  # ============================================================
  # blocked/failed gate (gates 26-28, 32)
  # ============================================================
  blocked_added=$(printf '%s\n' "$NEW" | grep -cE 'status:[[:space:]]*(blocked|failed)' || true)
  blocked_old=$(printf '%s\n' "$OLD" | grep -cE 'status:[[:space:]]*(blocked|failed)' || true)
  if (( blocked_added > blocked_old )); then
    handoff="$PROJECT_DIR/HANDOFF.md"
    if [[ ! -f "$handoff" ]]; then
      deny "blocked/failed requires HANDOFF.md with attempt log. File missing."
    fi
    if ! grep -qE "$ATTEMPT_RE" "$handoff"; then
      deny "blocked/failed: HANDOFF.md has no '- attempt: N' machine-readable entries."
    fi
    last_block=$(awk '/^[[:space:]]*-[[:space:]]+attempt:/{found=1; block=""} found {block = block $0 "\n"} END{print block}' "$handoff")
    for field in task_id hypothesis action command_or_artifact result next_decision evidence timestamp; do
      if ! printf '%s' "$last_block" | grep -qE "^[[:space:]]*-?[[:space:]]*${field}:"; then
        deny "blocked/failed: last attempt in HANDOFF.md missing field '${field}'."
      fi
    done
    blocker_text=$(printf '%s' "$NEW" | grep -A2 -E 'status:[[:space:]]*(blocked|failed)' | head -10)
    if printf '%s' "$blocker_text" | grep -qiE 'не получилось|тесты падают|ошибка|неясно|нужно разобраться|probably impossible|не работает'; then
      deny "G32 invalid blocker text. Use specific actionable blocker."
    fi

    # ============================================================
    # G35: retry budget. Per task_id, count attempt entries in HANDOFF.
    # If >= MAX_ATTEMPTS (default 3) AND no strategy_shift recorded
    # for that task → BLOCK. Forces re-plan via Senior/Codex consult.
    # ============================================================
    MAX_ATTEMPTS="${RALPH_MAX_ATTEMPTS:-3}"
    blocked_codes=$(printf '%s\n' "$NEW" \
      | awk '/status:[[:space:]]*(blocked|failed)/{found=1} found && /\*\*[A-Z]+-?[0-9A-Z._-]+:/ {match($0,/\*\*([A-Z]+-?[0-9A-Z._-]+):/,a); print a[1]; found=0}' \
      | sort -u || true)
    while IFS= read -r code; do
      [[ -n "$code" ]] || continue
      n=$(awk -v c="$code" '
        /^[[:space:]]*-[[:space:]]+attempt:/ {block=""}
        {block = block $0 "\n"}
        $0 ~ "task_id:[[:space:]]*" c "([^A-Za-z0-9_-]|$)" {count++}
        END {print count+0}
      ' "$handoff")
      if (( n >= MAX_ATTEMPTS )); then
        if ! grep -qE "strategy_shift:[[:space:]]*${code}\b" "$handoff" 2>/dev/null; then
          deny "G35 retry-budget: task $code has $n attempts (>= $MAX_ATTEMPTS) without strategy_shift entry in HANDOFF.md. Required: 'strategy_shift: $code reason: <new-approach>' line + Senior/Codex consult evidence."
        fi
        # G31 consult-at-stuck: strategy_shift entry must reference review evidence
        if ! grep -qE "strategy_shift:[[:space:]]*${code}.*evidence:[[:space:]]*[^[:space:]]+\.md" "$handoff" 2>/dev/null; then
          deny "G31 consult-at-stuck: strategy_shift for $code must include 'evidence: <path>.md' pointing to Senior/Codex review."
        fi
      fi
    done <<< "$blocked_codes"
  fi
fi

# ============================================================
# G16: plan-vs-code drift detection.
# When source file edited, the active tracker MUST reference
# this file (by basename or full path) in some in-progress task
# block. If no in-progress task mentions it → BLOCK as plan drift.
# Skipped if no active-tracker pointer (legacy projects).
# ============================================================
case "$FILE" in
  *.go|*.py|*.ts|*.tsx|*.js|*.jsx|*.rs|*.java|*.kt|*.swift|*.rb)
    case "$FILE" in
      */node_modules/*|*/dist/*|*/build/*|*/vendor/*|*/.git/*|*_test.go|*.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx|*_test.py|*test_*.py) ;;
      *)
        active_ptr="$PROJECT_DIR/.claude/active-tracker"
        if [[ -f "$active_ptr" ]]; then
          tracker_file=$(<"$active_ptr")
          if [[ -f "$tracker_file" ]]; then
            base=$(basename "$FILE")
            rel="${FILE#$PROJECT_DIR/}"
            # Need at least one in-progress task that mentions this file.
            inprog=$(awk '
              /^- \[ \][[:space:]]+\*\*[A-Z]+-?[0-9A-Z._-]+:/{block=""; in_block=1}
              in_block {block=block $0 "\n"}
              /^- \[[xX~]\]/{ if(in_block){print block; print "---END---"}; in_block=0; block=""}
              END {if(in_block) print block}
            ' "$tracker_file")
            if [[ -n "$inprog" ]] \
               && ! printf '%s' "$inprog" | grep -qF "$base" \
               && ! printf '%s' "$inprog" | grep -qF "$rel"; then
              # Check OVERRIDE escape: command/edit content can contain
              # `OVERRIDE: drift <basename> reason: <text>` to allow.
              if ! printf '%s' "$NEW" | grep -qE "OVERRIDE:[[:space:]]+drift[[:space:]]+${base}[[:space:]]+reason:"; then
                deny "G16 plan-vs-code drift: file '$rel' edited but no in-progress task in active-tracker mentions it. Update tracker first OR add 'OVERRIDE: drift $base reason: <text>' to bypass."
              fi
            fi
          fi
        fi
        ;;
    esac
    ;;
esac

# ============================================================
# G15: WORKPLAN freshness after code change
# ============================================================
case "$FILE" in
  *.go|*.py|*.ts|*.tsx|*.js|*.jsx|*.sh|*.sql|*.yml|*.yaml|*.toml|*.json)
    case "$FILE" in
      */node_modules/*|*/dist/*|*/build/*|*.evidence/*|*.checkpoints/*) ;;
      *)
        wp="$PROJECT_DIR/WORKPLAN.md"
        if [[ -f "$wp" && -d "$PROJECT_DIR/.git" ]]; then
          last_code_commit=$(git -C "$PROJECT_DIR" log -1 --format=%ct -- '*.go' '*.py' '*.ts' '*.tsx' 2>/dev/null || echo 0)
          wp_mtime=$(stat -f %m "$wp" 2>/dev/null || stat -c %Y "$wp" 2>/dev/null || echo 0)
          if [[ "$last_code_commit" != "0" ]] && (( wp_mtime < last_code_commit - 7200 )); then
            deny "WORKPLAN.md mtime ($wp_mtime) older than last code commit ($last_code_commit) by >2h. Update WORKPLAN.md before new code edits (G15)."
          fi
        fi
        ;;
    esac
    ;;
esac

exit 0

# Gate coverage:
#   G2-G7,G14 (TEC): item code parsing + evidence file check + Verdict/Command/Result/Commit sections.
#   G9-G10 (review SHA freshness): evidence commit must be ancestor of HEAD.
#   G11 (delete required = WAIVE): future extension via comm -23 on old vs new required-line set.
#   G15 (WORKPLAN freshness): block code edits when WORKPLAN.mtime < last code commit ts - 2h.
#   G26-G28,G32 (blocked/failed gate): attempt log schema validation + invalid blocker words.
#   G35 (retry-budget): per task_id attempt counter + strategy_shift gate.
#   G31 (consult-at-stuck): strategy_shift entry requires Senior/Codex evidence path.
#   G16 (plan-vs-code drift): source file edits require active-task mention; OVERRIDE escape.
