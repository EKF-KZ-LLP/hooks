#!/usr/bin/env bash
set -euo pipefail

roots=(
  "/Users/antonsahovskii/Dev"
  "/Users/antonsahovskii/Documents/Dev/claude-agents"
)

fail=0
checked=0

resolve_tracker() {
  local repo="$1" raw="$2"
  case "$raw" in
    ""|"__unstructured__") return 1 ;;
    /*) printf '%s\n' "$raw" ;;
    *) printf '%s\n' "$repo/$raw" ;;
  esac
}

for root in "${roots[@]}"; do
  [ -d "$root" ] || continue
  for active in "$root"/*/.claude/active-tracker "$root"/*/*/.claude/active-tracker; do
    [ -f "$active" ] || continue
    case "$active" in
      *bak*|*trash*|*/node_modules/*|*/.git/*|*/plugins/*) continue ;;
    esac
    repo="${active%/.claude/active-tracker}"
    hook="$repo/.claude/hooks/03-plan-tracker-edit-guard.sh"
    raw="$(sed -n '1p' "$active" | tr -d '\r')"
    tracker="$(resolve_tracker "$repo" "$raw" || true)"
    [ -n "${tracker:-}" ] || continue

    if [ ! -f "$tracker" ]; then
      echo "FAIL active-tracker target missing: $active -> $raw" >&2
      fail=$((fail + 1))
      continue
    fi
    if [ ! -x "$hook" ]; then
      echo "FAIL active-tracker has no executable 03 hook: $repo" >&2
      fail=$((fail + 1))
      continue
    fi

    input="$(jq -n \
      --arg cwd "$repo" \
      --arg sid "active-tracker-lint-$$" \
      --arg target "$tracker" \
      '{tool_name:"Edit", session_id:$sid, cwd:$cwd, tool_input:{file_path:$target, old_string:"- [ ] __lint_fake__", new_string:"- [x] __lint_fake__"}}')"

    set +e
    (cd "$repo" && printf '%s' "$input" | "$hook") >/tmp/active-tracker-lint.out 2>&1
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      echo "FAIL 03 hook did not recognize active tracker edit path: $repo active='$raw' target='$tracker'" >&2
      fail=$((fail + 1))
      continue
    fi

    non_tracker="$repo/.claude/__not_tracker__.md"
    input_allow="$(jq -n \
      --arg cwd "$repo" \
      --arg sid "active-tracker-lint-allow-$$" \
      --arg target "$non_tracker" \
      '{tool_name:"Edit", session_id:$sid, cwd:$cwd, tool_input:{file_path:$target, old_string:"old", new_string:"new"}}')"
    set +e
    (cd "$repo" && printf '%s' "$input_allow" | "$hook") >/tmp/active-tracker-lint-allow.out 2>&1
    allow_status=$?
    set -e
    if [ "$allow_status" -ne 0 ]; then
      echo "FAIL 03 hook blocked non-tracker edit: $repo status=$allow_status" >&2
      fail=$((fail + 1))
      continue
    fi

    echo "OK $repo active='$raw'"
    checked=$((checked + 1))
  done
done

echo "active_tracker_checked=$checked fail=$fail"
[ "$fail" -eq 0 ]
