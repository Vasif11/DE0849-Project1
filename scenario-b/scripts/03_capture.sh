#!/usr/bin/env bash
# Step 2 - Observe a complete UE life cycle on every interface at the same time:
#   deregistration -> initial registration (auth, security mode) -> PDU session establishment
#   -> ICMP / HTTP / iperf3 TCP / iperf3 UDP user traffic.
#
#   P1  br-ran      UE <-> gNB simulated radio (UERANSIM RLS, UDP 4997)   + UE uesimtun0 (inner IP)
#   P2  br-n2       N2  gNB <-> AMF   NGAP / SCTP 38412
#   P3  br-n3       N3  gNB <-> UPF   GTP-U / UDP 2152
#   P4  br-n4       N4  SMF <-> UPF   PFCP / UDP 8805
#   P5  br-n6       N6  UPF <-> data network (P6 Nginx and P7 iperf3 are on this bridge)
#   SBI br-sbi      5GC service-based interface, HTTP/2 cleartext port 7777
source "$(dirname "$0")/lib.sh"
require_root

DEST="$CAPTURE_DIR/step2"; AN="$DEST/analysis"; LOGS="$RESULTS_DIR/step2_logs"
TMP=/tmp/scenb-step2
rm -rf "$TMP"; mkdir -p "$TMP" "$DEST" "$AN" "$LOGS"
rm -f "$DEST"/*.pcap* "$AN"/* "$LOGS"/*

PIDS=()
cap() {   # cap <name> <iface> [filter]  - capture on a host bridge
  tcpdump -Z root -B 32768 -n -s 0 -i "$2" -w "$TMP/$1.pcap" ${3:+"$3"} 2>>"$TMP/tcpdump.err" & PIDS+=($!)
}

log "UE deregistration (switch-off) and power-off before the observation window"
# UERANSIM re-registers immediately after a switch-off deregistration, so the container is
# stopped right away; the core releases the UE context and the PDU session cleanly.
docker exec $C_UE nr-cli "imsi-$IMSI" --exec "deregister switch-off" || true
docker stop -t 1 $C_UE >/dev/null
sleep 5

log "Starting captures on all interfaces"
cap P1_radio br-ran
cap P2_N2 br-n2
cap P3_N3 br-n3
cap P4_N4 br-n4
cap P5_N6 br-n6
cap SBI br-sbi "tcp port 7777"
sleep 2
T0=$(date +%s)   # Unix time: docker logs --since would read a date without zone as local time

log "UE power-on: initial registration + PDU session establishment"
docker start $C_UE >/dev/null
# the UE tunnel interface is created during the PDU session -> start the inner capture afterwards
wait_pdu 60
nsenter -t "$(cpid $C_UE)" -n tcpdump -Z root -n -s 0 -i $UE_TUN -w "$TMP/P1_uesimtun0.pcap" 2>>"$TMP/tcpdump.err" & PIDS+=($!)
setup_routes
sleep 2
echo "PDU session address: $(ue_ip)" | tee "$AN/pdu_session.txt"

log "User traffic over the PDU session"
ue ping -c 5 -i 0.2 $NGINX_IP | tee "$AN/ping_output.txt"
ue curl -s -o /dev/null -w 'code=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} size=%{size_download}\n' \
  http://$NGINX_IP/ | tee "$AN/curl_output.txt"
ue iperf3 -c $IPERF_IP -t 2 -b 20M | tee "$AN/iperf_tcp_output.txt"
sleep 1
ue iperf3 -c $IPERF_IP -u -b 5M -t 2 | tee "$AN/iperf_udp_output.txt"
sleep 2
for p in "${PIDS[@]}"; do kill -INT "$p" 2>/dev/null || true; done
wait "${PIDS[@]}" 2>/dev/null || true
grep -o "[0-9]* packets dropped by kernel" "$TMP/tcpdump.err" | sort | uniq -c > "$AN/tcpdump_kernel_drops.txt" || true

log "Saving NF logs of the procedure window"
for c in ue gnb amf ausf udm udr smf upf pcf nrf scp; do
  docker logs --since "$T0" scenario-b-$c 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$LOGS/$c.log"
done

log "Decoding with tshark"
# NEA0 (null ciphering) is negotiated, so "ciphered" NAS messages can be decoded in clear
T="tshark -n -o tcp.relative_sequence_numbers:TRUE -o nas-5gs.null_decipher:TRUE"
F="frame.time_epoch"
# NGAP + NAS-5GS on N2
$T -r "$TMP/P2_N2.pcap" -Y ngap -T fields -E separator='|' -e $F -e ip.src -e ip.dst \
   -e ngap.procedureCode -e _ws.col.Info > "$AN/n2_ngap.txt"
$T -r "$TMP/P2_N2.pcap" -q -z io,phs > "$AN/n2_protocol_hierarchy.txt"
$T -r "$TMP/P2_N2.pcap" -Y "nas-5gs" -V 2>/dev/null | grep -E "Message type|5GMM cause|Security header type|SUCI|Type of identity|PDU session identity|PDU address|IPv4 address|Selected NAS security|Type of ciphering|Type of integrity|DNN|SST|5GS registration result|Session-AMBR" \
   | sed 's/^ *//' | uniq > "$AN/n2_nas_fields.txt" || true
