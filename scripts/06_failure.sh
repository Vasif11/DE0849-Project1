#!/usr/bin/env bash
# Failure diagnosis - inject three abnormal conditions, collect the evidence chain
# (symptom -> affected component -> packet/system/application evidence -> root cause -> recovery).
#
#   F1  missing return route on the host (routing misconfiguration, asymmetric failure)
#   F2  IP forwarding disabled on the access router
#   F3  application container stopped (service failure while the network is healthy)
#
# For every case an HTTP probe runs from the UE every 0.5 s (before / during / after),
# tcpdump runs at P1..P4 (+ host eth0 for F1), and system state is recorded.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/failure"
PC="$CAPTURE_DIR/failure"
TMP=/tmp/scena-failure
mkdir -p "$OUT" "$PC"; rm -rf "$TMP"; mkdir -p "$TMP"
rm -f "$OUT"/* "$PC"/*

UPLINK_IF=$(ip route show default | awk '{print $5; exit}')   # host interface of the default route
export NSTAT_HISTORY=/tmp/.nstat_scena_failure

PROBE_PID=""
probe_start() {   # HTTP probe loop from the UE -> CSV
  local f=$1
  ( echo "epoch,exit,code,t_total"
    while true; do
      t=$(date +%s.%N)
      r=$(ip netns exec $NS_UE curl -s -o /dev/null --max-time 1.5 -w '%{http_code},%{time_total}' \
          http://$APP_IP:$APP_PORT/) && rc=0 || rc=$?
      echo "$t,$rc,$r"
      sleep 0.5
    done ) > "$f" &
  PROBE_PID=$!
}
probe_stop() { kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true; }

CAP_PIDS=()
caps_start() {   # caps_start <case>
  local c=$1; CAP_PIDS=()
  ip netns exec $NS_UE   tcpdump -Z root -n -i ue-eth0  -w $TMP/${c}_P1_ue-eth0.pcap  "host $APP_IP or icmp" 2>/dev/null & CAP_PIDS+=($!)
  ip netns exec $NS_ACC  tcpdump -Z root -n -i acc-core -w $TMP/${c}_P2_acc-core.pcap "host $APP_IP or icmp" 2>/dev/null & CAP_PIDS+=($!)
  ip netns exec $NS_CORE tcpdump -Z root -n -i core-dn  -w $TMP/${c}_P3_core-dn.pcap  "host $APP_IP or icmp" 2>/dev/null & CAP_PIDS+=($!)
  tcpdump -Z root -n -i $DN_BRIDGE -w $TMP/${c}_P4_br-dn.pcap "host $APP_IP or icmp or arp" 2>/dev/null & CAP_PIDS+=($!)
  tcpdump -Z root -n -i "$UPLINK_IF" -w $TMP/${c}_host-${UPLINK_IF}.pcap "host $UE_IP" 2>/dev/null & CAP_PIDS+=($!)
  sleep 1.5
}
caps_stop() { sleep 0.5; kill -INT "${CAP_PIDS[@]}" 2>/dev/null; wait "${CAP_PIDS[@]}" 2>/dev/null || true; }

disable_offloads_containers() {
  for c in $APP_CONTAINER $IPERF_CONTAINER; do
    nsenter -t "$(container_pid $c)" -n ethtool -K eth0 tso off gso off gro off >/dev/null 2>&1 || true
  done
  for v in $(ip -o link show master $DN_BRIDGE | awk -F': ' '{print $2}' | cut -d@ -f1); do
    ethtool -K "$v" tso off gso off gro off >/dev/null 2>&1 || true
  done
}

events() { echo "$(date +%s.%N),$1,$2" >> "$OUT/events.csv"; }
echo "epoch,case,event" > "$OUT/events.csv"

run_case() {   # run_case <id> <inject-fn> <evidence-fn> <recover-fn>
  local id=$1 inject=$2 evidence=$3 recover=$4
  local E="$OUT/${id}_evidence.txt"
  log "$id: baseline phase"
  caps_start "$id"
  probe_start "$OUT/${id}_probe.csv"
  sleep 4
  log "$id: inject failure"; events "$id" inject; $inject
  sleep 6
  log "$id: collect evidence"; $evidence "$E"
  sleep 4
  log "$id: recover"; events "$id" recover; $recover
  sleep 5
  probe_stop; caps_stop
  events "$id" end
  {
    echo "### packet counts per observation point"
    for f in $TMP/${id}_*.pcap; do printf "%-32s %6s packets\n" "$(basename "$f")" "$(tcpdump -r "$f" -n 2>/dev/null | wc -l)"; done
  } >> "$E"
}

# ---------------------------------------------------------------- F1
f1_inject()  { ip route del 10.0.1.0/24 via $CORE_DN_IP dev host-core; }
f1_recover() { ip route add 10.0.1.0/24 via $CORE_DN_IP dev host-core; }
f1_evidence() {
  local E=$1
  run_logged "$E" ue curl -s -o /dev/null --max-time 2 -w 'code=%{http_code} total=%{time_total}\n' http://$APP_IP:$APP_PORT/
  run_logged "$E" ue ping -c 3 -W 1 $APP_IP
  run_logged "$E" ue ping -c 2 -W 1 $CORE_DN_IP
  run_logged "$E" ue ping -c 2 -W 1 $HOST_DN_IP
  run_logged "$E" ip route get $UE_IP
  run_logged "$E" ip route
  run_logged "$E" ue traceroute -n -q 1 -w 1 -m 5 $APP_IP
}

# ---------------------------------------------------------------- F2
f2_inject()  { ip netns exec $NS_ACC sysctl -qw net.ipv4.ip_forward=0; ip netns exec $NS_ACC nstat -n >/dev/null; }
f2_recover() { ip netns exec $NS_ACC sysctl -qw net.ipv4.ip_forward=1; }
f2_evidence() {
  local E=$1
  run_logged "$E" ue curl -s -o /dev/null --max-time 2 -w 'code=%{http_code} total=%{time_total}\n' http://$APP_IP:$APP_PORT/
  run_logged "$E" ue ping -c 3 -W 1 $ACC_UE_IP
  run_logged "$E" ue ping -c 3 -W 1 $APP_IP
  run_logged "$E" ip netns exec $NS_ACC sysctl net.ipv4.ip_forward
  run_logged "$E" ip netns exec $NS_ACC nstat -z IpInAddrErrors IpForwDatagrams IpInReceives
  run_logged "$E" ip -n $NS_ACC -s link show acc-ue
  run_logged "$E" ip -n $NS_ACC -s link show acc-core
}

# ---------------------------------------------------------------- F3
f3_inject()  { docker stop -t 1 $APP_CONTAINER >/dev/null; }
f3_recover() { docker start $APP_CONTAINER >/dev/null; sleep 1; disable_offloads_containers; }
f3_evidence() {
  local E=$1
  run_logged "$E" ue curl -s -o /dev/null --max-time 5 -w 'code=%{http_code} total=%{time_total}\n' http://$APP_IP:$APP_PORT/
  run_logged "$E" ue curl -sS -o /dev/null --max-time 5 http://$APP_IP:$APP_PORT/
  run_logged "$E" ue ping -c 3 -W 1 $APP_IP
  run_logged "$E" ue ping -c 3 -W 1 $IPERF_IP
  run_logged "$E" docker ps -a --filter name=scena- --format 'table {{.Names}}\t{{.Status}}'
  run_logged "$E" ip neigh show dev $DN_BRIDGE
  run_logged "$E" docker network inspect scena-dn --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
}

run_case F1_missing_return_route f1_inject f1_evidence f1_recover
run_case F2_access_forwarding_off f2_inject f2_evidence f2_recover
run_case F3_app_container_down    f3_inject f3_evidence f3_recover

# decode the key packets of each case: the first connection attempts AFTER the injection
for id in F1_missing_return_route F2_access_forwarding_off F3_app_container_down; do
  inj=$(awk -F, -v c="$id" '$2==c && $3=="inject" {print $1}' "$OUT/events.csv")
  for f in $TMP/${id}_*.pcap; do
    echo "===== $(basename "$f")  (packets after injection at epoch $inj)"
    # "|| true": head closes the pipe early, which would abort the script under pipefail
    tshark -n -t e -r "$f" -Y "frame.time_epoch >= $inj && (tcp.flags.syn==1 or icmp or arp)" 2>/dev/null | head -8 || true
  done > "$OUT/${id}_packets.txt"
done

gzip -f $TMP/*.pcap; cp $TMP/*.pcap.gz "$PC/"
log "Failure diagnosis evidence in $OUT and $PC"
