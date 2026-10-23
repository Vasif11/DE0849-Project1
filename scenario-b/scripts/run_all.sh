#!/usr/bin/env bash
# Reproduce Scenario B: deploy -> verify -> observe -> measure -> diagnose -> analyse (~35 min).
# Run as root from the scenario-b directory:  sudo ./scripts/run_all.sh
source "$(dirname "$0")/lib.sh"
require_root
S="$REPO_DIR/scripts"

"$S/01_deploy.sh"            # 5GC + RAN + DN, subscriber, PDU session
"$S/02_verify.sh"            # Step 1 evidence             -> results/step1/
"$S/03_capture.sh"           # Step 2 registration + traffic -> captures/step2/, results/step2_logs/
"$S/05_experiments.sh" 3     # Step 3 N3 vs N6 conditions   -> results/raw/, captures/step3/
"$S/06_failure.sh"           # failure diagnosis F1-F3      -> results/failure/
"$S/07_timeline.sh"          # Prometheus/Grafana run       -> results/timeline/

cd "$REPO_DIR/analysis"
$PY step2_analysis.py
$PY parse_results.py
$PY analyze.py
$PY failure_analysis.py
$PY timeline.py
$PY grafana_snapshot.py || echo "(optional) Grafana snapshot skipped - playwright not installed"