# SBI (HTTP/2 cleartext on 7777)
$T -r "$TMP/SBI.pcap" -d tcp.port==7777,http2 -Y "http2.headers.method or http2.headers.status" -T fields -E separator='|' \
   -e $F -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e http2.streamid -e http2.headers.method -e http2.headers.path -e http2.headers.status \
   > "$AN/sbi_http2.txt"
# PFCP on N4
$T -r "$TMP/P4_N4.pcap" -Y pfcp -T fields -E separator='|' -e $F -e ip.src -e ip.dst -e pfcp.msg_type -e pfcp.seqno -e _ws.col.Info > "$AN/n4_pfcp.txt"
$T -r "$TMP/P4_N4.pcap" -Y "pfcp.msg_type == 50" -V 2>/dev/null | grep -E "Create PDR|Create FAR|PDR ID|FAR ID|Source Interface|Destination Interface|UE IP Address|IPv4 address|TEID|Apply Action|Outer Header|F-TEID|Network Instance|QFI|Precedence" \
   | sed 's/^ *//' > "$AN/n4_pfcp_session_establishment_ies.txt" || true
$T -r "$TMP/P4_N4.pcap" -Y "pfcp.msg_type == 52" -V 2>/dev/null | grep -E "Update FAR|FAR ID|Apply Action|Outer Header Creation|TEID|IPv4" \
   | sed 's/^ *//' > "$AN/n4_pfcp_session_modification_ies.txt" || true
# GTP-U on N3
$T -r "$TMP/P3_N3.pcap" -q -z io,phs > "$AN/n3_protocol_hierarchy.txt"
$T -r "$TMP/P3_N3.pcap" -Y "gtp && icmp" -T fields -E separator='|' -e $F -e ip.src -e ip.dst -e udp.srcport -e udp.dstport \
   -e gtp.teid -e gtp.ext_hdr.pdu_ses_con.qos_flow_id -e ip.len -e icmp.type -e icmp.seq > "$AN/n3_gtpu_icmp.txt"
$T -r "$TMP/P3_N3.pcap" -Y "gtp && icmp.type==8" -V 2>/dev/null | awk '/^Frame /{n++} n==1' > "$AN/n3_gtpu_packet_verbose.txt"
# N6 / application
$T -r "$TMP/P5_N6.pcap" -q -z io,phs > "$AN/n6_protocol_hierarchy.txt"
$T -r "$TMP/P5_N6.pcap" -Y "icmp" -T fields -E separator='|' -e $F -e ip.src -e ip.dst -e ip.ttl -e ip.len -e icmp.type -e icmp.seq > "$AN/n6_icmp.txt"
$T -r "$TMP/P5_N6.pcap" -Y "tcp.port==80" > "$AN/n6_http_packet_list.txt"
$T -r "$TMP/P5_N6.pcap" -Y http -V 2>/dev/null | grep -E "^Hypertext|GET|HTTP/1.1 [0-9]|Host:|Server:|Content-Length|Content-Type|time since request" > "$AN/n6_http_messages.txt" || true
$T -r "$TMP/P5_N6.pcap" -q -z conv,tcp > "$AN/n6_tcp_conversations.txt"
$T -r "$TMP/P5_N6.pcap" -q -z conv,udp > "$AN/n6_udp_conversations.txt"
$T -r "$TMP/P1_uesimtun0.pcap" -q -z io,phs > "$AN/ue_tun_protocol_hierarchy.txt"
$T -r "$TMP/P1_radio.pcap" -q -z conv,udp > "$AN/radio_udp_conversations.txt"
# per-interface packet counts of the same user traffic
{
  printf "%-14s %10s %10s %10s %10s\n" capture all icmp tcp_80 udp_5201
  for f in "$TMP"/*.pcap; do
    b=$(basename "$f" .pcap)
    printf "%-14s %10s %10s %10s %10s\n" "$b" "$($T -r "$f" 2>/dev/null | wc -l)" \
      "$($T -r "$f" -Y icmp 2>/dev/null | wc -l)" "$($T -r "$f" -Y 'tcp.port==80' 2>/dev/null | wc -l)" \
      "$($T -r "$f" -Y 'udp.port==5201' 2>/dev/null | wc -l)"
  done
} > "$AN/packet_counts.txt"

# large user-plane captures are stored compressed (Wireshark opens .pcap.gz directly)
for f in P1_radio P1_uesimtun0 P3_N3 P5_N6; do gzip -c "$TMP/$f.pcap" > "$DEST/$f.pcap.gz"; done
for f in P2_N2 P4_N4 SBI; do cp "$TMP/$f.pcap" "$DEST/"; done
log "Captures in $DEST, decoded output in $AN, NF logs in $LOGS"
