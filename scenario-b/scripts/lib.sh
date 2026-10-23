#!/usr/bin/env bash
# Common configuration for Scenario B - 5G SA (Open5GS + UERANSIM). Sourced by every script.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="$REPO_DIR/results"
CAPTURE_DIR="$REPO_DIR/captures"
COMPOSE_FILE="$REPO_DIR/deploy/docker-compose.yml"
DC="docker compose -f $COMPOSE_FILE"

# ---- Docker networks (Linux bridge names on the host) ----
#  ran-net 10.20.1.0/24 br-ran : UE <-> gNB simulated radio (UERANSIM RLS, UDP 4997)
#  n2-net  10.20.2.0/24 br-n2  : gNB <-> AMF  NGAP / SCTP 38412
#  n3-net  10.20.3.0/24 br-n3  : gNB <-> UPF  GTP-U / UDP 2152
#  sbi-net 10.20.4.0/24 br-sbi : 5GC service-based interface (HTTP/2, port 7777) + MongoDB
#  n4-net  10.20.5.0/24 br-n4  : SMF <-> UPF  PFCP / UDP 8805
#  dn-net  10.20.6.0/24 br-n6  : UPF <-> data network (Nginx, iperf3)
#  obs-net 10.20.7.0/24 br-obs7: Prometheus / Grafana (observability only)
UE_RAN_IP=10.20.1.20
GNB_RAN_IP=10.20.1.10
GNB_N2_IP=10.20.2.10
AMF_N2_IP=10.20.2.12
GNB_N3_IP=10.20.3.10
UPF_N3_IP=10.20.3.14
SMF_N4_IP=10.20.5.13
UPF_N4_IP=10.20.5.14
UPF_N6_IP=10.20.6.14
NGINX_IP=10.20.6.20
NGINX_PORT=80
IPERF_IP=10.20.6.21
IPERF_PORT=5201
UE_POOL=10.45.0.0/16
DN_SUBNET=10.20.6.0/24
OBS_GW=10.20.7.1
EXPORTER_PORT=9102

IMSI=001010000000001
UE_TUN=uesimtun0

C_UE=scenario-b-ue
C_GNB=scenario-b-gnb
C_AMF=scenario-b-amf
C_SMF=scenario-b-smf
C_UPF=scenario-b-upf
C_NGINX=scenario-b-nginx
C_IPERF=scenario-b-iperf3
C_MONGO=scenario-b-mongodb

PY=${PY:-/opt/p1venv/bin/python}

require_root() {
  if [[ $EUID -ne 0 ]]; then echo "This script must be run as root (sudo)." >&2; exit 1; fi
}
log() { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%T)" "$*"; }
run_logged() {   # run_logged <file> <cmd...> : print + save command and output (evidence)
  local out=$1; shift
  { echo "\$ $*"; "$@" 2>&1 || true; echo; } | tee -a "$out"
}

cpid() { docker inspect -f '{{.State.Pid}}' "$1"; }
# run a host binary inside the network namespace of a container (no tools needed in the image)
cns() { local c=$1; shift; nsenter -t "$(cpid "$c")" -n "$@"; }
# interface name of a container that carries the given IPv4 address
ifname_of() { cns "$1" ip -o -4 addr show | awk -v ip="$2" '$4 ~ "^"ip"/" {print $2; exit}'; }
# host-side veth peer of a container interface (for impairing the direction towards the container)
host_peer_of() {
  # inside the container "eth1@if123" -> 123 is the ifindex of the peer in the root namespace
  local idx; idx=$(cns "$1" ip -o link show dev "$2" | sed -n 's/^[0-9]*: [^@]*@if\([0-9]*\):.*/\1/p')
  ip -o link | awk -F': ' -v i="$idx" '$1 == i {split($2, a, "@"); print a[1]; exit}'
}
# commands executed by the UE "application" - inside the UE container, bound to the PDU session
ue() { cns "$C_UE" "$@"; }
ue_ip() { ue ip -o -4 addr show dev "$UE_TUN" 2>/dev/null | awk '{split($4, a, "/"); print a[1]}'; }

wait_pdu() {   # wait until the UE has a PDU session (uesimtun0 with an address)
  local t=${1:-90}
  for _ in $(seq 1 "$t"); do
    [[ -n "$(ue_ip 2>/dev/null)" ]] && return 0
    sleep 1
  done
  echo "no PDU session after ${t}s" >&2; return 1
}

setup_routes() {
  # UE: the data network is reached through the PDU session (uesimtun0), never through the
  # container's own Docker interface - otherwise the test would bypass the 5G user plane.
  ue ip route replace "$DN_SUBNET" dev "$UE_TUN"
  # DN services: return path to the UE pool via the UPF N6 address (no NAT anywhere)
  for c in $C_NGINX $C_IPERF; do cns "$c" ip route replace "$UE_POOL" via "$UPF_N6_IP"; done
}

disable_offloads() {
  # every skb = one wire-size packet (see Scenario A §2.3): needed for meaningful netem/tbf
  local OFF="tso off gso off gro off" c ip ifc
  for pair in "$C_NGINX $NGINX_IP" "$C_IPERF $IPERF_IP" "$C_UPF $UPF_N6_IP" "$C_UPF $UPF_N3_IP" "$C_GNB $GNB_N3_IP"; do
    read -r c ip <<< "$pair"
    ifc=$(ifname_of "$c" "$ip")
    cns "$c" ethtool -K "$ifc" $OFF >/dev/null 2>&1 || true
    ethtool -K "$(host_peer_of "$c" "$ifc")" $OFF >/dev/null 2>&1 || true
  done
}
