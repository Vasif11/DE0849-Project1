#!/usr/bin/env bash
# Observability timeline - one long TCP flow from the UE while the network condition changes
# every phase. Prometheus (1 s scrape of the exporter) records the whole run; Grafana shows it;
# analysis/timeline.py exports the Prometheus series to CSV and plots them.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/timeline"
mkdir -p "$OUT"; rm -f "$OUT"/*
IMP="$REPO_DIR/scripts/impair.sh"

# start the exporter if it is not running
if ! pgrep -f scenario_exporter.py >/dev/null; then
  setsid nohup "$PY" "$REPO_DIR/exporter/scenario_exporter.py" --port $EXPORTER_PORT \
    > /tmp/scena-exporter.log 2>&1 < /dev/null &
  sleep 3
fi
curl -s "http://127.0.0.1:$EXPORTER_PORT/metrics" | grep -c '^scena_' | xargs echo "exporter series:"

# name | duration [s] | link | spec
PHASES=(
  "baseline|60|none|"
  "delay+50ms|60|access-core|netem delay 25ms"
  "recovery-1|40|none|"
  "loss-1%|60|access-core|netem loss 1%"
  "recovery-2|40|none|"
  "rate-20Mbit|60|access-core|tbf rate 20mbit burst 32kb latency 50ms"
  "recovery-3|40|none|"
  "delay+50ms+loss-1%|60|access-core|netem delay 25ms loss 1%"
  "recovery-4|50|none|"
)
TOTAL=0; for p in "${PHASES[@]}"; do IFS='|' read -r _ d _ _ <<< "$p"; TOTAL=$((TOTAL + d)); done

$IMP clear >/dev/null
log "Starting background TCP flow UE -> iperf3 for $((TOTAL + 10)) s"
ip netns exec $NS_UE iperf3 -c $IPERF_IP -t $((TOTAL + 10)) -i 1 --forceflush > "$OUT/iperf3_tcp_interval.txt" 2>&1 &
IPERF=$!
sleep 5

echo "phase,start_epoch,end_epoch,link,spec" > "$OUT/phases.csv"
for p in "${PHASES[@]}"; do
  IFS='|' read -r name dur link spec <<< "$p"
  $IMP clear >/dev/null
  [[ $link != none ]] && $IMP apply "$link" $spec >/dev/null
  start=$(date +%s.%N)
  log "phase $name ($dur s) $link $spec"
  sleep "$dur"
  echo "$name,$start,$(date +%s.%N),$link,$spec" >> "$OUT/phases.csv"
done
$IMP clear >/dev/null
wait $IPERF || true
log "Timeline finished - phases in $OUT/phases.csv"
