#!/usr/bin/env bash
# Diagnosis F0 - TCP retransmissions in the *unimpaired* baseline (an abnormal condition that
# was found, not injected).
#
# Symptom: iperf3 reports hundreds to ~2000 retransmissions per 10 s TCP test although no
# impairment is configured.
#
# Part A  hypothesis 1 "kernel input-backlog overflow": compare retransmissions with the
#         softnet "dropped" counter for net.core.netdev_max_backlog = 1000 and 10000.
# Part B  hypothesis 2 "loss on the path" vs "reordering": capture a 3 s flow at both ends
#         of the path (P1 ue-eth0 and P4 br-dn) and compare segment counts, tshark analysis
#         flags, interface drop counters and the TCP MIB of sender and receiver.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/baseline_retrans"
mkdir -p "$OUT"; rm -f "$OUT"/*
"$REPO_DIR/scripts/impair.sh" clear >/dev/null
ORIG_BACKLOG=$(sysctl -n net.core.netdev_max_backlog)

softnet_drops() {   # sum of the per-CPU "dropped" column (hex) of /proc/net/softnet_stat
  local s=0 d
  while read -r _ d _; do s=$((s + 16#$d)); done < /proc/net/softnet_stat
  echo $s
}
mib() {   # mib <history-file> <cmd...>  -> delta of selected TCP counters since the last call
  NSTAT_HISTORY=$1 "${@:2}" nstat -z TcpRetransSegs TcpExtTCPDSACKRecv TcpExtTCPSACKReorder \
    TcpExtTCPOFOQueue TcpExtTCPDSACKOldSent TcpInSegs TcpOutSegs |
    awk '{v[$1]=$2} END {printf "%d,%d,%d,%d,%d", v["TcpRetransSegs"], v["TcpExtTCPDSACKRecv"], \
         v["TcpExtTCPSACKReorder"], v["TcpExtTCPOFOQueue"], v["TcpExtTCPDSACKOldSent"]}'
}
SRV_PID=$(container_pid $IPERF_CONTAINER)

# ------------------------------------------------------------------ Part A
log "Part A: netdev_max_backlog 1000 vs 10000 (3 x 10 s upload each)"
echo "backlog,rep,throughput_bps,iperf_retrans,softnet_drops,ue_retrans,ue_dsack_recv,ue_sack_reorder,srv_ofo_queue,srv_dsack_sent" > "$OUT/partA_backlog.csv"
for backlog in 1000 10000; do
  sysctl -qw net.core.netdev_max_backlog=$backlog
  for r in 1 2 3; do
    d0=$(softnet_drops)
    mib /tmp/.nstat_f0_ue ip netns exec $NS_UE >/dev/null
    mib /tmp/.nstat_f0_srv nsenter -t "$SRV_PID" -n >/dev/null
    ue iperf3 -c $IPERF_IP -t 10 -J > "$OUT/partA_backlog${backlog}_rep$r.json"
    d1=$(softnet_drops)
    ue_m=$(mib /tmp/.nstat_f0_ue ip netns exec $NS_UE | cut -d, -f1-3)
    srv_m=$(mib /tmp/.nstat_f0_srv nsenter -t "$SRV_PID" -n | cut -d, -f4-5)
    bps=$(jq '.end.sum_received.bits_per_second' "$OUT/partA_backlog${backlog}_rep$r.json")
    rt=$(jq '.end.sum_sent.retransmits' "$OUT/partA_backlog${backlog}_rep$r.json")
    echo "$backlog,$r,$bps,$rt,$((d1 - d0)),$ue_m,$srv_m" | tee -a "$OUT/partA_backlog.csv"
    sleep 1
  done
done
sysctl -qw net.core.netdev_max_backlog="$ORIG_BACKLOG"

# ------------------------------------------------------------------ Part B
log "Part B: two-point capture of a 3 s full-rate TCP flow"
TMP=/tmp/scena-f0; rm -rf $TMP; mkdir -p $TMP
link_drops() {
  for e in "$NS_UE ue-eth0" "$NS_ACC acc-ue" "$NS_ACC acc-core" "$NS_CORE core-acc" "$NS_CORE core-dn"; do
    set -- $e; ip -n "$1" -s -j link show "$2"
  done | jq -s '[.[][0].stats64 | .rx.dropped + .tx.dropped] | add'
}
L0=$(link_drops); D0=$(softnet_drops)
mib /tmp/.nstat_f0_ue ip netns exec $NS_UE >/dev/null
mib /tmp/.nstat_f0_srv nsenter -t "$SRV_PID" -n >/dev/null
ip netns exec $NS_UE tcpdump -Z root -B 65536 -n -s 80 -i ue-eth0 -w $TMP/P1.pcap "tcp and dst port $IPERF_PORT" 2>$TMP/P1.err & A=$!
tcpdump -Z root -B 65536 -n -s 80 -i $DN_BRIDGE -w $TMP/P4.pcap "tcp and dst port $IPERF_PORT" 2>$TMP/P4.err & B=$!
sleep 1.5
ue iperf3 -c $IPERF_IP -t 3 -J > "$OUT/partB_iperf.json"
sleep 1; kill -INT $A $B; wait $A $B 2>/dev/null || true
L1=$(link_drops); D1=$(softnet_drops)
UE_M=$(mib /tmp/.nstat_f0_ue ip netns exec $NS_UE)
SRV_M=$(mib /tmp/.nstat_f0_srv nsenter -t "$SRV_PID" -n)

count() { tshark -n -r "$1" -Y "$2" 2>/dev/null | wc -l; }
{
  echo "iperf3: $(jq -r '"\(.end.sum_sent.bits_per_second/1e9) Gbit/s, retransmits=\(.end.sum_sent.retransmits)"' "$OUT/partB_iperf.json")"
  echo "tcpdump: $(grep -h 'dropped by kernel' $TMP/P1.err $TMP/P4.err | tr '\n' ' ')"
  echo "interface drop counters on the path (delta): $((L1 - L0))"
  echo "softnet backlog drops (delta): $((D1 - D0))"
  echo "UE  (sender)   TcpRetransSegs,DSACKRecv,SACKReorder,OFOQueue,DSACKOldSent = $UE_M"
  echo "srv (receiver) TcpRetransSegs,DSACKRecv,SACKReorder,OFOQueue,DSACKOldSent = $SRV_M"
  echo
  printf "%-6s %12s %14s %14s %14s\n" point data_segs retransmission out_of_order spurious_retr
  for p in P1 P4; do
    printf "%-6s %12s %14s %14s %14s\n" $p \
      "$(count $TMP/$p.pcap 'tcp.len>0')" \
      "$(count $TMP/$p.pcap 'tcp.analysis.retransmission')" \
      "$(count $TMP/$p.pcap 'tcp.analysis.out_of_order')" \
      "$(count $TMP/$p.pcap 'tcp.analysis.spurious_retransmission')"
  done
} | tee "$OUT/partB_two_point_evidence.txt"
# keep a small excerpt (first 3000 packets) of both captures as evidence
for p in P1 P4; do editcap -r $TMP/$p.pcap $TMP/${p}_excerpt.pcap 1-3000 >/dev/null 2>&1 || true; done
mkdir -p "$CAPTURE_DIR/baseline_retrans"
gzip -c $TMP/P1_excerpt.pcap > "$CAPTURE_DIR/baseline_retrans/P1_ue-eth0_excerpt.pcap.gz"
gzip -c $TMP/P4_excerpt.pcap > "$CAPTURE_DIR/baseline_retrans/P4_br-dn_excerpt.pcap.gz"
log "Evidence in $OUT"
