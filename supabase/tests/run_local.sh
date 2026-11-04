#!/usr/bin/env bash
# Rebuilds a scratch local database from the migrations and runs the SQL tests.
# Needs a local Postgres; set PGHOST/PGPORT/PGUSER as needed.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TEST_DB:-wf_test}
dropdb --if-exists "$DB" && createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f tests/supabase_stub.sql 2>&1 | grep -v -i "wal_level\|HINT" || true
for f in migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"; done
# Every test file except the platform stub. Each one rolls back what it creates.
for t in tests/*.sql; do
  [ "$(basename "$t")" = supabase_stub.sql ] && continue
  psql -q -t -A -v ON_ERROR_STOP=1 -d "$DB" -f "$t" 2>&1 | grep -E 'ok - |FAILED|ERROR' | sed 's/^psql:[^ ]* //'
done
