#!/usr/bin/env bash
set -euo pipefail

SCRIPT=/Users/antonsahovskii/.local/share/agent-hooks/claude-mem-db-maintenance.sh
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-mem-db-maintenance.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT
DB="$TMPDIR/test.db"

/usr/bin/sqlite3 "$DB" "
create table sdk_sessions (
  id integer primary key,
  status text not null,
  completed_at_epoch integer
);
create table pending_messages (
  id integer primary key,
  session_db_id integer not null,
  status text not null,
  created_at_epoch integer not null,
  failed_at_epoch integer,
  completed_at_epoch integer
);
insert into sdk_sessions(id, status, completed_at_epoch) values
  (1, 'completed', 700000),
  (2, 'active', null),
  (3, 'completed', 950000);
insert into pending_messages(id, session_db_id, status, created_at_epoch) values
  (10, 1, 'pending', 700000),
  (11, 1, 'processing', 700100),
  (20, 2, 'pending', 700000),
  (30, 3, 'pending', 970000);
"

"$SCRIPT" --db "$DB" --now-ms 1000000 --stale-ms 120000 >/tmp/claude-mem-db-maintenance-test.out

remaining_old=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where id in (10,11);")
active_kept=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where id=20;")
recent_kept=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where id=30;")

test "$remaining_old" = "0"
test "$active_kept" = "1"
test "$recent_kept" = "1"
rg -q 'removed_stale_completed_session_queue=2' /tmp/claude-mem-db-maintenance-test.out
rg -q 'removed_stale_active_session_queue=0' /tmp/claude-mem-db-maintenance-test.out

"$SCRIPT" --db "$DB" --now-ms 1000000 --stale-ms 120000 --active-stale-ms 120000 >/tmp/claude-mem-db-maintenance-test-active.out

active_removed=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where id=20;")
recent_still_kept=$(/usr/bin/sqlite3 "$DB" "select count(*) from pending_messages where id=30;")

test "$active_removed" = "0"
test "$recent_still_kept" = "1"
rg -q 'removed_stale_active_session_queue=1' /tmp/claude-mem-db-maintenance-test-active.out

echo "claude-mem-db-maintenance.test.sh passed"
