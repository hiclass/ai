#!/bin/bash
# Create the benchmark database, bulk load it, start the server.
set -euo pipefail
. "$(dirname "$0")/env.sh"
SCALE=${1:-1.0}
cd "$WORK"
python3 "$(dirname "$0")/gen_data.py" "$WORK" "$SCALE"
cubrid server stop "$DB" >/dev/null 2>&1 || true
cubrid deletedb "$DB" >/dev/null 2>&1 || true
mkdir -p "$WORK/db" && cd "$WORK/db"
cubrid createdb --db-volume-size=4G --log-volume-size=512M "$DB" en_US.utf8
cubrid loaddb -u dba -s "$WORK/schema.sql" -d "$WORK/data.txt" -i "$WORK/index.sql" --no-statistics "$DB"
cubrid server start "$DB"
csql -u dba "$DB" -c "SELECT COUNT(*) FROM t01;"
