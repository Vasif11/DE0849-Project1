#!/usr/bin/env bash
# Step 3 - Run the full measurement set for the CURRENT network condition.
#
#   04_measure.sh <condition-name> [repetitions]
#
# Level 1 network     : ICMP RTT / loss                  (ping, 30 probes x reps)
# Level 2 transport   : TCP up/down throughput + retrans (iperf3 10 s x reps)
#                       UDP throughput / loss / jitter   (iperf3 -u -b 30M, 10 s x reps)
# Level 3 application : HTTP response time / success     (curl, 50 requests x reps)
#                       1 MiB transfer completion time   (curl, 5 downloads x reps)
# Evidence            : short tcpdump at both ends of the path + tc qdisc statistics
source "$(dirname "$0")/lib.sh"
require_root

COND=${1:?condition name}
REPS=${2:-3}
UDP_RATE=${UDP_RATE:-30M}
OUT="$RESULTS_DIR/raw/$COND"
PCAP_DIR="$CAPTURE_DIR/step3"
mkdir -p "$OUT" "$PCAP_DIR"
rm -f "$OUT"/*

"$REPO_DIR/scripts/impair.sh" show > "$OUT/qdisc_before.txt"
date -Is > "$OUT/started_at.txt"

iperf_run() {   # iperf_run <outfile> <args...>  (retries if the server is still busy)
  local out=$1; shift
  for attempt in 1 2 3 4 5; do
    if ue iperf3 -c $IPERF_IP "$@" -J > "$out" 2>/dev/null; then return 0; fi
    grep -q "busy" "$out" 2>/dev/null || true
    sleep 2
  done
  echo "iperf3 failed: $*" >&2
}

for r in $(seq 1 "$REPS"); do
  log "[$COND] repetition $r/$REPS"

  # ---- Level 1: ICMP
  ue ping -c 30 -i 0.2 -W 3 $APP_IP > "$OUT/ping_rep$r.txt" 2>&1 || true

  # ---- Level 2: TCP upload (UE -> server) and download (server -> UE)
  iperf_run "$OUT/tcp_up_rep$r.json"   -t 10;    sleep 1
  iperf_run "$OUT/tcp_down_rep$r.json" -t 10 -R; sleep 1

  # ---- Level 2: UDP with a fixed offered bit-rate
  iperf_run "$OUT/udp_rep$r.json" -u -b "$UDP_RATE" -t 10; sleep 1

  # ---- Level 3: HTTP small page (new TCP connection per request)
  # nstat without -a prints the counter delta since the previous call (UE namespace TCP MIB)
  export NSTAT_HISTORY=/tmp/.nstat_scena_ue
  ue nstat -n >/dev/null
  {
    echo "rep,req,exit,code,t_connect,t_ttfb,t_total,size"
    for i in $(seq 1 50); do
      res=$(ue curl -s -o /dev/null --max-time 5 \
            -w '%{http_code},%{time_connect},%{time_starttransfer},%{time_total},%{size_download}' \
            http://$APP_IP:$APP_PORT/) && rc=0 || rc=$?
      echo "$r,$i,$rc,$res"
    done
  } > "$OUT/http_rep$r.csv"
  ue nstat -z TcpRetransSegs TcpOutSegs TcpExtTCPTimeouts TcpActiveOpens TcpAttemptFails > "$OUT/http_nstat_rep$r.txt"

  # ---- Level 3: 1 MiB transfer completion time
  {
    echo "rep,req,exit,code,t_connect,t_ttfb,t_total,size"
    for i in $(seq 1 5); do
      res=$(ue curl -s -o /dev/null --max-time 20 \
            -w '%{http_code},%{time_connect},%{time_starttransfer},%{time_total},%{size_download}' \
            http://$APP_IP:$APP_PORT/files/1M.bin) && rc=0 || rc=$?
      echo "$r,$i,$rc,$res"
    done
  } > "$OUT/http1m_rep$r.csv"
done

# ---- Packet-level evidence: 3 s TCP flow (paced at 50 Mbit/s) captured at both ends
log "[$COND] packet capture for evidence"
TMP=/tmp/scena-step3; rm -rf $TMP; mkdir -p $TMP
ip netns exec $NS_UE tcpdump -Z root -B 16384 -n -s 96 -i ue-eth0 -w $TMP/${COND}_P1_ue-eth0.pcap "host $IPERF_IP and tcp" 2>/dev/null & P1=$!
tcpdump -Z root -B 16384 -n -s 96 -i $DN_BRIDGE -w $TMP/${COND}_P4_br-dn.pcap "host $IPERF_IP and tcp" 2>/dev/null & P4=$!
sleep 1.5
iperf_run "$OUT/capture_iperf.json" -t 3 -b 50M
sleep 1; kill -INT $P1 $P4; wait $P1 $P4 2>/dev/null || true
gzip -f $TMP/*.pcap
cp $TMP/*.pcap.gz "$PCAP_DIR/"

"$REPO_DIR/scripts/impair.sh" show > "$OUT/qdisc_after.txt"
date -Is > "$OUT/finished_at.txt"
log "[$COND] done -> $OUT"
