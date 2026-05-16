#!/usr/bin/env bash
set -euo pipefail

DB=${CLAUDE_MEM_WATCHDOG_DB:-/Users/antonsahovskii/.claude-mem/claude-mem.db}
API_URL=${CLAUDE_MEM_WATCHDOG_API_URL:-http://127.0.0.1:37701/api/processing-status}
STATE_DIR=${CLAUDE_MEM_WATCHDOG_STATE_DIR:-/Users/antonsahovskii/.claude-mem/watchdog-state}
MAINTENANCE=${CLAUDE_MEM_WATCHDOG_MAINTENANCE:-/Users/antonsahovskii/.local/share/agent-hooks/claude-mem-db-maintenance.sh}
NOW_MS=""
STALE_MS=${CLAUDE_MEM_STALE_QUEUE_MS:-120000}
ACTIVE_STALE_MS=${CLAUDE_MEM_WATCHDOG_ACTIVE_STALE_MS:-0}
AGE_THRESHOLD_MS=${CLAUDE_MEM_WATCHDOG_AGE_THRESHOLD_MS:-900000}
MAX_TRACK_MS=${CLAUDE_MEM_WATCHDOG_MAX_TRACK_MS:-86400000}
API_TIMEOUT=${CLAUDE_MEM_WATCHDOG_API_TIMEOUT_SECONDS:-2}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --db)
      DB="$2"
      shift 2
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --no-api)
      API_URL="none"
      shift
      ;;
    --state-dir)
      STATE_DIR="$2"
      shift 2
      ;;
    --now-ms)
      NOW_MS="$2"
      shift 2
      ;;
    --stale-ms)
      STALE_MS="$2"
      shift 2
      ;;
    --active-stale-ms)
      ACTIVE_STALE_MS="$2"
      shift 2
      ;;
    --age-threshold-ms)
      AGE_THRESHOLD_MS="$2"
      shift 2
      ;;
    --max-track-ms)
      MAX_TRACK_MS="$2"
      shift 2
      ;;
    *)
      echo "unknown_arg=$1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$NOW_MS" ]; then
  NOW_MS="$(($(date +%s) * 1000))"
fi

api_status=not_checked
queue_depth=0
if [ "$API_URL" != "none" ]; then
  api_body=$(curl -fsS --max-time "$API_TIMEOUT" "$API_URL" 2>/dev/null || true)
  if [ -n "$api_body" ]; then
    api_status=ok
    parsed_depth=$(printf '%s' "$api_body" | sed -n 's/.*"queueDepth"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
    queue_depth=${parsed_depth:-0}
  else
    api_status=unavailable
  fi
fi

pending_messages=0
oldest_pending_age_ms=0
if [ -f "$DB" ]; then
  has_pending=$(/usr/bin/sqlite3 "$DB" "select count(*) from sqlite_master where type='table' and name='pending_messages';")
  if [ "$has_pending" = "1" ]; then
    pending_messages=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where status in ('pending', 'processing');")
    oldest_created=$(/usr/bin/sqlite3 "$DB" "select coalesce(min(created_at_epoch), 0) from pending_messages where status in ('pending', 'processing');")
    if [ "$oldest_created" != "0" ]; then
      oldest_pending_age_ms="$((NOW_MS - oldest_created))"
      if [ "$oldest_pending_age_ms" -lt 0 ]; then
        oldest_pending_age_ms=0
      fi
    fi
  fi
fi

mkdir -p "$STATE_DIR"
state_file="$STATE_DIR/queue.json"
queue_observed_for_ms=0
if [ "$queue_depth" -gt 0 ] || [ "$pending_messages" -gt 0 ]; then
  first_seen=""
  if [ -f "$state_file" ]; then
    first_seen=$(sed -n 's/.*"first_seen_ms"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$state_file" | head -n 1)
  fi
  case "$first_seen" in
    ""|*[!0-9]*)
      first_seen=""
      ;;
    *)
      if [ "$first_seen" -le 0 ] || [ "$first_seen" -gt "$NOW_MS" ]; then
        first_seen=""
      elif [ "$((NOW_MS - first_seen))" -gt "$MAX_TRACK_MS" ]; then
        first_seen=""
      fi
      ;;
  esac
  if [ -z "$first_seen" ]; then
    first_seen="$NOW_MS"
    printf '{"first_seen_ms":%s}\n' "$first_seen" >"$state_file"
  fi
  queue_observed_for_ms="$((NOW_MS - first_seen))"
  if [ "$queue_observed_for_ms" -lt 0 ]; then
    queue_observed_for_ms=0
  fi
else
  rm -f "$state_file"
fi

echo "api_status=$api_status"
echo "queue_depth=$queue_depth"
echo "pending_messages=$pending_messages"
echo "oldest_pending_age_ms=$oldest_pending_age_ms"
echo "queue_observed_for_ms=$queue_observed_for_ms"

if [ "$oldest_pending_age_ms" -lt "$AGE_THRESHOLD_MS" ] && [ "$queue_observed_for_ms" -lt "$AGE_THRESHOLD_MS" ]; then
  echo "watchdog_action=none"
  exit 0
fi

if [ ! -x "$MAINTENANCE" ]; then
  echo "watchdog_action=maintenance_missing"
  echo "missing_maintenance=$MAINTENANCE" >&2
  exit 1
fi

echo "watchdog_action=maintenance"
"$MAINTENANCE" \
  --db "$DB" \
  --now-ms "$NOW_MS" \
  --stale-ms "$STALE_MS" \
  --active-stale-ms "$ACTIVE_STALE_MS"
