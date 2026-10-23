#!/usr/bin/env bash
# Common configuration for Scenario A (sourced by every script).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$REPO_DIR/results"
CAPTURE_DIR="$REPO_DIR/captures"
COMPOSE_FILE="$REPO_DIR/deploy/docker-compose.yml"

# ---- Linux network namespaces (UE, Access Router, Core/Gateway) ----
NS_UE=ue
NS_ACC=access
NS_CORE=core

# ---- veth links ----
#  ue-eth0  (ue)     <-> acc-ue    (access)   10.0.1.0/24  "access network"
#  acc-core (access) <-> core-acc  (core)     10.0.2.0/24  "access-core backhaul"
#  core-dn  (core)   <-> host-core (host)     10.0.3.0/24  "data network / host integration"
UE_IP=10.0.1.10
ACC_UE_IP=10.0.1.1
ACC_CORE_IP=10.0.2.1
CORE_ACC_IP=10.0.2.2
CORE_DN_IP=10.0.3.1
HOST_DN_IP=10.0.3.2

# ---- Docker user-defined bridge networks ----
DN_SUBNET=10.0.4.0/24      # data network (application + performance services)
DN_GW=10.0.4.1
DN_BRIDGE=br-dn
OBS_SUBNET=10.0.5.0/24     # observability network (Prometheus, Grafana) - not in the traffic path
OBS_GW=10.0.5.1
APP_IP=10.0.4.10
APP_PORT=8080
IPERF_IP=10.0.4.20
IPERF_PORT=5201
EXPORTER_PORT=9101

APP_CONTAINER=scena-nginx
IPERF_CONTAINER=scena-iperf3

PY=${PY:-/opt/p1venv/bin/python}

ue()   { ip netns exec "$NS_UE" "$@"; }
acc()  { ip netns exec "$NS_ACC" "$@"; }
core() { ip netns exec "$NS_CORE" "$@"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then echo "This script must be run as root (sudo)." >&2; exit 1; fi
}

log() { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%T)" "$*"; }

# Run a command, print it with a prompt and save both to a file (evidence log).
run_logged() {
  local out=$1; shift
  { echo "\$ $*"; "$@" 2>&1 || true; echo; } | tee -a "$out"
}

container_pid() { docker inspect -f '{{.State.Pid}}' "$1"; }
