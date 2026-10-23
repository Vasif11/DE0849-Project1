#!/usr/bin/env bash
# Install everything needed for Scenario B on Ubuntu 22.04+ (VM or WSL2).
source "$(dirname "$0")/lib.sh"
require_root

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 iproute2 iputils-ping traceroute iperf3 tcpdump tshark \
  ethtool curl jq python3-venv
systemctl enable --now docker
modprobe sctp; modprobe tun

for i in gradiant/open5gs:2.8.0 gradiant/ueransim:3.3.0 mongo:7.0 nginx:1.27-alpine \
         networkstatic/iperf3:latest prom/prometheus:v2.53.2 grafana/grafana:11.2.0; do
  docker pull "$i"
done

python3 -m venv /opt/p1venv
/opt/p1venv/bin/pip install -r "$REPO_DIR/requirements.txt"
echo "Install finished."
