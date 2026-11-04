#!/usr/bin/env bash
# Rebuilds a scratch local database from the migrations and runs the SQL tests.
# Needs a local Postgres; set PGHOST/PGPORT/PGUSER as needed.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TEST_DB:-wf_test}
dropdb --if-exists "$DB" && createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f tests/supabase_stub.sql 2>&1 | grep -v -i "wal_level\|HINT" || true
for f in migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"; done
psql -q -t -A -v ON_ERROR_STOP=1 -d "$DB" -f tests/policies_and_rules.sql 2>&1 | grep -E 'ok - |FAILED|ERROR' | sed 's/^psql:[^ ]* //'
