#!/usr/bin/env bash
set -euo pipefail

DB=/Users/antonsahovskii/.claude-mem/claude-mem.db
NOW_MS=""
STALE_MS=${CLAUDE_MEM_STALE_QUEUE_MS:-120000}
ACTIVE_STALE_MS=${CLAUDE_MEM_ACTIVE_STALE_QUEUE_MS:-0}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --db)
      DB="$2"
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
    *)
      echo "unknown_arg=$1" >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$DB" ]; then
  echo "missing_db=$DB"
  exit 0
fi

if [ -z "$NOW_MS" ]; then
  NOW_MS="$(($(date +%s) * 1000))"
fi

CUTOFF_MS="$((NOW_MS - STALE_MS))"

has_pending=$(/usr/bin/sqlite3 "$DB" "select count(*) from sqlite_master where type='table' and name='pending_messages';")
has_sessions=$(/usr/bin/sqlite3 "$DB" "select count(*) from sqlite_master where type='table' and name='sdk_sessions';")
if [ "$has_pending" != "1" ] || [ "$has_sessions" != "1" ]; then
  echo "removed_stale_completed_session_queue=0"
  exit 0
fi

removed=$(/usr/bin/sqlite3 "$DB" "
select count(*)
from pending_messages pm
join sdk_sessions s on s.id = pm.session_db_id
where pm.status in ('pending', 'processing')
  and s.status = 'completed'
  and pm.created_at_epoch <= $CUTOFF_MS;
")

if [ "$removed" != "0" ]; then
  /usr/bin/sqlite3 "$DB" "
  delete from pending_messages
  where id in (
    select pm.id
    from pending_messages pm
    join sdk_sessions s on s.id = pm.session_db_id
    where pm.status in ('pending', 'processing')
      and s.status = 'completed'
      and pm.created_at_epoch <= $CUTOFF_MS
  );
  "
fi

echo "removed_stale_completed_session_queue=$removed"

active_removed=0
if [ "$ACTIVE_STALE_MS" -gt 0 ]; then
  ACTIVE_CUTOFF_MS="$((NOW_MS - ACTIVE_STALE_MS))"
  active_removed=$(/usr/bin/sqlite3 "$DB" "
  select count(*)
  from pending_messages pm
  join sdk_sessions s on s.id = pm.session_db_id
  where pm.status in ('pending', 'processing')
    and s.status = 'active'
    and pm.created_at_epoch <= $ACTIVE_CUTOFF_MS;
  ")

  if [ "$active_removed" != "0" ]; then
    /usr/bin/sqlite3 "$DB" "
    delete from pending_messages
    where id in (
      select pm.id
      from pending_messages pm
      join sdk_sessions s on s.id = pm.session_db_id
      where pm.status in ('pending', 'processing')
        and s.status = 'active'
        and pm.created_at_epoch <= $ACTIVE_CUTOFF_MS
    );
    "
  fi
fi

echo "removed_stale_active_session_queue=$active_removed"
