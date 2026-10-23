#!/usr/bin/env bash
# Step 1 - Deploy the 5G SA network: MongoDB + subscriber, Open5GS 5GC, UPF, UERANSIM gNB/UE,
# N6 services, Prometheus/Grafana. Then set the user-plane routes and wait for the PDU session.
source "$(dirname "$0")/lib.sh"
require_root

log "Kernel modules (SCTP for NGAP, TUN, netem/tbf)"
modprobe sctp; modprobe tun; modprobe sch_netem; modprobe sch_tbf
sysctl -qw net.core.netdev_max_backlog=10000

log "1/4 Subscriber database"
$DC up -d mongodb
for _ in $(seq 1 60); do
  docker exec $C_MONGO mongosh --quiet --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null | grep -q 1 && break
  sleep 1
done
docker exec $C_MONGO mongosh --quiet mongodb://localhost/open5gs /scripts/add_subscriber.js

log "2/4 5G core, RAN, data network and observability containers"
$DC up -d --build
$DC ps --format 'table {{.Name}}\t{{.Status}}'

log "3/4 Waiting for UE registration and PDU session"
wait_pdu 120
echo "UE PDU session address: $(ue_ip) on $UE_TUN"

log "4/4 User-plane routes and offloads"
setup_routes
disable_offloads

log "Quick check over the 5G user plane"
ue ping -c 3 -W 2 $NGINX_IP | tail -2
ue curl -s -o /dev/null -w 'HTTP %{http_code} from %{remote_ip}:%{remote_port} (local %{local_ip}) in %{time_total}s\n' http://$NGINX_IP/
