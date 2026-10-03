#!/bin/bash
# Stage 2: one checkdb / backupdb request, server-side workers = N (checkdb_worker_count).
#   mode "tables"  : cubrid checkdb -C -i tables.txt   (per-table path, xboot_checkdb_table)
#   mode "db"      : cubrid checkdb -C                 (whole-database path, same as backupdb's pre-check)
#   mode "backup"  : cubrid backupdb -C -z             (backup with its built-in consistency check)
#   mode "bkflags" : checkdb with exactly backupdb's check flags (heap, b-tree, catalog, tracker, class names)
#   mode "xcheck"  : checkdb --check-btree-entries only (heap/b-tree cross check)
set -uo pipefail
. "$(dirname "$0")/env.sh"
N=${1:-1}; MODE=${2:-tables}
cd "$WORK"
csql -u dba "$DB" -c "SET SYSTEM PARAMETERS 'checkdb_worker_count=$N'" >/dev/null
start=$(date +%s.%N)
case "$MODE" in
  tables) cubrid checkdb -C -i tables.txt "$DB" > "log_stage2_${MODE}_$N.out" 2>&1; rc=$? ;;
  db)     cubrid checkdb -C "$DB" > "log_stage2_${MODE}_$N.out" 2>&1; rc=$? ;;
  # exactly the flag set backupdb uses for its pre-check (no heap/b-tree cross check)
  bkflags) cubrid checkdb -C --check-file-tracker --check-heap --check-catalog --check-btree --check-class-name "$DB" > "log_stage2_${MODE}_$N.out" 2>&1; rc=$? ;;
  # the cross check alone
  xcheck) cubrid checkdb -C --check-btree-entries "$DB" > "log_stage2_${MODE}_$N.out" 2>&1; rc=$? ;;
  backup) rm -rf "$WORK/bk" && mkdir -p "$WORK/bk" && cubrid backupdb -C -D "$WORK/bk" -z "$DB" > "log_stage2_${MODE}_$N.out" 2>&1; rc=$? ;;
esac
end=$(date +%s.%N)
printf "stage2 mode=%s workers=%d elapsed=%.2f rc=%d\n" "$MODE" "$N" "$(echo "$end - $start" | bc)" "$rc"
