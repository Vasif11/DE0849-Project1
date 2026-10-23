#!/usr/bin/env bash
# Failure diagnosis in the 5G network - three injected faults with a full evidence chain:
#   F1  wrong subscriber key in the UDR       -> 5G-AKA fails, UE cannot register (control plane)
#   F2  UPF crash and restart                 -> user plane lost while the control plane still reports the session
#   F3  N3 interface of the UPF down          -> GTP-U black hole while N2/N4 stay healthy
# An HTTP probe runs in the UE every 0.5 s; tcpdump records N2, N3, N4 and N6; NF logs + metrics are saved.
source "$(dirname "$0")/lib.sh"
require_root

OUT="$RESULTS_DIR/failure"; PC="$CAPTURE_DIR/failure"; TMP=/tmp/scenb-failure
mkdir -p "$OUT" "$PC"; rm -rf "$TMP"; mkdir -p "$TMP"; rm -f "$OUT"/* "$PC"/*
echo "epoch,case,event" > "$OUT/events.csv"
events() { echo "$(date +%s.%N),$1,$2" >> "$OUT/events.csv"; }
mongo() { docker exec $C_MONGO mongosh --quiet mongodb://localhost/open5gs "$@"; }
nrcli() { docker exec $C_UE nr-cli "imsi-$IMSI" --exec "$1"; }
metric() { curl -s --max-time 2 "http://$1:9090/metrics" | grep -E "^($2)" || true; }

PROBE=""
probe_start() {
  ( echo "epoch,exit,code,t_total"
    while true; do
      t=$(date +%s.%N)
      r=$(ue curl -s -o /dev/null --max-time 1.5 -w '%{http_code},%{time_total}' http://$NGINX_IP/ 2>/dev/null) && rc=0 || rc=$?
      [[ -z "$r" ]] && r="000,1.5"
      echo "$t,$rc,$r"; sleep 0.5
    done ) > "$1" &
  PROBE=$!
}
probe_stop() { kill "$PROBE" 2>/dev/null; wait "$PROBE" 2>/dev/null || true; }

CAPS=()
caps_start() {
  CAPS=()
  for b in br-n2 br-n3 br-n4 br-n6; do
    tcpdump -Z root -n -s 256 -i $b -w "$TMP/${1}_${b#br-}.pcap" 2>/dev/null & CAPS+=($!)
  done
  sleep 1.5
}
caps_stop() { sleep 0.5; kill -INT "${CAPS[@]}" 2>/dev/null; wait "${CAPS[@]}" 2>/dev/null || true; }
# never leave the probe loop or tcpdump running if a step fails
cleanup() {
  local rc=$?
  [[ -n "$PROBE" ]] && kill "$PROBE" 2>/dev/null
  [[ ${#CAPS[@]} -gt 0 ]] && kill -INT "${CAPS[@]}" 2>/dev/null
  exit $rc
}
trap cleanup EXIT

ue_recover() { wait_pdu 90 && setup_routes; }

# ------------------------------------------------------------------ F1
f1() {
  local id=F1_wrong_subscriber_key E="$OUT/F1_wrong_subscriber_key_evidence.txt"
  log "$id"; caps_start $id; probe_start "$OUT/${id}_probe.csv"; sleep 4
  events $id inject
  mongo --eval 'db.subscribers.updateOne({imsi: "'$IMSI'"}, {$set: {"security.k": "00112233445566778899AABBCCDDEEFF"}})' > /dev/null
  docker restart $C_UE >/dev/null           # power-cycle -> new initial registration with the wrong key in the HN
  sleep 15
  run_logged "$E" nrcli status
  run_logged "$E" nrcli ps-list
  run_logged "$E" ue ip -br addr
  run_logged "$E" bash -c "docker logs --since 20s $C_UE 2>&1 | grep -E -i 'auth|reject|MAC|SQN|failed' | head -12"
  run_logged "$E" bash -c "docker logs --since 20s scenario-b-amf 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E -i 'auth|reject|MAC|SQN|fail' | head -12"
  run_logged "$E" bash -c "docker logs --since 20s scenario-b-ausf 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E -i 'auth|fail|mismatch' | head -6"
  run_logged "$E" metric 10.20.4.12 "fivegs_amffunction_amf_auth|fivegs_amffunction_rm_reginit|ran_ue|amf_session"
  run_logged "$E" mongo --eval 'printjson(db.subscribers.findOne({imsi: "'$IMSI'"}, {_id: 0, "security.k": 1}))'
  events $id recover
  docker exec $C_MONGO mongosh --quiet mongodb://localhost/open5gs /scripts/add_subscriber.js > /dev/null
  docker restart $C_UE >/dev/null
  ue_recover
  sleep 4; probe_stop; caps_stop; events $id end
}

# ------------------------------------------------------------------ F2
f2() {
  local id=F2_upf_restart E="$OUT/F2_upf_restart_evidence.txt"
  log "$id"; caps_start $id; probe_start "$OUT/${id}_probe.csv"; sleep 4
  events $id inject
  docker stop -t 1 $C_UPF >/dev/null
  sleep 12
  echo "### phase 1: UPF down" >> "$E"
  run_logged "$E" nrcli status
  run_logged "$E" nrcli ps-list
  run_logged "$E" metric 10.20.4.13 "pfcp_peers_active|pfcp_sessions_active|ues_active"
  run_logged "$E" ue curl -s -o /dev/null --max-time 2 -w 'code=%{http_code} total=%{time_total}\n' http://$NGINX_IP/
  run_logged "$E" bash -c "docker logs --since 15s scenario-b-smf 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E -i 'pfcp|heartbeat|association|fail' | head -8"
  # recovery = only restart the UPF; the 5GC itself restores the user-plane state
  events $id recover
  docker start $C_UPF >/dev/null
  local t0; t0=$(date +%s.%N)
  for _ in $(seq 1 60); do
    ue curl -s -o /dev/null --max-time 1 http://$NGINX_IP/ 2>/dev/null && break
    sleep 0.5
  done
  echo "user plane usable again $(echo "$(date +%s.%N) - $t0" | bc) s after 'docker start'" | tee -a "$E"
  disable_offloads
  echo "### phase 2: UPF restarted - no action on the UE" >> "$E"
  run_logged "$E" nrcli ps-list
  run_logged "$E" metric 10.20.4.13 "pfcp_peers_active|pfcp_sessions_active|ues_active"
  run_logged "$E" metric 10.20.5.14 "fivegs_upffunction_upf_sessionnbr|pfcp_peers_active"
  run_logged "$E" bash -c "docker logs --since 40s scenario-b-smf 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E -i 'pfcp|association|restor|session|UPF' | head -12"
  run_logged "$E" bash -c "docker logs --since 40s $C_UPF 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E -i 'pfcp|session|associated' | head -10"
  sleep 4; probe_stop; caps_stop; events $id end
}

# ------------------------------------------------------------------ F3
f3() {
  local id=F3_n3_link_down E="$OUT/F3_n3_link_down_evidence.txt" n3if
  n3if=$(ifname_of $C_UPF $UPF_N3_IP)
  log "$id"; caps_start $id; probe_start "$OUT/${id}_probe.csv"; sleep 4
  events $id inject
  cns $C_UPF ip link set "$n3if" down
  sleep 10
  run_logged "$E" cns $C_UPF ip -br link show "$n3if"
  run_logged "$E" nrcli status
  run_logged "$E" nrcli ps-list
  run_logged "$E" docker exec $C_GNB nr-cli "$(docker exec $C_GNB nr-cli --dump | head -1)" --exec status
  run_logged "$E" metric 10.20.4.13 "pfcp_peers_active|pfcp_sessions_active"
  run_logged "$E" cns $C_GNB ip -s link show "$(ifname_of $C_GNB $GNB_N3_IP)"
  run_logged "$E" cns $C_UPF ip -s link show "$n3if"
  run_logged "$E" ue ping -c 3 -W 1 $NGINX_IP
  events $id recover
  cns $C_UPF ip link set "$n3if" up          # the address survives a link down/up
  sleep 6
  run_logged "$E" ue ping -c 3 -W 1 $NGINX_IP
  probe_stop; caps_stop; events $id end
}

f1; sleep 3
f2; sleep 3
f3

# packet-level summary per case and interface (during the failure window)
{
  printf "%-26s %-4s %8s %8s %8s %8s %8s %8s\n" case if pkts ngap pfcp gtpu_ul gtpu_dl gtp_err
  for id in F1_wrong_subscriber_key F2_upf_restart F3_n3_link_down; do
    inj=$(awk -F, -v c=$id '$2==c && $3=="inject"{print $1}' "$OUT/events.csv")
    rec=$(awk -F, -v c=$id '$2==c && $3=="recover"{print $1}' "$OUT/events.csv")
    for b in n2 n3 n4 n6; do
      f="$TMP/${id}_$b.pcap"; W="frame.time_epoch >= $inj && frame.time_epoch < $rec"
      c() { tshark -n -r "$f" -Y "$W${1:+ && $1}" 2>/dev/null | wc -l; }
      printf "%-26s %-4s %8s %8s %8s %8s %8s %8s\n" $id $b "$(c)" "$(c ngap)" "$(c pfcp)" \
        "$(c 'gtp && ip.dst==10.20.3.14')" "$(c 'gtp && ip.dst==10.20.3.10')" "$(c 'gtp.message==26')"
    done
  done
} > "$OUT/packet_summary.txt"
T="tshark -n -o nas-5gs.null_decipher:TRUE"
$T -r "$TMP/F1_wrong_subscriber_key_n2.pcap" -Y ngap -T fields -e frame.time_epoch -e ip.src -e ip.dst -e _ws.col.Info 2>/dev/null \
  | sed 's/SACK ([^)]*) *, *//' > "$OUT/F1_n2_messages.txt"
$T -r "$TMP/F1_wrong_subscriber_key_n2.pcap" -Y "nas-5gs.mm.5gmm_cause or nas-5gs.mm.message_type == 0x59" -V 2>/dev/null \
  | grep -E "Message type|5GMM cause|Authentication failure parameter" | sed 's/^ *//' > "$OUT/F1_nas_causes.txt" || true
$T -r "$TMP/F2_upf_restart_n3.pcap" -Y "gtp.message==26" -V 2>/dev/null | awk '/^Frame /{n++} n==1' > "$OUT/F2_gtpu_error_indication.txt"
$T -r "$TMP/F2_upf_restart_n4.pcap" -Y pfcp -T fields -e frame.time_epoch -e ip.src -e ip.dst -e _ws.col.Info 2>/dev/null > "$OUT/F2_n4_messages.txt"
gzip -f "$TMP"/*.pcap; cp "$TMP"/*.pcap.gz "$PC/"
log "Failure evidence in $OUT and $PC"
