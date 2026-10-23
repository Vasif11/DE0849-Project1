#!/usr/bin/env bash
# Step 1 - Verify the 5G SA deployment layer by layer; evidence saved to results/step1/.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/step1"
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
NRF=http://10.20.4.10:7777

log "Environment and containers"
E="$OUT/00_environment.txt"
run_logged "$E" uname -r
run_logged "$E" docker version --format 'Docker {{.Server.Version}}'
run_logged "$E" $DC images
run_logged "$E" $DC ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'

log "Docker networks = 5G interfaces"
N="$OUT/01_networks_addressing.txt"
for n in ran n2 n3 sbi n4 dn obs; do
  run_logged "$N" docker network inspect scenario-b-$n --format \
    '{{.Name}} {{(index .IPAM.Config 0).Subnet}} bridge={{index .Options "com.docker.network.bridge.name"}}{{"\n"}}{{range .Containers}}   {{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
done

log "Interfaces and routes of the user-plane nodes"
R="$OUT/02_interfaces_routes.txt"
for c in $C_UE $C_GNB $C_UPF $C_NGINX $C_IPERF; do
  run_logged "$R" cns $c ip -br addr
  run_logged "$R" cns $c ip route
done
run_logged "$R" cns $C_UPF sysctl net.ipv4.ip_forward
run_logged "$R" ue ip route get $NGINX_IP
run_logged "$R" cns $C_UPF ip route get 10.45.0.2
run_logged "$R" cns $C_NGINX ip route get 10.45.0.2

log "Listening sockets per network function (control and user plane)"
S="$OUT/03_sockets.txt"
run_logged "$S" cns scenario-b-amf ss -lnp --sctp
run_logged "$S" cns scenario-b-amf ss -np --sctp
run_logged "$S" cns $C_GNB ss -np --sctp
run_logged "$S" cns $C_UPF ss -lunp
run_logged "$S" cns $C_GNB ss -lunp
run_logged "$S" cns scenario-b-smf ss -lunp
run_logged "$S" cns scenario-b-nrf ss -ltnp
run_logged "$S" cns $C_NGINX ss -ltnp
run_logged "$S" cns $C_IPERF ss -ltnp

log "5G core state: NRF registrations, RAN, UE, sessions"
F="$OUT/04_5gc_state.txt"
# NF profiles registered in the NRF (Nnrf_NFManagement API over HTTP/2 cleartext)
{
  echo "\$ curl --http2-prior-knowledge $NRF/nnrf-nfm/v1/nf-instances  (+ one GET per instance)"
  for href in $(curl -s --http2-prior-knowledge "$NRF/nnrf-nfm/v1/nf-instances" | jq -r '._links.item[].href'); do
    curl -s --http2-prior-knowledge "$href" |
      jq -c '{nfType, ipv4: .ipv4Addresses[0], nfStatus, services: [.nfServices[]?.serviceName]}'
  done | sort
  echo
} | tee -a "$F"
run_logged "$F" docker exec $C_GNB nr-cli --dump
GNB_NODE=$(docker exec $C_GNB nr-cli --dump | head -1)
run_logged "$F" docker exec $C_GNB nr-cli "$GNB_NODE" --exec status
run_logged "$F" docker exec $C_GNB nr-cli "$GNB_NODE" --exec amf-list
run_logged "$F" docker exec $C_GNB nr-cli "$GNB_NODE" --exec ue-count
run_logged "$F" docker exec $C_UE nr-cli "imsi-$IMSI" --exec status
run_logged "$F" docker exec $C_UE nr-cli "imsi-$IMSI" --exec ps-list
run_logged "$F" bash -c "curl -s http://10.20.4.12:9090/metrics | grep -E '^(gnb|ran_ue|amf_session|fivegs_amffunction_rm_reginit)'"
run_logged "$F" bash -c "curl -s http://10.20.4.13:9090/metrics | grep -E '^(ues_active|pfcp_sessions_active|pfcp_peers_active|bearers_active)'"
run_logged "$F" bash -c "curl -s http://10.20.5.14:9090/metrics | grep -E '^(fivegs_upffunction_upf_sessionnbr|pfcp_peers_active)'"

log "NF logs: registration, authentication, PDU session"
L="$OUT/05_nf_logs.txt"
run_logged "$L" bash -c "docker logs $C_UE 2>&1 | grep -E 'Registration|registration|PDU Session|TUN|uesimtun|Authentication|Security' | tail -20"
run_logged "$L" bash -c "docker logs $C_GNB 2>&1 | grep -E 'NG Setup|SCTP|PDU session|UE Context' | tail -10"
run_logged "$L" bash -c "docker logs scenario-b-amf 2>&1 | grep -E 'gNB-N2|Registration|SUCI|IMSI|accepted|Number of' | sed 's/\x1b\[[0-9;]*m//g' | tail -15"
run_logged "$L" bash -c "docker logs scenario-b-smf 2>&1 | grep -E 'PFCP|UE SUPI|IPv4|associated|Number of' | sed 's/\x1b\[[0-9;]*m//g' | tail -12"
run_logged "$L" bash -c "docker logs $C_UPF 2>&1 | grep -E 'PFCP|UE F-SEID|IPv4|associated|Number of' | sed 's/\x1b\[[0-9;]*m//g' | tail -10"

log "End-to-end over the 5G user plane (from the UE PDU session)"
A="$OUT/06_end_to_end.txt"
run_logged "$A" ue ping -c 5 -i 0.2 $NGINX_IP
run_logged "$A" ue ping -c 5 -i 0.2 $IPERF_IP
run_logged "$A" ue traceroute -n -q 1 -w 1 $NGINX_IP
run_logged "$A" ue curl -sv http://$NGINX_IP/
run_logged "$A" ue curl -s -o /dev/null -w 'code=%{http_code} remote=%{remote_ip}:%{remote_port} local=%{local_ip}:%{local_port} connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s size=%{size_download}B\n' http://$NGINX_IP/
run_logged "$A" ue iperf3 -c $IPERF_IP -t 3
run_logged "$A" docker logs --tail 3 $C_NGINX
echo "### Contrast: a request from inside the data network only proves N6/Docker connectivity, not 5G" >> "$A"
run_logged "$A" cns $C_IPERF curl -s -o /dev/null -w 'code=%{http_code} local=%{local_ip} (DN-internal, bypasses UE/gNB/N3/UPF)\n' http://$NGINX_IP/
echo "Evidence saved to $OUT"
