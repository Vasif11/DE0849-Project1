#!/usr/bin/env bash
# Step 3 - Full measurement set for the CURRENT condition over the complete 5G user plane:
#   UE (10.45.0.x, uesimtun0) -> gNB -> N3/GTP-U -> UPF -> N6 -> Nginx / iperf3
#
#   04_measure.sh <condition-name> [repetitions]
#
# Level 1 network     : ICMP RTT / loss                  (ping, 30 probes x reps)
# Level 2 transport   : TCP up/down throughput + retrans (iperf3 10 s x reps)
#                       UDP throughput / loss / jitter   (iperf3 -u -b 30M, 10 s x reps)
# Level 3 application : HTTP response time / success     (curl, 50 requests x reps)
#                       1 MiB transfer completion time   (curl, 5 downloads x reps)
# Evidence            : 3 s TCP flow captured at P1 (uesimtun0), P3 (N3) and P5 (N6) + tc statistics
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
echo "UE address: $(ue_ip)" > "$OUT/ue_address.txt"

iperf_run() {   # iperf_run <outfile> <args...>  (retries while the server is busy)
  local out=$1; shift
  for _ in 1 2 3 4 5; do
    if ue iperf3 -c $IPERF_IP "$@" -J > "$out" 2>/dev/null; then return 0; fi
    sleep 2
  done
  echo "iperf3 failed: $*" >&2
}

export NSTAT_HISTORY=/tmp/.nstat_scenb_ue
for r in $(seq 1 "$REPS"); do
  log "[$COND] repetition $r/$REPS"
  ue ping -c 30 -i 0.2 -W 3 $NGINX_IP > "$OUT/ping_rep$r.txt" 2>&1 || true

  iperf_run "$OUT/tcp_up_rep$r.json"   -t 10;    sleep 1
  iperf_run "$OUT/tcp_down_rep$r.json" -t 10 -R; sleep 1
  iperf_run "$OUT/udp_rep$r.json" -u -b "$UDP_RATE" -t 10; sleep 1

  ue nstat -n >/dev/null
  {
    echo "rep,req,exit,code,t_connect,t_ttfb,t_total,size"
    for i in $(seq 1 50); do
      res=$(ue curl -s -o /dev/null --max-time 5 \
            -w '%{http_code},%{time_connect},%{time_starttransfer},%{time_total},%{size_download}' \
            http://$NGINX_IP/) && rc=0 || rc=$?
      echo "$r,$i,$rc,$res"
    done
  } > "$OUT/http_rep$r.csv"
  ue nstat -z TcpRetransSegs TcpOutSegs TcpExtTCPTimeouts TcpActiveOpens TcpAttemptFails > "$OUT/http_nstat_rep$r.txt"

  {
    echo "rep,req,exit,code,t_connect,t_ttfb,t_total,size"
    for i in $(seq 1 5); do
      res=$(ue curl -s -o /dev/null --max-time 20 \
            -w '%{http_code},%{time_connect},%{time_starttransfer},%{time_total},%{size_download}' \
            http://$NGINX_IP/files/1M.bin) && rc=0 || rc=$?
      echo "$r,$i,$rc,$res"
    done
  } > "$OUT/http1m_rep$r.csv"
done

log "[$COND] packet capture at P1 (UE tunnel), P3 (N3) and P5 (N6)"
TMP=/tmp/scenb-step3; rm -rf $TMP; mkdir -p $TMP
nsenter -t "$(cpid $C_UE)" -n tcpdump -Z root -B 32768 -n -s 96 -i $UE_TUN -w $TMP/${COND}_P1_uesimtun0.pcap "tcp port $IPERF_PORT" 2>/dev/null & A=$!
tcpdump -Z root -B 32768 -n -s 160 -i br-n3 -w $TMP/${COND}_P3_N3.pcap "udp port 2152" 2>/dev/null & B=$!
tcpdump -Z root -B 32768 -n -s 96 -i br-n6 -w $TMP/${COND}_P5_N6.pcap "tcp port $IPERF_PORT" 2>/dev/null & C=$!
sleep 1.5
iperf_run "$OUT/capture_iperf.json" -t 3 -b 50M
sleep 1; kill -INT $A $B $C; wait $A $B $C 2>/dev/null || true
gzip -f $TMP/*.pcap
cp $TMP/*.pcap.gz "$PCAP_DIR/"

"$REPO_DIR/scripts/impair.sh" show > "$OUT/qdisc_after.txt"
date -Is > "$OUT/finished_at.txt"
log "[$COND] done -> $OUT"
