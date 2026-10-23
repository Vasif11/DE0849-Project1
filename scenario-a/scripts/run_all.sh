#!/usr/bin/env bash
# Reproduce the whole project: deploy -> verify -> observe -> measure -> diagnose -> analyse.
# Takes about 35 minutes. Run as root from the repository root:  sudo ./scripts/run_all.sh
source "$(dirname "$0")/lib.sh"
require_root
S="$REPO_DIR/scripts"

"$S/01_deploy.sh"                    # Step 1 deployment
"$S/02_verify.sh"                    # Step 1 evidence           -> results/step1/
"$S/03_capture.sh"                   # Step 2 packet captures    -> captures/step2/
"$S/05_experiments.sh" 3             # Step 3 measurements       -> results/raw/, captures/step3/
"$S/06_failure.sh"                   # failure diagnosis F1-F3   -> results/failure/
"$S/08_baseline_retrans_diagnosis.sh" # diagnosis F0              -> results/baseline_retrans/
"$S/07_timeline.sh"                  # Prometheus/Grafana run    -> results/timeline/

cd "$REPO_DIR/analysis"
$PY parse_results.py
$PY analyze.py
$PY step2_analysis.py
$PY failure_analysis.py
$PY timeline.py
$PY grafana_snapshot.py || echo "(optional) Grafana snapshot skipped - playwright not installed"
