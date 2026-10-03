#!/bin/bash
# Poor man's profiler: sample the stacks of every cub_server thread every INTERVAL seconds, COUNT times,
# and print the most frequent leaf frames and most frequent full stacks. Usage: sample_stacks.sh COUNT INTERVAL
. "$(dirname "$0")/env.sh"
COUNT=${1:-20}; INTERVAL=${2:-1}
PID=$(pgrep -f "cub_server $DB" | head -1)
OUT="$WORK/stacks_$(date +%s).txt"
for i in $(seq "$COUNT"); do
  gdb -p "$PID" -batch -ex "thread apply all bt 12" 2>/dev/null >> "$OUT"
  sleep "$INTERVAL"
done
echo "samples in $OUT"
# leaf frames of threads that are inside the check code
awk '/^Thread/{t=$0; st=""} /^#/{st=st" | "$0} /^$/{if (st ~ /checkdb|check_heap|btree_check|locator_check|chkreloc|verify/) print st}' "$OUT" \
  | sed 's/ 0x[0-9a-f]* in / /g' | sed 's/ (.*//' | awk -F' \\| ' '{print $2}' | sort | uniq -c | sort -rn | head -15
