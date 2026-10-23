#!/usr/bin/env bash
# Observability timeline - one long TCP upload from the UE over the PDU session while the condition
# changes on N3 and N6. Prometheus records Open5GS NF metrics + the exporter; Grafana shows the run.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/timeline"; mkdir -p "$OUT"; rm -f "$OUT"/*
IMP="$REPO_DIR/scripts/impair.sh"

if ! pgrep -f "scenario_b_exporte[r]" >/dev/null; then
  setsid nohup "$PY" "$REPO_DIR/exporter/scenario_b_exporter.py" --port $EXPORTER_PORT \
    > /tmp/scenb-exporter.log 2>&1 < /dev/null &
  sleep 4
fi
curl -s "http://127.0.0.1:$EXPORTER_PORT/metrics" | grep -c '^scenb_' | xargs echo "exporter series:"

# name | duration [s] | segment | spec
PHASES=(
  "baseline|45|none|"
  "N3 +50ms|60|n3|netem delay 25ms"
  "recovery-1|35|none|"
  "N6 +50ms|60|n6|netem delay 25ms"
  "recovery-2|35|none|"
  "N3 loss 1%|60|n3|netem loss 1%"
  "recovery-3|35|none|"
  "N6 loss 1%|60|n6|netem loss 1%"
  "recovery-4|35|none|"
  "N3 20Mbit|60|n3|tbf rate 20mbit burst 32kb latency 50ms"
  "recovery-5|45|none|"
)
TOTAL=0; for p in "${PHASES[@]}"; do IFS='|' read -r _ d _ _ <<< "$p"; TOTAL=$((TOTAL + d)); done

$IMP clear >/dev/null
log "Background TCP upload UE -> iperf3 over the 5G user plane for $((TOTAL + 10)) s"
nsenter -t "$(cpid $C_UE)" -n iperf3 -c $IPERF_IP -t $((TOTAL + 10)) -i 1 --forceflush > "$OUT/iperf3_tcp_interval.txt" 2>&1 &
IPERF=$!
sleep 5
echo "phase,start_epoch,end_epoch,link,spec" > "$OUT/phases.csv"
for p in "${PHASES[@]}"; do
  IFS='|' read -r name dur seg spec <<< "$p"
  $IMP clear >/dev/null
  [[ $seg != none ]] && $IMP apply "$seg" $spec >/dev/null
  start=$(date +%s.%N)
  log "phase $name ($dur s) $seg $spec"
  sleep "$dur"
  echo "$name,$start,$(date +%s.%N),$seg,$spec" >> "$OUT/phases.csv"
done
$IMP clear >/dev/null
wait $IPERF || true
log "Timeline finished"
