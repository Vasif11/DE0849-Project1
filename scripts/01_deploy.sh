#!/usr/bin/env bash
# Step 1 - Deploy the hybrid Linux-namespace + Docker network of Scenario A.
#
#   UE (ns ue) -> Access Router (ns access) -> Core/Gateway (ns core)
#      -> Data Network / host integration (root ns) -> Docker bridge br-dn
#      -> Nginx 10.0.4.10:8080  and  iperf3 10.0.4.20:5201
#
# Idempotent: tears down an existing deployment first.
source "$(dirname "$0")/lib.sh"
require_root

log "Cleaning previous deployment (if any)"
"$REPO_DIR/scripts/99_teardown.sh" --keep-containers >/dev/null 2>&1 || true

log "Loading kernel modules (veth, netem, tbf)"
modprobe sch_netem; modprobe sch_tbf; modprobe br_netfilter || true

# ------------------------------------------------------------------
log "1/5 Docker services (Nginx, iperf3, Prometheus, Grafana)"
docker compose -f "$COMPOSE_FILE" up -d --build
docker compose -f "$COMPOSE_FILE" ps

# ------------------------------------------------------------------
log "2/5 Network namespaces"
for ns in $NS_UE $NS_ACC $NS_CORE; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done

log "3/5 veth pairs and IP addressing"
ip link add ue-eth0  netns $NS_UE   type veth peer name acc-ue    netns $NS_ACC
ip link add acc-core netns $NS_ACC  type veth peer name core-acc  netns $NS_CORE
ip link add core-dn  netns $NS_CORE type veth peer name host-core   # host-core stays in the root ns

ip -n $NS_UE   addr add $UE_IP/24       dev ue-eth0
ip -n $NS_ACC  addr add $ACC_UE_IP/24   dev acc-ue
ip -n $NS_ACC  addr add $ACC_CORE_IP/24 dev acc-core
ip -n $NS_CORE addr add $CORE_ACC_IP/24 dev core-acc
ip -n $NS_CORE addr add $CORE_DN_IP/24  dev core-dn
ip addr add $HOST_DN_IP/24 dev host-core

for pair in "$NS_UE ue-eth0" "$NS_ACC acc-ue" "$NS_ACC acc-core" "$NS_CORE core-acc" "$NS_CORE core-dn"; do
  set -- $pair; ip -n "$1" link set "$2" up
done
ip link set host-core up

log "4/5 Routing and IP forwarding"
# UE: everything goes to the access router
ip -n $NS_UE route add default via $ACC_UE_IP
# Access router: data-network side prefixes are behind the core gateway
ip -n $NS_ACC route add 10.0.3.0/24 via $CORE_ACC_IP
ip -n $NS_ACC route add $DN_SUBNET  via $CORE_ACC_IP
# Core/gateway: UE prefix behind access, Docker data network behind the host
ip -n $NS_CORE route add 10.0.1.0/24 via $ACC_CORE_IP
ip -n $NS_CORE route add $DN_SUBNET  via $HOST_DN_IP
# Host (integration boundary): return path to UE/access prefixes via core
ip route add 10.0.1.0/24 via $CORE_DN_IP
ip route add 10.0.2.0/24 via $CORE_DN_IP

ip netns exec $NS_UE   sysctl -qw net.ipv4.ip_forward=0   # UE is an end host, not a router
ip netns exec $NS_ACC  sysctl -qw net.ipv4.ip_forward=1
ip netns exec $NS_CORE sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.ip_forward=1
# veth delivers every packet through the per-CPU input backlog; at ~270 kpps (offloads off)
# the default of 1000 packets overflowed during bursts (veth rx_dropped / softnet drops).
sysctl -qw net.core.netdev_max_backlog=10000

# Docker drops forwarded traffic into its bridges by default (FORWARD policy DROP).
# Allow routed (non-NAT) traffic between the namespace network and the data network.
for rule in "-i host-core -o $DN_BRIDGE -j ACCEPT" "-i $DN_BRIDGE -o host-core -j ACCEPT"; do
  iptables -C DOCKER-USER $rule 2>/dev/null || iptables -I DOCKER-USER $rule
done

# ------------------------------------------------------------------
log "5/5 Disable segmentation offloads (TSO/GSO/GRO) on the measured path"
# Without this, veth/containers hand 64 KB "super-packets" to tc/netem, so a single
# netem "loss" event would drop ~44 MTU-sized segments and captures would show
# non-wire-sized frames. Turning offloads off makes every skb a real 1500-byte packet.
OFF="tso off gso off gro off"
ip netns exec $NS_UE   ethtool -K ue-eth0  $OFF >/dev/null 2>&1 || true
ip netns exec $NS_ACC  ethtool -K acc-ue   $OFF >/dev/null 2>&1 || true
ip netns exec $NS_ACC  ethtool -K acc-core $OFF >/dev/null 2>&1 || true
ip netns exec $NS_CORE ethtool -K core-acc $OFF >/dev/null 2>&1 || true
ip netns exec $NS_CORE ethtool -K core-dn  $OFF >/dev/null 2>&1 || true
ethtool -K host-core $OFF >/dev/null 2>&1 || true
for c in $APP_CONTAINER $IPERF_CONTAINER; do
  nsenter -t "$(container_pid $c)" -n ethtool -K eth0 $OFF >/dev/null 2>&1 || true
done
for v in $(ip -o link show master $DN_BRIDGE | awk -F': ' '{print $2}' | cut -d@ -f1); do
  ethtool -K "$v" $OFF >/dev/null 2>&1 || true
done

log "Deployment complete. Quick check:"
ue ping -c 2 -W 1 $APP_IP | tail -2
ue curl -s -o /dev/null -w 'HTTP %{http_code} from %{remote_ip}:%{remote_port} in %{time_total}s\n' http://$APP_IP:$APP_PORT/
