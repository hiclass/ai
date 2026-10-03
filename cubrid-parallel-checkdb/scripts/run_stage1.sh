#!/bin/bash
# Stage 1: N concurrent checkdb processes, each on a disjoint bucket of tables (no engine change needed).
# Buckets are balanced greedily by row count (largest tables first, each to the lightest bucket).
set -euo pipefail
. "$(dirname "$0")/env.sh"
N=${1:-1}
cd "$WORK"
rm -f bucket_*.txt
sort -k2 -n -r table_sizes.txt | python3 -c "
import sys
n=$N; buckets=[[0,[]] for _ in range(n)]
for line in sys.stdin:
    t,c=line.split(); b=min(buckets,key=lambda x:x[0]); b[0]+=int(c); b[1].append(t)
for i,(c,ts) in enumerate(buckets):
    open(f'bucket_{i}.txt','w').write('\n'.join(ts)+'\n')
"
# server-side parallelism off: this stage measures process-level parallelism only
csql -u dba "$DB" -c "SET SYSTEM PARAMETERS 'checkdb_worker_count=1'" >/dev/null
start=$(date +%s.%N)
pids=()
for f in bucket_*.txt; do
  cubrid checkdb -C -i "$f" "$DB" > "log_stage1_${f%.txt}.out" 2>&1 &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
end=$(date +%s.%N)
printf "stage1 procs=%d elapsed=%.2f rc=%d\n" "$N" "$(echo "$end - $start" | bc)" "$rc"
