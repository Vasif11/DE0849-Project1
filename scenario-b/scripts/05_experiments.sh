#!/usr/bin/env bash
# Step 3 - Run every condition in sequence: baseline, and the same impairments on N3 vs N6.
#   05_experiments.sh [repetitions]          ONLY="C0_baseline C3_loss1_n3" 05_experiments.sh
source "$(dirname "$0")/lib.sh"
require_root
REPS=${1:-3}

# name | segment | tc qdisc spec   (segment "none" = no impairment)
CONDITIONS=(
  "C0_baseline|none|"
  "C1_delay50_n3|n3|netem delay 25ms"
  "C2_delay50_n6|n6|netem delay 25ms"
  "C3_loss1_n3|n3|netem loss 1%"
  "C4_loss1_n6|n6|netem loss 1%"
  "C5_rate20_n3|n3|tbf rate 20mbit burst 32kb latency 50ms"
)

{
  echo "condition,link,spec"
  for c in "${CONDITIONS[@]}"; do echo "$c" | tr '|' ','; done
} > "$RESULTS_DIR/conditions.csv"

for c in "${CONDITIONS[@]}"; do
  IFS='|' read -r name seg spec <<< "$c"
  if [[ -n "${ONLY:-}" && " $ONLY " != *" $name "* ]]; then continue; fi
  log "===== $name : $seg $spec ====="
  "$REPO_DIR/scripts/impair.sh" clear
  if [[ $seg != none ]]; then "$REPO_DIR/scripts/impair.sh" apply "$seg" $spec; fi
  sleep 2
  "$REPO_DIR/scripts/04_measure.sh" "$name" "$REPS"
done
"$REPO_DIR/scripts/impair.sh" clear
log "All experiments finished."
