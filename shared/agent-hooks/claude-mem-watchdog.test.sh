#!/usr/bin/env bash
set -euo pipefail

SCRIPT=/Users/antonsahovskii/.local/share/agent-hooks/claude-mem-watchdog.sh
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-mem-watchdog-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

DB="$TMP_ROOT/claude-mem.db"
NOW=2000000

/usr/bin/sqlite3 "$DB" "
create table sdk_sessions (id integer primary key, status text not null);
create table pending_messages (
  id integer primary key,
  session_db_id integer not null,
  status text not null,
  created_at_epoch integer not null,
  message_type text,
  content_session_id text
);
insert into sdk_sessions (id, status) values (1, 'completed'), (2, 'active');
insert into pending_messages (id, session_db_id, status, created_at_epoch, message_type, content_session_id)
values
  (10, 1, 'pending', 500000, 'summary', 'completed-old'),
  (20, 2, 'pending', 500000, 'summary', 'active-old');
"

OUT="$TMP_ROOT/watchdog.out"
"$SCRIPT" --db "$DB" --no-api --state-dir "$TMP_ROOT/state-1" --now-ms "$NOW" --stale-ms 1000 --age-threshold-ms 900000 >"$OUT"

grep -q '^api_status=not_checked$' "$OUT"
grep -q '^pending_messages=2$' "$OUT"
grep -q '^oldest_pending_age_ms=1500000$' "$OUT"
grep -q '^watchdog_action=maintenance$' "$OUT"
grep -q '^removed_stale_completed_session_queue=1$' "$OUT"
grep -q '^removed_stale_active_session_queue=0$' "$OUT"

remaining_completed=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where session_db_id = 1;")
remaining_active=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where session_db_id = 2;")
test "$remaining_completed" = "0"
test "$remaining_active" = "1"

DB2="$TMP_ROOT/claude-mem-active.db"
cp "$DB" "$DB2"
"$SCRIPT" --db "$DB2" --no-api --state-dir "$TMP_ROOT/state-2" --now-ms "$NOW" --stale-ms 1000 --active-stale-ms 1000 --age-threshold-ms 900000 >"$TMP_ROOT/watchdog-active.out"
grep -q '^removed_stale_active_session_queue=1$' "$TMP_ROOT/watchdog-active.out"

DB3="$TMP_ROOT/claude-mem-fresh.db"
/usr/bin/sqlite3 "$DB3" "
create table sdk_sessions (id integer primary key, status text not null);
create table pending_messages (
  id integer primary key,
  session_db_id integer not null,
  status text not null,
  created_at_epoch integer not null,
  message_type text,
  content_session_id text
);
insert into sdk_sessions (id, status) values (1, 'completed');
insert into pending_messages (id, session_db_id, status, created_at_epoch, message_type, content_session_id)
values (10, 1, 'pending', 1999500, 'summary', 'fresh');
"
"$SCRIPT" --db "$DB3" --no-api --state-dir "$TMP_ROOT/state-3" --now-ms "$NOW" --stale-ms 100 --age-threshold-ms 900000 >"$TMP_ROOT/watchdog-fresh.out"
grep -q '^watchdog_action=none$' "$TMP_ROOT/watchdog-fresh.out"
remaining_fresh=$(/usr/bin/sqlite3 "$DB3" "select count(*) from pending_messages;")
test "$remaining_fresh" = "1"

STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"
printf '{"first_seen_ms":0}\n' >"$STATE_DIR/queue.json"
"$SCRIPT" --db "$DB3" --no-api --state-dir "$STATE_DIR" --now-ms "$NOW" --stale-ms 100 --age-threshold-ms 900000 >"$TMP_ROOT/watchdog-bad-state.out"
grep -q '^queue_observed_for_ms=0$' "$TMP_ROOT/watchdog-bad-state.out"
grep -q '^watchdog_action=none$' "$TMP_ROOT/watchdog-bad-state.out"

STALE_STATE_DIR="$TMP_ROOT/stale-state"
mkdir -p "$STALE_STATE_DIR"
printf '{"first_seen_ms":1000}\n' >"$STALE_STATE_DIR/queue.json"
"$SCRIPT" --db "$DB3" --no-api --state-dir "$STALE_STATE_DIR" --now-ms "$NOW" --stale-ms 100 --age-threshold-ms 900000 --max-track-ms 1000 >"$TMP_ROOT/watchdog-stale-state.out"
grep -q '^queue_observed_for_ms=0$' "$TMP_ROOT/watchdog-stale-state.out"
grep -q '^watchdog_action=none$' "$TMP_ROOT/watchdog-stale-state.out"

echo "claude-mem-watchdog.test.sh passed"
