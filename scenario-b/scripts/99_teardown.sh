#!/usr/bin/env bash
# Remove the Scenario B deployment (containers, networks; volumes are kept unless -v is given).
source "$(dirname "$0")/lib.sh"
require_root
for p in $(pgrep -f "scenario_b_exporte[r]"); do kill "$p"; done
$DC down "$@"
echo "Teardown done."
