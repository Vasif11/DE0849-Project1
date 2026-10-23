#!/usr/bin/env bash
# Install everything needed on a fresh Ubuntu (22.04+ / 24.04 / 26.04, VM or WSL2).
source "$(dirname "$0")/lib.sh"
require_root

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 iproute2 iputils-ping iputils-tracepath traceroute \
  iperf3 tcpdump tshark ethtool curl jq netcat-openbsd python3-venv iptables

systemctl enable --now docker

docker pull nginx:1.27-alpine
docker pull networkstatic/iperf3:latest
docker pull prom/prometheus:v2.53.2
docker pull grafana/grafana:11.2.0

# Python environment for the exporter and the data analysis
python3 -m venv /opt/p1venv
/opt/p1venv/bin/pip install -r "$REPO_DIR/requirements.txt"

echo "Install finished."
