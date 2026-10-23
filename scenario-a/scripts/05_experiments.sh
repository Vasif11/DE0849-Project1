#!/usr/bin/env bash
# Step 3 - Run every experimental condition (baseline + degraded) in sequence.
#   05_experiments.sh [repetitions]     (default 3)
#   ONLY="C0_baseline C2_loss1" 05_experiments.sh   -> run a subset
source "$(dirname "$0")/lib.sh"
require_root
REPS=${1:-3}

# name | link | tc qdisc spec   (link "none" = no impairment)
CONDITIONS=(
  "C0_baseline|none|"
  "C1_delay50|access-core|netem delay 25ms"
  "C2_loss1|access-core|netem loss 1%"
  "C3_rate20|access-core|tbf rate 20mbit burst 32kb latency 50ms"
  "C4_delay50_loss1|access-core|netem delay 25ms loss 1%"
  "C5_delay50_dn|core-dn|netem delay 25ms"
  "C6_loss1_dn|core-dn|netem loss 1%"
)

{
  echo "condition,link,spec"
  for c in "${CONDITIONS[@]}"; do echo "$c" | tr '|' ','; done
} > "$RESULTS_DIR/conditions.csv"

for c in "${CONDITIONS[@]}"; do
  IFS='|' read -r name link spec <<< "$c"
  if [[ -n "${ONLY:-}" && " $ONLY " != *" $name "* ]]; then continue; fi
  log "===== $name : $link $spec ====="
  "$REPO_DIR/scripts/impair.sh" clear
  if [[ $link != none ]]; then "$REPO_DIR/scripts/impair.sh" apply "$link" $spec; fi
  sleep 2
  "$REPO_DIR/scripts/04_measure.sh" "$name" "$REPS"
done
"$REPO_DIR/scripts/impair.sh" clear
log "All experiments finished."
