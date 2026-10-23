#!/usr/bin/env bash
# Step 2 - Capture ICMP, TCP (HTTP + iperf3), UDP (iperf3) and application traffic
# simultaneously at four observation points along the path and decode it with tshark.
#
#   P1  ue      / ue-eth0   UE side (traffic source)
#   P2  access  / acc-core  after the access router
#   P3  core    / core-dn   after the core gateway
#   P4  host    / br-dn     Docker data-network bridge, in front of the containers
source "$(dirname "$0")/lib.sh"
require_root

DEST="$CAPTURE_DIR/step2"
AN="$DEST/analysis"
# Capture to a local Linux tmpfs/ext4 path first: writing pcaps directly to a slow
# (e.g. Windows/9p) mount makes tcpdump lose packets in bursts. Copied to $DEST at the end.
OUT=/tmp/scena-step2
rm -rf "$OUT"; mkdir -p "$OUT" "$DEST" "$AN"
rm -f "$DEST"/*.pcap "$AN"/*

POINTS=("P1 $NS_UE ue-eth0" "P2 $NS_ACC acc-core" "P3 $NS_CORE core-dn" "P4 - $DN_BRIDGE")
PIDS=()

start_caps() {   # start_caps <name> <snaplen> <bpf filter>
  local name=$1 snap=$2 filter=$3
  PIDS=()
  for p in "${POINTS[@]}"; do
    set -- $p
    local f="$OUT/${name}_$1_$3.pcap"
    if [[ $2 == "-" ]]; then
      tcpdump -Z root -B 16384 -n -s "$snap" -i "$3" -w "$f" "$filter" 2>>"$OUT/tcpdump_stats.txt" &
    else
      ip netns exec "$2" tcpdump -Z root -B 16384 -n -s "$snap" -i "$3" -w "$f" "$filter" 2>>"$OUT/tcpdump_stats.txt" &
    fi
    PIDS+=($!)
  done
  sleep 1.5
}

stop_caps() {
  sleep 1
  for pid in "${PIDS[@]}"; do kill -INT "$pid" 2>/dev/null || true; done
  wait "${PIDS[@]}" 2>/dev/null || true
}

# ---------------------------------------------------------------- A. ICMP
log "A. ICMP echo with three packet sizes"
start_caps icmp 0 "icmp"
for size in 56 512 1400; do
  ue ping -c 5 -i 0.2 -s $size $APP_IP | tee -a "$AN/icmp_ping_output.txt"
done
stop_caps

# ---------------------------------------------------------------- B. TCP via HTTP (Nginx)
log "B/D. HTTP over TCP to Nginx (connection, request, response, teardown)"
start_caps http 0 "tcp port $APP_PORT"
ue curl -s -o /dev/null -w 'code=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} size=%{size_download}\n' \
  http://$APP_IP:$APP_PORT/ | tee "$AN/http_curl_output.txt"
stop_caps

log "D. Application bulk transfer (1 MiB object over HTTP)"
start_caps http1m 128 "tcp port $APP_PORT"
ue curl -s -o /dev/null -w 'code=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} size=%{size_download} speed=%{speed_download}B/s\n' \
  http://$APP_IP:$APP_PORT/files/1M.bin | tee "$AN/http1m_curl_output.txt"
stop_caps

# ---------------------------------------------------------------- B. TCP via iperf3
log "B. iperf3 TCP (2 s, paced at 20 Mbit/s to keep the capture small)"
start_caps tcp_iperf 128 "host $IPERF_IP and tcp"
ue iperf3 -c $IPERF_IP -t 2 -b 20M | tee "$AN/tcp_iperf_output.txt"
stop_caps

# ---------------------------------------------------------------- C. UDP via iperf3
log "C. iperf3 UDP (2 s at 5 Mbit/s)"
start_caps udp_iperf 128 "host $IPERF_IP"
ue iperf3 -c $IPERF_IP -u -b 5M -t 2 | tee "$AN/udp_iperf_output.txt"
stop_caps

# ---------------------------------------------------------------- tshark decoding
log "Decoding captures with tshark"
T="tshark -n -o tcp.relative_sequence_numbers:TRUE"

# packet counts per observation point
{
  printf "%-12s %-4s %-10s %8s\n" capture point iface packets
  for f in "$OUT"/*.pcap; do
    b=$(basename "$f" .pcap)
    n=$($T -r "$f" 2>/dev/null | wc -l)
    printf "%-12s %-4s %-10s %8s\n" "${b%_P*}" "$(echo "$b" | grep -o 'P[0-9]')" "${b##*_P[0-9]_}" "$n"
  done
} > "$AN/packet_counts.txt"

# ICMP: per-packet fields at UE (P1) and at the data-network bridge (P4)
for p in P1_ue-eth0 P4_br-dn; do
  $T -r "$OUT/icmp_$p.pcap" -T fields -E header=y -E separator=, \
     -e frame.number -e frame.time_epoch -e frame.len -e ip.src -e ip.dst -e ip.ttl -e ip.len \
     -e ip.id -e icmp.type -e icmp.code -e icmp.seq -e icmp.resptime > "$AN/icmp_fields_$p.csv"
done
$T -r "$OUT/icmp_P1_ue-eth0.pcap" -q -z io,phs > "$AN/icmp_protocol_hierarchy.txt"
$T -r "$OUT/icmp_P1_ue-eth0.pcap" -V -c 2 > "$AN/icmp_first_packets_verbose.txt"

# HTTP / TCP connection
$T -r "$OUT/http_P1_ue-eth0.pcap" > "$AN/http_packet_list.txt"
$T -r "$OUT/http_P1_ue-eth0.pcap" -T fields -E header=y -E separator=, \
   -e frame.number -e frame.time_relative -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e ip.ttl \
   -e tcp.flags.str -e tcp.seq -e tcp.ack -e tcp.window_size_value -e tcp.len -e tcp.analysis.ack_rtt \
   -e http.request.method -e http.request.uri -e http.response.code -e http.time > "$AN/http_tcp_fields.csv"
$T -r "$OUT/http_P1_ue-eth0.pcap" -q -z io,phs > "$AN/http_protocol_hierarchy.txt"
$T -r "$OUT/http_P1_ue-eth0.pcap" -q -z conv,tcp > "$AN/http_conversations.txt"
$T -r "$OUT/http_P1_ue-eth0.pcap" -Y http -V > "$AN/http_messages_verbose.txt"
$T -r "$OUT/http_P1_ue-eth0.pcap" -q -z http,stat > "$AN/http_stat.txt" 2>/dev/null || true
$T -r "$OUT/http1m_P1_ue-eth0.pcap" -q -z conv,tcp > "$AN/http1m_conversations.txt"
$T -r "$OUT/http1m_P1_ue-eth0.pcap" -q -z io,stat,0.005 > "$AN/http1m_io_stat.txt"
$T -r "$OUT/http1m_P1_ue-eth0.pcap" -q -z expert > "$AN/http1m_expert.txt" 2>/dev/null || true

# iperf3 TCP
$T -r "$OUT/tcp_iperf_P1_ue-eth0.pcap" -q -z conv,tcp > "$AN/tcp_iperf_conversations.txt"
$T -r "$OUT/tcp_iperf_P1_ue-eth0.pcap" -q -z io,phs > "$AN/tcp_iperf_protocol_hierarchy.txt"
$T -r "$OUT/tcp_iperf_P1_ue-eth0.pcap" -c 30 > "$AN/tcp_iperf_first30.txt"
$T -r "$OUT/tcp_iperf_P1_ue-eth0.pcap" -q -z expert > "$AN/tcp_iperf_expert.txt" 2>/dev/null || true
$T -r "$OUT/tcp_iperf_P1_ue-eth0.pcap" -Y "tcp.analysis.ack_rtt" -T fields -e tcp.analysis.ack_rtt > "$AN/tcp_iperf_ack_rtt.txt"

# iperf3 UDP
$T -r "$OUT/udp_iperf_P1_ue-eth0.pcap" -q -z conv,udp > "$AN/udp_iperf_conversations.txt"
$T -r "$OUT/udp_iperf_P1_ue-eth0.pcap" -q -z conv,tcp > "$AN/udp_iperf_control_conversations.txt"
$T -r "$OUT/udp_iperf_P1_ue-eth0.pcap" -q -z io,phs > "$AN/udp_iperf_protocol_hierarchy.txt"
$T -r "$OUT/udp_iperf_P1_ue-eth0.pcap" -Y udp -c 5 -V > "$AN/udp_iperf_first_datagrams_verbose.txt"
for p in P1_ue-eth0 P4_br-dn; do
  $T -r "$OUT/udp_iperf_$p.pcap" -Y udp -T fields -E header=y -E separator=, \
     -e frame.time_epoch -e ip.src -e ip.dst -e ip.ttl -e ip.id -e udp.srcport -e udp.dstport -e udp.length \
     > "$AN/udp_fields_$p.csv"
done

# capture-side sanity check: every tcpdump instance must report "0 packets dropped by kernel"
grep -o "[0-9]* packets dropped by kernel" "$OUT/tcpdump_stats.txt" | sort | uniq -c > "$AN/tcpdump_kernel_drops.txt" || true
cp "$OUT"/*.pcap "$DEST/"
echo "Captures in $DEST, decoded output in $AN"
