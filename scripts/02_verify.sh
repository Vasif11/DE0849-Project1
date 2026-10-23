#!/usr/bin/env bash
# Step 1 - Verify the deployment layer by layer and save the evidence to results/step1/.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/step1"
mkdir -p "$OUT"
rm -f "$OUT"/*.txt

log "Environment"
E="$OUT/00_environment.txt"
run_logged "$E" uname -a
run_logged "$E" bash -c 'grep PRETTY_NAME /etc/os-release'
run_logged "$E" docker version --format 'Docker client {{.Client.Version}} / server {{.Server.Version}}'
run_logged "$E" docker compose version
run_logged "$E" bash -c 'iperf3 --version | head -1; tcpdump --version 2>&1 | head -1; tshark --version | head -1; curl --version | head -1'
run_logged "$E" bash -c 'nproc; free -m'

log "Namespaces, interfaces and addressing"
N="$OUT/01_namespaces_interfaces.txt"
run_logged "$N" ip netns list
for ns in $NS_UE $NS_ACC $NS_CORE; do
  run_logged "$N" ip -n "$ns" -br link
  run_logged "$N" ip -n "$ns" -br addr
  run_logged "$N" ip -n "$ns" -d link show type veth
done
run_logged "$N" ip -br addr show host-core
run_logged "$N" ip -br addr show $DN_BRIDGE
run_logged "$N" bridge link show master $DN_BRIDGE

log "Routing tables and forwarding state"
R="$OUT/02_routing.txt"
for ns in $NS_UE $NS_ACC $NS_CORE; do
  run_logged "$R" ip -n "$ns" route
  run_logged "$R" ip netns exec "$ns" sysctl net.ipv4.ip_forward
done
run_logged "$R" ip route
run_logged "$R" sysctl net.ipv4.ip_forward
run_logged "$R" ue ip route get $APP_IP
run_logged "$R" acc ip route get $APP_IP
run_logged "$R" core ip route get $APP_IP
run_logged "$R" ip route get $APP_IP
run_logged "$R" ip route get $UE_IP
run_logged "$R" iptables -S DOCKER-USER

log "Docker network, containers and services"
D="$OUT/03_docker.txt"
run_logged "$D" docker compose -f "$COMPOSE_FILE" ps
run_logged "$D" docker network ls
run_logged "$D" docker network inspect scena-dn --format '{{json .Options}} {{json .IPAM.Config}}'
run_logged "$D" docker network inspect scena-dn --format '{{range .Containers}}{{.Name}} {{.IPv4Address}} {{.MacAddress}}{{"\n"}}{{end}}'
run_logged "$D" docker inspect -f '{{.Name}} pid={{.State.Pid}} image={{.Config.Image}} cmd={{.Config.Cmd}}' $APP_CONTAINER $IPERF_CONTAINER
run_logged "$D" nsenter -t "$(container_pid $APP_CONTAINER)" -n ss -tlnp
run_logged "$D" nsenter -t "$(container_pid $IPERF_CONTAINER)" -n ss -tulnp
run_logged "$D" nsenter -t "$(container_pid $APP_CONTAINER)" -n ip route
run_logged "$D" docker exec $APP_CONTAINER nginx -T

log "Hop-by-hop reachability"
P="$OUT/04_reachability.txt"
for t in $ACC_UE_IP $ACC_CORE_IP $CORE_ACC_IP $CORE_DN_IP $HOST_DN_IP $DN_GW $APP_IP $IPERF_IP; do
  run_logged "$P" ue ping -c 3 -i 0.2 -W 1 "$t"
done
run_logged "$P" ue traceroute -n -q 1 -w 1 $APP_IP
run_logged "$P" ue tracepath -n $APP_IP

log "Transport / application endpoints"
A="$OUT/05_application.txt"
run_logged "$A" ue curl -sv http://$APP_IP:$APP_PORT/
run_logged "$A" ue curl -s -o /dev/null -w 'code=%{http_code} remote=%{remote_ip}:%{remote_port} local=%{local_ip}:%{local_port} connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s size=%{size_download}B\n' http://$APP_IP:$APP_PORT/
run_logged "$A" ue curl -s http://$APP_IP:$APP_PORT/health
run_logged "$A" ue curl -s http://$APP_IP:$APP_PORT/nginx_status
run_logged "$A" ue nc -zv -w 2 $IPERF_IP $IPERF_PORT
sleep 2   # iperf3 -s resets its listener after a connection without a test cookie (nc -z)
run_logged "$A" ue iperf3 -c $IPERF_IP -t 3
run_logged "$A" docker logs --tail 5 $APP_CONTAINER
run_logged "$A" docker logs --tail 12 $IPERF_CONTAINER

log "Neighbour tables and interface counters (proof that each hop forwarded traffic)"
C="$OUT/06_neighbours_counters.txt"
for ns in $NS_UE $NS_ACC $NS_CORE; do
  run_logged "$C" ip -n "$ns" neigh
  run_logged "$C" ip -n "$ns" -s link
done
run_logged "$C" ip neigh show dev host-core
run_logged "$C" ip neigh show dev $DN_BRIDGE
run_logged "$C" ip -s link show host-core

echo "Evidence saved to $OUT"
