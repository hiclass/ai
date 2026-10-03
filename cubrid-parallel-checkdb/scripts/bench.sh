#!/bin/bash
# Full benchmark: warm-up, then every configuration REPS times. Results appended to $WORK/results.txt
set -uo pipefail
. "$(dirname "$0")/env.sh"
REPS=${REPS:-2}
S="$(dirname "$0")"
cd "$WORK"
echo "=== $(date) nproc=$(nproc) ===" >> results.txt
"$S/run_stage2.sh" 1 tables > /dev/null        # warm-up (page cache)
for r in $(seq "$REPS"); do
  for n in 1 2 4 8; do "$S/run_stage1.sh" "$n" | tee -a results.txt; done
  for n in 1 2 4 8; do "$S/run_stage2.sh" "$n" tables | tee -a results.txt; done
  for n in 1 2 4 8; do "$S/run_stage2.sh" "$n" db     | tee -a results.txt; done
  for n in 1 4;     do "$S/run_stage2.sh" "$n" backup | tee -a results.txt; done
done
